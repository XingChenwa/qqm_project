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
    // Fresh installs have no telemetry tables. Legacy history is never dropped or pruned.
    check((int)$core->query("SELECT count(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN ('qqm_installations','qqm_daily_usage')")->fetchColumn() === 0, 'Fresh install does not collect devices');
    $tables = $core->query("SELECT ENGINE,TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME LIKE 'qqm_%'")->fetchAll();
    check(count($tables) === 3, 'Three non-telemetry application tables');
    foreach ($tables as $table) { check($table['ENGINE'] === 'InnoDB' && $table['TABLE_COLLATION'] === 'utf8mb4_unicode_ci', 'InnoDB utf8mb4'); }
    $core->db->exec("CREATE TABLE qqm_installations (id INT PRIMARY KEY, legacy_data VARCHAR(64)) ENGINE=InnoDB");
    $core->db->exec("CREATE TABLE qqm_daily_usage (id INT PRIMARY KEY, legacy_data VARCHAR(64)) ENGINE=InnoDB");
    foreach (['qqm_installations','qqm_daily_usage'] as $table) { $core->query("INSERT INTO $table VALUES (1, ?)", ['history-must-remain']); }
    $core->initializeSchema(); $core->prune();
    foreach (['qqm_installations','qqm_daily_usage'] as $table) { check($core->query("SELECT legacy_data FROM $table WHERE id=1")->fetchColumn() === 'history-must-remain', 'Legacy history retained'); }
    rejects(fn() => new Core(dirname(__DIR__), $path, ['database' => array_replace($database, ['name' => 'unsafe;dbname=another'])]));
    rejects(fn() => new Core(dirname(__DIR__), $path, ['database' => array_replace($database, ['port' => 0])]));
    rejects(fn() => new Core(dirname(__DIR__), $path, ['database' => null]));
    rejects(fn() => new Core(dirname(__DIR__), $path, ['database' => array_replace($database, ['password' => 'deliberately-incorrect-fixture-password'])]));
    check(!is_file($path . '/manager.sqlite'), 'No SQLite fallback');
    echo "MySQL schema/config: {$passed} checks passed.\n";
} finally {
    unset($core); if (is_dir($path) && dirname($path) === sys_get_temp_dir() && str_starts_with(basename($path), 'qqm-schema-test-')) { rmdir($path); }
}
