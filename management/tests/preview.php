<?php
// Local preview only. Never run this as production initialization.
declare(strict_types=1);
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require dirname(__DIR__) . '/src/Core.php';
require __DIR__ . '/database.php';
$path = getenv('QQM_DATA_DIR') ?: '';
if (basename($path) !== 'management-preview' || !str_contains(str_replace('\\', '/', $path), '/build/')) { throw new RuntimeException('Preview data must stay in this task build directory.'); }
if (!is_dir($path)) { mkdir($path, 0700, true); }
if (!is_file($path . '/config.json')) {
    $keys = sodium_crypto_sign_keypair();
    file_put_contents($path . '/config.json', json_encode(['environment' => 'development', 'app_url' => 'http://127.0.0.1:8987', 'signing_secret' => base64_encode(sodium_crypto_sign_secretkey($keys))], JSON_THROW_ON_ERROR));
    chmod($path . '/config.json', 0600);
}
$config = json_decode(file_get_contents($path . '/config.json'), true, 32, JSON_THROW_ON_ERROR);
$config['database'] = testDatabase('preview');
unset($config['admin_user'], $config['admin_password_hash']);
file_put_contents($path . '/config.json', json_encode($config, JSON_THROW_ON_ERROR), LOCK_EX); chmod($path . '/config.json', 0600);
$core = new QQM\Core(dirname(__DIR__), $path, [], false); $core->initializeSchema();
echo "Local-only MySQL preview initialized. No QQ account or real user data.\n";
