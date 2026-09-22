CREATE TABLE fileprovider_outbox (
    id TEXT PRIMARY KEY NOT NULL,
    drive TEXT NOT NULL,
    payload TEXT NOT NULL
);
