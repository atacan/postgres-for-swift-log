
```sql
-- Create the table to store logs
CREATE TABLE logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(), -- Unique identifier for each log entry
    label TEXT, -- Label of the log message, NOT NULL as label is always provided
    server_timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP, -- Timestamp of when the log was recorded, automatically set to current time
    level TEXT NOT NULL, -- Log level, using the defined enum, NOT NULL as level is always provided
    message TEXT NOT NULL, -- The log message itself, NOT NULL as message is always provided
    metadata JSONB, -- Metadata associated with the log message, stored as JSONB for flexibility
    source TEXT, -- Source of the log message (e.g., module name)
    file TEXT, -- File where the log message originated
    function TEXT, -- Function where the log message originated
    line INTEGER, -- Line number where the log message originated
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Optionally add indexes for faster querying, especially if you plan to filter or sort by level or timestamp frequently
CREATE INDEX idx_logs_level ON logs (level);
CREATE INDEX idx_logs_server_timestamp ON logs (server_timestamp DESC); -- Index timestamp in descending order for recent logs first
CREATE INDEX idx_logs_level_server_timestamp ON logs (level, server_timestamp DESC); -- Combined index for level and timestamp for ordered queries
```