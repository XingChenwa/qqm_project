<?php
// Bootstrap only the new loopback instance started by tests/mysql.mjs, never a service database.
declare(strict_types=1);
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
$file = getenv('QQM_TEST_DATABASE_CONFIG') ?: '';
$config = json_decode(file_get_contents($file), true, 16, JSON_THROW_ON_ERROR);
$connection = $config['connection'];
if ($connection['host'] !== '127.0.0.1' || $connection['port'] < 1024 || in_array($connection['port'], [3306, 33060], true)
    || $connection['username'] !== 'qqm_test') { throw new RuntimeException('Refusing a non-isolated server'); }
$pdo = new PDO('mysql:host=127.0.0.1;port=' . $connection['port'] . ';charset=utf8mb4', 'root', '', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$pdo->exec("CREATE USER 'qqm_test'@'127.0.0.1' IDENTIFIED BY " . $pdo->quote($connection['password']));
foreach ($config['databases'] as $name) {
    if (!preg_match('/^qqm_test_[a-z]+_[a-f0-9]{12}$/D', $name)) { throw new RuntimeException('Unsafe test database name'); }
    $pdo->exec("CREATE DATABASE `{$name}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
    $pdo->exec("GRANT ALL PRIVILEGES ON `{$name}`.* TO 'qqm_test'@'127.0.0.1'");
}
echo 'Isolated server ready: ' . $pdo->getAttribute(PDO::ATTR_SERVER_VERSION) . "\n";
