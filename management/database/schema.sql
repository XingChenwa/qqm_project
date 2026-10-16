-- Select the dedicated database created in BaoTa before importing this file.
-- No CREATE DATABASE, DROP, root account or credentials are included.
CREATE TABLE IF NOT EXISTS qqm_schema_migrations (
    version INT UNSIGNED NOT NULL PRIMARY KEY,
    installed_at BIGINT UNSIGNED NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS qqm_releases (
    id CHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    platform VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    arch VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    version VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    build INT UNSIGNED NOT NULL,
    `format` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    filename VARCHAR(160) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    sha256 CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    size BIGINT UNSIGNED NOT NULL,
    notes TEXT NOT NULL,
    published TINYINT UNSIGNED NOT NULL DEFAULT 0,
    force_update TINYINT UNSIGNED NOT NULL DEFAULT 0,
    created_at BIGINT UNSIGNED NOT NULL,
    UNIQUE KEY qqm_release_build (platform,arch,build),
    KEY qqm_release_latest (platform,arch,published,build),
    KEY qqm_release_hash (sha256)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Legacy telemetry tables are deliberately not recreated or dropped.
-- Existing qqm_installations / qqm_daily_usage remain untouched on upgrades.

CREATE TABLE IF NOT EXISTS qqm_limits (
    id CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    bucket_start BIGINT UNSIGNED NOT NULL,
    hits INT UNSIGNED NOT NULL,
    KEY qqm_limit_bucket (bucket_start)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- The CLI install/db-init completes the current schema without deleting historical tables.
INSERT INTO qqm_schema_migrations(version,installed_at) VALUES(1,UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE version=version;
