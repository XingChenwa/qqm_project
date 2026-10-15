<?php
declare(strict_types=1);

/** Only credentials for the task's isolated loopback test server are accepted. */
function testDatabase(string $suite): array
{
    $file = getenv('QQM_TEST_DATABASE_CONFIG') ?: '';
    if ($file === '' || !is_file($file)) { throw new RuntimeException('Run the isolated MySQL test runner first; never use a production database.'); }
    $config = json_decode(file_get_contents($file), true, 16, JSON_THROW_ON_ERROR);
    $database = $config['connection']; $database['name'] = $config['databases'][$suite] ?? '';
    if ($database['host'] !== '127.0.0.1' || $database['port'] < 1024 || in_array($database['port'], [3306, 33060], true)
        || $database['username'] !== 'qqm_test' || !preg_match('/^qqm_test_[a-z]+_[a-f0-9]{12}$/D', $database['name'])) {
        throw new RuntimeException('Refusing non-isolated test database configuration.');
    }
    return $database;
}
