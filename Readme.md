# LoggingToPostgres

[![Swift](https://img.shields.io/badge/Swift-6.1+-orange.svg)](https://swift.org)
[![SwiftLog](https://img.shields.io/badge/SwiftLog-1.5+-blue.svg)](https://github.com/apple/swift-log)
[![PostgresNIO](https://img.shields.io/badge/PostgresNIO-1.25+-green.svg)](https://github.com/vapor/postgres-nio)
[![ServiceLifecycle](https://img.shields.io/badge/ServiceLifecycle-2.0+-purple.svg)](https://github.com/swift-server/swift-service-lifecycle)

A backend handler for [apple/swift-log](https://github.com/apple/swift-log) that sends log entries to a PostgreSQL database using [vapor/postgres-nio](https://github.com/vapor/postgres-nio). It integrates seamlessly with the [swift-server/swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle) for robust application lifecycle management, including graceful shutdown.

## Features

*   **SwiftLog Backend:** Implements the `LogHandler` protocol from `swift-log`.
*   **Asynchronous Processing:** Uses an actor (`PostgresLogProcessor`) to buffer log entries and perform database writes asynchronously, minimizing impact on application performance.
*   **Buffering & Batching:** Configurable maximum batch size and flush interval for efficient database insertion.
*   **Graceful Shutdown:** Conforms to the `Service` protocol from `swift-service-lifecycle`. During shutdown, it stops accepting new logs and ensures all buffered logs are written to the database before terminating.
*   **PostgresNIO Integration:** Leverages the non-blocking `PostgresNIO` library for database interaction.
*   **Customizable:** Allows specifying the target PostgreSQL table name.
*   **Metadata Support:** Persists `Logger.Metadata` as a `JSONB` column in the database.

## Requirements

*   Swift 6.1+ (_TODO: could be 5.9_)
*   An application using `swift-log`.
*   Access to a PostgreSQL database.
*   Dependencies: `swift-log`, `postgres-nio`, `swift-service-lifecycle`.

## Database Setup

You need to create a table in your PostgreSQL database to store the log entries. You can choose any name for the table. Here is a recommended schema:

```sql
-- Choose a name for your table (e.g., 'logs', 'application_logs')
-- Replace 'logs' below with your chosen name if different.

CREATE TABLE logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(), -- Unique identifier for each log entry
    label TEXT, -- Label of the Logger instance (e.g., 'App', 'DatabaseService')
    server_timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP, -- Timestamp when the logger log method is called
    level TEXT NOT NULL, -- Log level (e.g., 'debug', 'info', 'error')
    message TEXT NOT NULL, -- The log message itself
    metadata JSONB, -- Metadata associated with the log message
    source TEXT, -- Source module of the log message (if provided by swift-log)
    file TEXT, -- File where the log message originated
    function TEXT, -- Function where the log message originated
    line INTEGER, -- Line number where the log message originated
    -- The 'created_at' column below captures the DB insertion time, different than the server_timestamp as the logs are recorded in batches
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Optional indexes for better query performance:
CREATE INDEX idx_logs_level ON logs (level);
CREATE INDEX idx_logs_server_timestamp ON logs (server_timestamp DESC);
CREATE INDEX idx_logs_level_server_timestamp ON logs (level, server_timestamp DESC);
CREATE INDEX idx_logs_label ON logs (label); -- If querying by logger label often
CREATE INDEX idx_logs_metadata ON logs USING gin (metadata); -- If querying JSONB metadata often
```

Remember the table name you choose, as you'll need it when configuring the `PostgresLogProcessor`.

## Usage

1.  **Configure `PostgresClient`:** Set up your database connection using `PostgresNIO`.
2.  **Configure `PostgresLogProcessor`:** Create an instance, providing the `PostgresClient`, your chosen table name, and optional batching/flushing parameters. This processor is an `actor` and conforms to the `Service` protocol.
3.  **Create Logger:** Instantiate a `Logger` using the `PostgresLogHandler` factory, passing the processor instance.
4.  **Run Services:** Both the `PostgresClient` and `PostgresLogProcessor` need to be run. Typically, this is done using a `ServiceGroup` from `swift-service-lifecycle`.
5.  **Log Messages:** Use the logger instance as you would with any `swift-log` logger.

### Short Example

```swift
let postgresClient = PostgresNIO.PostgresClient(/*...*/)
let logProcessor = PostgresLogProcessor(
    configuration: .init(
        postgresClient: postgresClient,
        tableName: "logs", // *** Use the table name you created ***
        maxBatchSize: 50, // Optional: Max logs per DB write
        flushInterval: .seconds(5), // Optional: How often to write to DB
        logger: bootstrapLogger // Logger for the processor's internal logs
    )
)
let logger = Logger(
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
logger.info("Hello, Postgres!", metadata: ["Example": .string("metadata")])
```

### Full Example

[ServiceGroupExample](Examples/ServiceGroupExample/Sources/main.swift)

## Configuration

The `PostgresLogProcessor.Configuration` allows you to customize:

*   `postgresClient`: The `PostgresNIO.PostgresClient` instance. (Required)
*   `tableName`: The name of your PostgreSQL log table. (Required)
*   `maxBatchSize`: The maximum number of log entries to accumulate before forcing a flush to the database. Defaults to `100`.
*   `flushInterval`: The maximum time interval between database flushes, even if `maxBatchSize` is not reached. Defaults to `5` seconds.
*   `logger`: An optional separate `Logger` instance to log the internal operations of the `PostgresLogProcessor` itself (e.g., for debugging).

## Metadata Handling

*   Metadata provided directly to a log call (`logger.info("Message", metadata: ["key": "value"])`) is merged with any metadata attached to the `PostgresLogHandler` instance itself.
*   The combined metadata is stored in the `metadata` JSONB column in your PostgreSQL table.
*   If metadata is empty or `nil`, the `metadata` column will be `NULL`.

## Graceful Shutdown

When the `ServiceGroup` initiates a shutdown (e.g., upon receiving `SIGINT` or `SIGTERM`), the `PostgresLogProcessor`:

1.  Immediately stops accepting new log entries via `enqueueLog`.
2.  Signals its internal processing loop to stop after the current sleep/flush cycle.
3.  Performs a final flush of any remaining entries in its buffer to the database.
4.  Shuts down cleanly.

This ensures that logs generated right before shutdown are not lost.

## Installation

Add `LoggingToPostgres` as a dependency to your `Package.swift` file:

```swift
// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "YourPackageName",
    platforms: [
       .macOS(.v13) // Or your target platform
    ],
    dependencies: [
        .package(url: "https://github.com/atacan/postgres-for-swift-log.git", from: "0.0.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.2"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.25.0"),
        // ... other dependencies
    ],
    targets: [
        .target(
            name: "YourTargetName",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "LoggingToPostgres", package: "postgres-for-swift-log"),
                // ... other dependencies
            ]
        ),
        // ... other targets
    ]
)
```