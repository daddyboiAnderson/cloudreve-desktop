CREATE TABLE IF NOT EXISTS fileprovider_remote_items (
    drive_id TEXT NOT NULL,
    remote_id TEXT NOT NULL,
    uri TEXT NOT NULL,
    parent_uri TEXT NOT NULL,
    is_folder BOOLEAN NOT NULL,
    version TEXT NOT NULL,
    seen_generation BIGINT NOT NULL,
    PRIMARY KEY (drive_id, remote_id)
);

CREATE INDEX IF NOT EXISTS idx_fileprovider_remote_items_drive_uri
    ON fileprovider_remote_items (drive_id, uri);
