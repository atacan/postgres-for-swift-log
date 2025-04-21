import Logging
import LoggingToPostgres
import NIOCore  // For EventLoopGroup
import NIOPosix  // For EventLoopGroup implementation
import PostgresNIO
import ServiceLifecycle  // Required for ServiceGroup and running services

// Use a real logger for bootstrapping and internal processor logs
var bootstrapLogger = Logger(label: "bootstrap")
bootstrapLogger.logLevel = .debug

// Remember to create the table in Postgres before running the app

// 1. Configure PostgresClient
// Ensure you have an EventLoopGroup
let postgresClient = PostgresClient(
    configuration: .init(
        host: "localhost",  // Your DB host
        username: "",  // Your DB user
        password: "",  // Your DB password
        database: "",  // Your DB name
        tls: .disable  // Or configure TLS as needed
    ),
    backgroundLogger: bootstrapLogger  // Logger for the client itself
)

// 2. Configure PostgresLogProcessor
let logProcessor = PostgresLogProcessor(
    configuration: .init(
        postgresClient: postgresClient,
        tableName: "logs",  // *** Use the table name you created ***
        maxBatchSize: 50,  // Optional: Max logs per DB write
        flushInterval: .seconds(5),  // Optional: How often to write to DB
        logger: bootstrapLogger  // Logger for the processor's internal logs
    )
)

// 3. Create your main application logger to record logs to Postgres
let logger = Logger(label: "YourApp") { label in
    // This factory creates the handler using the shared processor
    PostgresLogHandler(
        label: label,
        logLevel: .info,  // Minimum level to send to Postgres
        metadata: ["app_version": "1.0.0"],  // Optional: Base metadata
        processor: logProcessor
    )
}

// Define a service for the main application logic
struct AppLogicService: Service {
    let logger: Logger  // This logger will record logs to Postgres
    let bootstrapLogger: Logger  // This logger will record logs to the console

    func run() async throws {
        // Log that this service is starting
        bootstrapLogger.info("AppLogicService running...")

        // Give other services a moment to potentially start up if needed
        // In a real app, you might use more robust readiness checks
        try await Task.sleep(for: .milliseconds(100))  // Small delay

        // Perform the application logging
        logger.info("Application started successfully.", metadata: ["user_id": "123"])
        logger.warning("A non-critical issue occurred.")
        logger.error("Something went wrong!", metadata: ["error_code": "DB500"])

        bootstrapLogger.info(
            "AppLogicService finished initial tasks, waiting for shutdown signal...")

        // Wait until the service is shut down
        try? await gracefulShutdown()

        bootstrapLogger.info("AppLogicService run method finished.")
    }
}

// 4. Prepare and run services using ServiceLifecycle
let appLogicService = AppLogicService(logger: logger, bootstrapLogger: bootstrapLogger)

let serviceGroup = ServiceGroup(
    configuration: .init(
        services: [
            postgresClient,
            logProcessor,
            appLogicService,  // Add the application logic service
        ],
        gracefulShutdownSignals: [.sigint, .sigterm],  // Handle OS signals
        logger: bootstrapLogger
    )
)

do {
    bootstrapLogger.info("App starting...")

    // Run the service group - this starts the client, the log processor, and app logic
    try await serviceGroup.run()

    // This line will now execute *after* the ServiceGroup has shut down
    bootstrapLogger.info("App finished cleanly.")

} catch {
    bootstrapLogger.error("Application failed to run: \(error)")
    // Attempt graceful shutdown even on error (ServiceGroup might handle some of this)
    await serviceGroup.triggerGracefulShutdown()

    throw error
}
