import Logging
@testable import LoggingToPostgres
import PostgresNIO
import Testing

struct LoggingToPostgresTests {
    let logger = Logger(label: "LoggingToPostgresTests")
    
    init() {
        logger.info("Initializing...")
        defer {
            logger.info("Initialization complete.")
        }
    }
    
    @Test func example() async throws {
        let postgresClient = PostgresClient(
            configuration: .init(
                host: "localhost",
                username: "postgres",
                password: "",
                database: "postgres",
                tls: .disable
            ),
            backgroundLogger: logger
        )
        let postgresLogProcessor = PostgresLogProcessor(
            configuration: .init(
                postgresClient: postgresClient,
                tableName: "logs",
                maxBatchSize: 1,
                flushInterval: .seconds(0.1),
                logger: logger
            )
        )
        
        let loggerToPostgres = Logger(
            label: "postgresActorLogHandler",
            factory: { label in
                PostgresLogHandler(
                    label: label,
                    logLevel: Logger.Level.debug,
                    metadata: Logger.Metadata(),
                    processor: postgresLogProcessor
                )
            }
        )
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await postgresClient.run()
            }
            
            group.addTask {
                try await postgresLogProcessor.run()
            }
            
            // wait for postgresClient.run() to be called
            // otherwise: "trying to lease connection from `PostgresClient`, but `PostgresClient.run()` hasn't been called yet."
            // but still works
            try await Task.sleep(for: .seconds(0.3))
            do {
                let rows = try await postgresClient.query("Select 1", logger: self.logger)
                for try await row in rows { logger.debug("Postgres is running! \(row)") }
                
                // the moment of truth
                loggerToPostgres.info("Hello, Postgres!", metadata: ["Example": .string("metadata")])
            } catch {
                logger.error("⚠️ \(String(reflecting: error))")
                throw error
            }
            
            
            // wait for logging processor to handle the buffer before ending the task group
            try await Task.sleep(for: .seconds(0.3))
            group.cancelAll()
        }
    }
}
