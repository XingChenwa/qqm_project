<?php
declare(strict_types=1);
require dirname(__DIR__) . '/src/Core.php';
require __DIR__ . '/database.php';
use QQM\Core;
use QQM\HttpError;
$path = sys_get_temp_dir() . '/qqm-schema-test-' . bin2hex(random_bytes(8));
$database = testDatabase('schema'); $passed = 0;
function check(bool $condition, string $name): void { global $passed; if (!$condition) { throw new RuntimeException($name); } $passed++; }
function rejects(Closure $call): void { try { $call(); } catch (HttpError $error) { check($error->status === 503, 'Safe configuration error'); return; } throw new RuntimeException('Expected configuration failure'); }
try {
    rejects(fn() => new Core(dirname(__DIR__), $path, ['database' => $database]));
    $core = new Core(dirname(__DIR__), $path, ['database' => $database], false); $core->initializeSchema();
    check($core->db->getAttribute(PDO::ATTR_DRIVER_NAME) === 'mysql', 'MySQL driver');
    check(!$core->db->getAttribute(PDO::ATTR_EMULATE_PREPARES), 'Native prepared statements');
    check((int)$core->query('SELECT MAX(version) FROM qqm_schema_migrations')->fetchColumn() === Core::SCHEMA_VERSION, 'Current schema version');
    // Simulate the deployed v1 table, with an existing installation that must survive.
    $id = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'; $now = time();
    $core->query('INSERT INTO qqm_installations(id,token_hash,platform,version,build,first_seen,last_seen,ip_updated_at) VALUES(?,?,?,?,?,?,?,?)', [$id, str_repeat('a', 64), 'windows', '1.3.0', 11, $now, $now, $now]);
    foreach (['device_name','device_model','system_version','system_arch'] as $column) { $core->db->exec('ALTER TABLE qqm_installations DROP COLUMN ' . $column); }
    $core->query('DELETE FROM qqm_schema_migrations WHERE version=2');
    rejects(fn() => new Core(dirname(__DIR__), $path, ['database' => $database]));
    $core->initializeSchema(); $core->initializeSchema();
    $retained = $core->query('SELECT * FROM qqm_installations WHERE id=?', [$id])->fetch();
    check($retained['version'] === '1.3.0' && $retained['build'] === 11, 'v1 migration preserves existing installation');
    check(array_key_exists('device_name', $retained) && $retained['device_name'] === null, 'v2 nullable device columns added');
    check((int)$core->query('SELECT COUNT(*) FROM qqm_schema_migrations WHERE version=2')->fetchColumn() === 1, 'Migration is idempotent');
    $tables = $core->query("SELECT ENGINE,TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME LIKE 'qqm_%'")->fetchAll();
    check(count($tables) === 5, 'Five application tables');
    foreach ($tables as $table) { check($table['ENGINE'] === 'InnoDB' && $table['TABLE_COLLATION'] === 'utf8mb4_unicode_ci', 'InnoDB utf8mb4'); }
    rejects(fn() => new Core(dirname(__DIR__), $path, ['database' => array_replace($database, ['name' => 'unsafe;dbname=another'])]));
    rejects(fn() => new Core(dirname(__DIR__), $path, ['database' => array_replace($database, ['port' => 0])]));
    rejects(fn() => new Core(dirname(__DIR__), $path, ['database' => null]));
    rejects(fn() => new Core(dirname(__DIR__), $path, ['database' => array_replace($database, ['password' => 'deliberately-incorrect-fixture-password'])]));
    check(!is_file($path . '/manager.sqlite'), 'No SQLite fallback');
    echo "MySQL schema/config: {$passed} checks passed.\n";
} finally {
    unset($core); if (is_dir($path) && dirname($path) === sys_get_temp_dir() && str_starts_with(basename($path), 'qqm-schema-test-')) { rmdir($path); }
}
