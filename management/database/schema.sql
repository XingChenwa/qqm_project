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
    created_at BIGINT UNSIGNED NOT NULL,
    UNIQUE KEY qqm_release_build (platform,arch,build),
    KEY qqm_release_latest (platform,arch,published,build),
    KEY qqm_release_hash (sha256)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS qqm_installations (
    id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    token_hash CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    platform VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    version VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    build INT UNSIGNED NOT NULL,
    first_seen BIGINT UNSIGNED NOT NULL,
    last_seen BIGINT UNSIGNED NOT NULL,
    last_ip VARCHAR(45) CHARACTER SET ascii COLLATE ascii_bin NULL,
    ip_source VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    ip_updated_at BIGINT UNSIGNED NOT NULL,
    device_name VARCHAR(128) NULL,
    device_model VARCHAR(128) NULL,
    system_version VARCHAR(255) NULL,
    system_arch VARCHAR(64) NULL,
    UNIQUE KEY qqm_install_token (token_hash),
    KEY qqm_install_seen (last_seen)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS qqm_daily_usage (
    day DATE NOT NULL,
    installation_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    PRIMARY KEY (day,installation_id),
    KEY qqm_usage_install (installation_id),
    CONSTRAINT qqm_usage_install_fk FOREIGN KEY (installation_id) REFERENCES qqm_installations(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS qqm_limits (
    id CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    bucket_start BIGINT UNSIGNED NOT NULL,
    hits INT UNSIGNED NOT NULL,
    KEY qqm_limit_bucket (bucket_start)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- The CLI install/db-init completes version 2, including safe migration of older tables.
INSERT INTO qqm_schema_migrations(version,installed_at) VALUES(1,UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE version=version;
