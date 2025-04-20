import Atomics
import Foundation
import Logging
import PostgresNIO
import ServiceLifecycle

// Define a struct to hold log data internally mimicking the log method signature
public struct LogEntry: Sendable {
    let label: String
    let level: Logger.Level
    let message: Logger.Message
    let metadata: Logger.Metadata?
    let source: String
    let file: String
    let function: String
    let line: UInt
    let timestamp: Date
}

// Actor to manage buffering and async database writes, conforming to Service
public actor PostgresLogProcessor: Service {
    private var buffer: [LogEntry] = []
    private let postgresClient: PostgresClient
    private let tableName: String
    private let maxBatchSize: Int
    private let flushInterval: Duration
    private let logger: Logger?

    // Atomic flag to signal when to stop accepting AND processing new logs in the main loop
    private let isRunning = ManagedAtomic<Bool>(true)

    public struct Configuration {
        let postgresClient: PostgresClient
        let tableName: String
        let maxBatchSize: Int
        let flushInterval: Duration
        let logger: Logger?

        /// - Parameters:
        ///   - postgresClient: The PostgresClient to use for logging.
        ///   - tableName: The name of the table to use for logging.
        ///   - maxBatchSize: The maximum number of logs to process in a single batch.
        ///   - flushInterval: The interval to flush the buffer to the database.
        ///   - logger: Another logger to use for logging the internal workings of the processor. You can them log to the console for example.
        public init(postgresClient: PostgresClient, tableName: String, maxBatchSize: Int = 100, flushInterval: Duration = .seconds(5), logger: Logger? = nil) {
            self.postgresClient = postgresClient
            self.tableName = tableName
            self.maxBatchSize = maxBatchSize
            self.flushInterval = flushInterval
            self.logger = logger
        }
    }

    public init(configuration: Configuration) {
        self.postgresClient = configuration.postgresClient
        self.tableName = configuration.tableName
        self.maxBatchSize = configuration.maxBatchSize
        self.flushInterval = configuration.flushInterval
        self.logger = configuration.logger
        logger?.trace("PostgresLogProcessor initialized.")
    }

    public func run() async throws {
        logger?.trace("PostgresLogProcessor run() started.")

        try await withGracefulShutdownHandler {

            logger?.trace("PostgresLogProcessor: Entering main processing loop.")
            do {
                // Loop while isRunning is true
                while self.isRunning.load(ordering: .relaxed) {
                    do {
                        // Sleep, but catch cancellation because the outer Task *could* still be cancelled
                        try await Task.sleep(for: flushInterval)
                    } catch is CancellationError {
                        logger?.trace("PostgresLogProcessor: Task.sleep cancelled (external cancellation). Loop will exit.")
                        // Explicitly ensure isRunning is false if sleep is cancelled.
                        // Although technically the loop condition check would handle this next.
                        self.isRunning.store(false, ordering: .relaxed)
                        break  // Exit loop immediately if sleep is cancelled
                    } catch {
                        // Handle other potential errors from Task.sleep if any
                        logger?.error("PostgresLogProcessor: Unexpected error during sleep: \(error). Stopping.")
                        self.isRunning.store(false, ordering: .relaxed)
                        throw error  // Propagate unexpected errors
                    }

                    // Check the flag *again* after waking up, before processing
                    guard self.isRunning.load(ordering: .relaxed) else {
                        logger?.trace("PostgresLogProcessor: Shutdown detected after sleep, skipping processBuffer.")
                        break  // Exit loop
                    }

                    // Process the buffer if still running
                    await processBuffer()
                    logger?.trace("PostgresLogProcessor: Processed buffer. Buffer size: \(buffer.count)")

                    // Yield ever so often if needed, especially if processBuffer could be long
                    // await Task.yield()
                }
                logger?.trace("PostgresLogProcessor: Exited main processing loop (isRunning=\(self.isRunning.load(ordering: .relaxed))).")

            } catch {
                // Catch errors also from processBuffer if it could throw (it doesn't currently)
                logger?.error("PostgresLogProcessor: Error in main loop execution: \(error). Exiting loop.")
                // Ensure flag is false on error exit
                self.isRunning.store(false, ordering: .relaxed)
                // Propagate error to ServiceGroup
                throw error
            }

            // Drain the queue after loop exit
            // The loop exited because isRunning became false (either via onGracefulShutdown or cancellation/error).
            logger?.trace("PostgresLogProcessor: Performing final drain...")

            // Yield to allow any already-scheduled 'addEntry' tasks that were created
            // *before* isRunning was set to false in onGracefulShutdown to run on the actor's executor.
            await Task.yield()

            // Process whatever is left in the buffer after yielding.
            await processBuffer()  // This uses the isolated processBuffer method
            logger?.trace("PostgresLogProcessor: Final drain complete. Buffer size: \(buffer.count)")

        } onGracefulShutdown: {
            // - Shutdown handler is synchronous! -
            // This is the first reliable place to know shutdown has started.
            // Signal the main loop to stop and prevent new log entries.
            // Use compareExchange to log only once if called multiple times.
            let alreadyShuttingDown = !self.isRunning.compareExchange(expected: true, desired: false, ordering: .relaxed).exchanged
            if !alreadyShuttingDown {
                self.logger?.trace("PostgresLogProcessor: Graceful shutdown signal received. Signalling run loop to stop and stopping acceptance of new logs.")
            } else {
                self.logger?.trace("PostgresLogProcessor: Graceful shutdown signal received again (already shutting down).")
            }
        }

        logger?.trace("PostgresLogProcessor run() finished.")
    }

    // Non-isolated synchronous function called by the LogHandler
    nonisolated public func enqueueLog(_ entry: LogEntry) {
        // Check if still running *before* creating the Task.
        // Use the same flag the run loop checks.
        guard self.isRunning.load(ordering: .relaxed) else {
            logger?.trace("PostgresLogProcessor: Discarding log message during shutdown: \(entry.message)")
            return
        }

        // Still running, create task to enqueue
        Task {  // Required to call isolated method from non-isolated context
            // Add a check inside the task as well, in case shutdown happens
            // between the guard above and this Task actually starting execution.
            guard await self.shouldAcceptEntry() else {
                // logger?.trace("PostgresLogProcessor: Discarding log message - shutdown occurred before actor task execution: \(entry.message)")
                return
            }
            await self.addEntry(entry)
        }
    }

    // Helper to check flag from isolated context
    private func shouldAcceptEntry() -> Bool {
        self.isRunning.load(ordering: .relaxed)
    }

    // Isolated method to add to the buffer
    private func addEntry(_ entry: LogEntry) {
        // No need to check flag here if we trust the checks in enqueueLog
        // and the final drain logic. Adding here ensures logs enqueued just
        // before shutdown signal are captured.
        buffer.append(entry)
        // logger?.trace("Log entry enqueued. Buffer size: \(buffer.count)")

        // If the buffer gets too large even between flush intervals, trigger an early flush.
        // if buffer.count >= maxBatchSize {
        //    Task { await self.processBuffer() } // Kick off processing asynchronously
        // }
    }

    // Processes the current contents of the buffer
    private func processBuffer() async {
        // Only process if there's something to process and we are still notionally running
        // (although the main loop controls *calling* this, this adds safety for manual calls)
        guard !buffer.isEmpty,
                self.isRunning.load(ordering: .relaxed) || !buffer.isEmpty /* Allow final drain */
        else {
            if !buffer.isEmpty {
                logger?.trace("PostgresLogProcessor: Skipping processBuffer as shutdown is complete and buffer should be drained.")
            }
            return
        }

        // Use a temporary batch to avoid holding up the actor if DB writes are slow
        let batchToProcess = buffer
        buffer.removeAll(keepingCapacity: true)  // Clear buffer immediately

        logger?.trace("Processing batch of \(batchToProcess.count) logs.")
        // If DB operation needs to be more robust, consider TaskGroup or similar
        // For now, sequential processing is simple.
        for entry in batchToProcess {
            // Make sure submitLogEntry handles its own errors robustly
            await submitLogEntry(entry)
        }
    }

    // Submits a single log entry to the database (async)
    private func submitLogEntry(_ entry: LogEntry) async {
        let lineNo = Int(entry.line)  // Convert UInt to Int for Postgres parameter. Othwerwise we get `Cannot convert value of type 'UInt' to expected argument type 'PostgresData'`
        
        // The manual bindings construction because:
        // - We want to allow the user to define the table's name, and we insert it with String interpolation
        // - Metadata can be nil or the encoding of Metadata can throw. Then we would have to write the large part the query three times
        
        var columns = ["label", "server_timestamp", "level", "message", "source", "file", "function", "line"]
        var valuesPlaceholders = ["$1", "$2", "$3", "$4", "$5", "$6", "$7", "$8"]
        var bindings = PostgresBindings()
        bindings.append(entry.label)
        bindings.append(entry.timestamp)
        bindings.append(entry.level.rawValue)
        bindings.append(entry.message.description)
        bindings.append(entry.source)
        bindings.append(entry.file)
        bindings.append(entry.function)
        bindings.append(lineNo)

        // Attempt to add metadata if it exists
        if let metadata = entry.metadata {
            do {
                // Try encoding and appending metadata *first*
                try bindings.append(metadata)  // This can throw because metadata is encoded as json

                // If successful, *then* update the columns and placeholders
                columns.append("metadata")
                valuesPlaceholders.append("$\(columns.count)")  // Next available placeholder index
            } catch {
                // If encoding fails, just log the error.
                // No need to modify columns or valuesPlaceholders as they weren't changed, as the `bindings.append(metadata)` failed in the 'do' block.
                logger?.error("Failed encoding metadata for logging to postgres: \(String(reflecting: error)). Entry: \(entry)")
            }
        }

        // Construct the final query string
        let columnsString = columns.joined(separator: ", ")
        let valuesString = valuesPlaceholders.joined(separator: ", ")
        let queryString = "INSERT INTO \(tableName) (\(columnsString)) VALUES (\(valuesString))"

        let insertionQuery = PostgresQuery(unsafeSQL: queryString, binds: bindings)

        do {
            _ = try await postgresClient.query(insertionQuery)
        } catch {
            logger?.error("‼️ Failed logging to postgres: \(String(reflecting: error)). Query: \(queryString), Bindings: \(bindings), Entry: \(entry)")
        }
    }

    // Deinit for cleanup confirmation
    deinit {
        // Ensure flag is false if deinit happens unexpectedly
        isRunning.store(false, ordering: .relaxed)
        logger?.trace("PostgresLogProcessor deinitialized.")
    }
}

public struct PostgresLogHandler: LogHandler {
    public var label: String
    public var logLevel: Logger.Level
    public var metadata: Logger.Metadata {
        get { sharedProcessorMetadata }
        set { sharedProcessorMetadata = newValue }
    }

    // The processor instance will be managed by the ServiceLifecycle container
    private let processor: PostgresLogProcessor
    private var sharedProcessorMetadata: Logger.Metadata

    public init(
        label: String,
        logLevel: Logger.Level = .debug,
        metadata: Logger.Metadata = .init(),
        processor: PostgresLogProcessor
    ) {
        self.label = label
        self.logLevel = logLevel
        self.sharedProcessorMetadata = metadata
        self.processor = processor
    }

    // LogHandler protocol requirement
    public func log(level: Logger.Level, message: Logger.Message, metadata logMetadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        // Filter out the logs below the configured level early
        guard level >= self.logLevel else { return }

        var effectiveMetadata = self.sharedProcessorMetadata
        if let logMetadata = logMetadata {
            effectiveMetadata.merge(logMetadata) { _, new in new }
        }

        let entry = LogEntry(
            label: self.label,
            level: level,
            message: message,
            metadata: effectiveMetadata.isEmpty ? nil : effectiveMetadata,
            source: source,
            file: file,
            function: function,
            line: line,
            timestamp: Date()
        )

        processor.enqueueLog(entry)
    }

    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            sharedProcessorMetadata[metadataKey]
        }
        set(newValue) {
            sharedProcessorMetadata[metadataKey] = newValue
        }
    }
}
