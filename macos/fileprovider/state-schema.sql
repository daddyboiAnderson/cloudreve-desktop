-- Version 1. Shared by the Rust host and Swift extension. Changes must be
-- additive while either process from the previous build can still be running.
CREATE TABLE IF NOT EXISTS fp_state_schema (version INTEGER NOT NULL);
INSERT INTO fp_state_schema SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM fp_state_schema);
CREATE TABLE IF NOT EXISTS fp_event_heads (
    drive TEXT PRIMARY KEY NOT NULL,
    latest INTEGER NOT NULL DEFAULT 0,
    floor INTEGER NOT NULL DEFAULT 0,
    imported INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS fp_events (
    drive TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    payload TEXT NOT NULL,
    PRIMARY KEY (drive, sequence)
);
CREATE TABLE IF NOT EXISTS fp_records (
    namespace TEXT NOT NULL,
    key TEXT NOT NULL,
    payload TEXT NOT NULL,
    PRIMARY KEY (namespace, key)
);
CREATE TABLE IF NOT EXISTS fp_imports (
    namespace TEXT PRIMARY KEY NOT NULL
);
CREATE TABLE IF NOT EXISTS fp_deliveries (id TEXT PRIMARY KEY NOT NULL);
