<?php
declare(strict_types=1);
require dirname(__DIR__) . '/src/Core.php';
require __DIR__ . '/database.php';
use QQM\Core;
use QQM\HttpError;

$passed = 0;
function check(bool $condition, string $message): void { global $passed; if (!$condition) { throw new RuntimeException($message); } $passed++; }
function rejects(callable $call, int $status): void { try { $call(); } catch (HttpError $error) { check($error->status === $status, 'Unexpected HTTP status'); return; } throw new RuntimeException('Expected rejection'); }
$directory = sys_get_temp_dir() . '/qqm-backend-test-' . bin2hex(random_bytes(8));
$keys = sodium_crypto_sign_keypair();
$overrides = ['database' => testDatabase('core'), 'environment' => 'development', 'app_url' => 'https://botmanager.uuze.cn', 'signing_secret' => base64_encode(sodium_crypto_sign_secretkey($keys)), 'origin_token' => 'synthetic-test-origin-token', 'trusted_proxy_cidrs' => ['192.0.2.0/24', '2001:db8::/32']];
$core = new Core(dirname(__DIR__), $directory, $overrides, false);
$core->initializeSchema();
try {
    check($core->db->getAttribute(PDO::ATTR_DRIVER_NAME) === 'mysql', 'Real MySQL PDO driver');
    $core->initializeSchema(); check((int)$core->query('SELECT MAX(version) FROM qqm_schema_migrations')->fetchColumn() === Core::SCHEMA_VERSION, 'Idempotent schema setup');
    check(Core::inCidr('192.0.2.14', '192.0.2.0/24'), 'IPv4 range');
    check(!Core::inCidr('198.51.100.2', '192.0.2.0/24'), 'Outside IPv4 range');
    check(Core::inCidr('2001:db8::1', '2001:db8::/32'), 'IPv6 range');
    check(!Core::inCidr('192.0.2.1', '0.0.0.0/0'), 'Do not trust every proxy');
    $server = ['REMOTE_ADDR' => '192.0.2.2', 'HTTP_EO_CONNECTING_IP' => '203.0.113.5', 'HTTP_X_QQM_ORIGIN_TOKEN' => 'synthetic-test-origin-token'];
    check($core->clientIp($server)['ip'] === '203.0.113.5', 'Trusted EdgeOne IP');
    check($core->clientIp(array_replace($server, ['REMOTE_ADDR' => '198.51.100.4']))['ip'] === '198.51.100.4', 'Spoofed proxy');
    check($core->clientIp(array_replace($server, ['HTTP_X_QQM_ORIGIN_TOKEN' => 'fake']))['ip'] === '192.0.2.2', 'Spoofed origin token');
    check($core->clientIp(array_replace($server, ['HTTP_EO_CONNECTING_IP' => '203.0.113.1,1.1.1.1']))['ip'] === '192.0.2.2', 'Reject IP list');
    check($core->proxyDiagnostics($server)['reason'] === 'accepted', 'Strict diagnostic accepts token plus network');
    check($core->proxyDiagnostics(array_replace($server, ['QQM_PROXY_ADDR' => '198.51.100.4']))['reason'] === 'proxy_not_in_trusted_cidrs', 'Original TCP peer is used even if REMOTE_ADDR was rewritten');
    $free = new Core(dirname(__DIR__), $directory, array_replace($overrides, ['proxy_trust_mode' => 'edgeone_token', 'require_origin_token' => true, 'trusted_proxy_cidrs' => []]));
    check($free->clientIp($server)['ip'] === '203.0.113.5', 'Free EdgeOne mode accepts authenticated header without CIDR');
    $free->checkOriginToken($server); check(true, 'Correct free-mode origin token admitted');
    check($free->clientIp(array_replace($server, ['HTTP_EO_CONNECTING_IP' => '2001:db8::42']))['ip'] === '2001:db8::42', 'Free mode IPv6 client');
    check($free->clientIp(array_replace($server, ['HTTP_EO_CONNECTING_IP' => " 203.0.113.5\t"]))['ip'] === '203.0.113.5', 'Optional HTTP header whitespace');
    foreach (['203.0.113.1, 1.1.1.1', '203.0.113.1:443', "203.0.113.1\r\n", '<script>'] as $invalid) {
        check($free->proxyDiagnostics(array_replace($server, ['HTTP_EO_CONNECTING_IP' => $invalid]))['reason'] === 'client_ip_header_invalid', 'Free mode rejects malformed or duplicate IP headers');
    }
    $withoutToken = $server; unset($withoutToken['HTTP_X_QQM_ORIGIN_TOKEN']);
    check($free->clientIp($withoutToken)['ip'] === '192.0.2.2', 'Missing token cannot authenticate forwarded IP');
    check($free->proxyDiagnostics($withoutToken)['reason'] === 'origin_token_missing', 'Diagnostic identifies missing token');
    rejects(fn() => $free->checkOriginToken($withoutToken), 403);
    $wrongToken = array_replace($server, ['HTTP_X_QQM_ORIGIN_TOKEN' => 'wrong']);
    check($free->proxyDiagnostics($wrongToken)['reason'] === 'origin_token_mismatch', 'Diagnostic identifies wrong token');
    rejects(fn() => $free->checkOriginToken($wrongToken), 403);
    rejects(fn() => $free->checkOriginToken(array_replace($server, ['HTTP_X_QQM_ORIGIN_TOKEN' => ['invalid-type']])), 403);
    $withoutHeader = $server; unset($withoutHeader['HTTP_EO_CONNECTING_IP']);
    $withoutHeader['HTTP_X_FORWARDED_FOR'] = '203.0.113.99'; $withoutHeader['HTTP_X_REAL_IP'] = '203.0.113.99';
    check($free->proxyDiagnostics($withoutHeader)['reason'] === 'client_ip_header_missing', 'Never falls back to user-supplied XFF/X-Real-IP');
    check($free->clientIp(array_replace($server, ['QQM_PROXY_ADDR' => 'invalid']))['ip'] === null, 'Invalid original peer cannot authenticate an IP header');
    $diagnostic = $free->proxyDiagnostics($server);
    check($diagnostic['trusted_cidrs_count'] === 0 && !$diagnostic['proxy_peer_trusted'] && $diagnostic['origin_token_matches'], 'Free-mode diagnostics distinguish token trust from CIDR trust');
    check(!str_contains(json_encode($diagnostic), $overrides['origin_token']) && !str_contains(json_encode($diagnostic), $overrides['signing_secret']), 'Diagnostic contains neither origin nor signing secret');
    $unconfigured = new Core(dirname(__DIR__), $directory, array_replace($overrides, ['origin_token' => '', 'proxy_trust_mode' => 'edgeone_token', 'require_origin_token' => true]));
    check($unconfigured->proxyDiagnostics($server)['reason'] === 'origin_token_not_configured', 'Empty secret never authenticates free mode');
    rejects(fn() => $unconfigured->checkOriginToken($server), 403);
    $fields = ['installation_id' => '11111111-2222-4333-8444-555555555555', 'consent_version' => '1', 'platform' => 'windows', 'version' => '1.3.0', 'build' => 11];
    rejects(fn() => $core->register(array_replace($fields, ['consent_version' => '']), $core->clientIp($server)), 422);
    $token = $core->register($fields, $core->clientIp($server))['token'];
    check(strlen($token) === 64, 'Installation token');
    check($core->stats()['online'] === 1, 'Online count');
    $core->heartbeat($fields, $token, $core->clientIp($server)); $core->heartbeat($fields, $token, $core->clientIp($server));
    check($core->stats()['today'] === 1, 'Daily deduplication');
    check($core->stats()['devices'][0]['device_name'] === null, 'Legacy client without device data remains supported');
    $deviceFields = ['device_name' => '测试电脑 🤖', 'device_model' => '测试型号', 'system_version' => 'Windows 11', 'system_arch' => 'x64'];
    $core->heartbeat(array_replace($fields, $deviceFields), $token, $core->clientIp($server));
    $device = $core->stats()['devices'][0];
    foreach ($deviceFields as $name => $value) { check($device[$name] === $value, 'Allowed device field stored: ' . $name); }
    $core->heartbeat($fields, $token, $core->clientIp($server));
    check($core->stats()['devices'][0]['device_name'] === $deviceFields['device_name'], 'Legacy heartbeat does not erase newer device metadata');
    foreach (['device_name' => str_repeat('机', 129), 'device_model' => [], 'system_version' => "bad\r\nvalue", 'system_arch' => 42] as $name => $value) {
        rejects(fn() => $core->heartbeat(array_replace($fields, [$name => $value]), $token, $core->clientIp($server)), 422);
    }
    check(!array_key_exists('serial_number', Core::deviceFields(['serial_number' => 'never-stored'])), 'No arbitrary hardware metadata stored');
    rejects(fn() => $core->heartbeat($fields, str_repeat('0', 64), $core->clientIp($server)), 401);
    rejects(fn() => $core->heartbeat(array_replace($fields, ['platform' => 'android']), $token, $core->clientIp($server)), 422);
    rejects(fn() => $core->register($fields, $core->clientIp($server)), 409);
    $zipPath = $directory . '/fixture.zip'; $zip = new ZipArchive(); $zip->open($zipPath, ZipArchive::CREATE);
    foreach (['qq_bot_manager.exe', 'flutter_windows.dll', 'data/app.so'] as $name) { $zip->addFromString($name, 'synthetic-fixture'); } $zip->close();
    $release = $core->addRelease(['platform' => 'windows', 'version' => '1.3.0', 'build' => 11, 'arch' => 'x64', 'format' => 'zip', 'notes' => '测试发布 🤖'], $zipPath, false);
    check($release['notes'] === '测试发布 🤖', 'utf8mb4 Chinese and emoji');
    check($release['force_update'] === false, 'Force update defaults off');
    check(count($core->releases()) === 0, 'Draft not public');
    $nonce = '11111111-2222-4333-8444-555555555555';
    $empty = $core->signedUpdate('windows', 'x64', $nonce);
    check(json_decode(base64_decode($empty['payload']), true)['release'] === null, 'Draft not an update');
    $core->publish($release['id'], true);
    $envelope = $core->signedUpdate('windows', 'x64', $nonce); $payload = base64_decode($envelope['payload']);
    check(sodium_crypto_sign_verify_detached(base64_decode($envelope['signature']), $payload, sodium_crypto_sign_publickey($keys)), 'Ed25519 signature');
    check(!sodium_crypto_sign_verify_detached(base64_decode($envelope['signature']), $payload . ' ', sodium_crypto_sign_publickey($keys)), 'Tampering rejected');
    check(json_decode($payload, true)['release']['sha256'] === hash_file('sha256', $zipPath), 'Hash matches package');
    check(json_decode($payload, true)['nonce'] === $nonce, 'Replay nonce included');
    $core->setForceUpdate($release['id'], true);
    $forced = json_decode(base64_decode($core->signedUpdate('windows', 'x64', $nonce)['payload']), true);
    check($forced['release']['force_update'] === true, 'Signed manifest carries force update');
    $core->setForceUpdate($release['id'], false);
    $core->publish($release['id'], false); check(count($core->releases()) === 0, 'Unpublish');
    rejects(fn() => $core->addRelease(['platform' => 'windows', 'version' => '1.3.0', 'build' => 11, 'arch' => 'x64', 'format' => 'zip'], $zipPath, false), 409);
    $badPath = $directory . '/bad.zip'; $zip = new ZipArchive(); $zip->open($badPath, ZipArchive::CREATE); $zip->addFromString('../escape.exe', 'no'); $zip->close();
    rejects(fn() => $core->addRelease(['platform' => 'windows', 'version' => '1.3.0', 'build' => 12, 'arch' => 'x64', 'format' => 'zip'], $badPath, false), 422);
    // Synthetic UDIF trailer tests only; no disk image is mounted or executed.
    $dmgPath = $directory . '/fixture.dmg'; file_put_contents($dmgPath, 'fixture-only' . 'koly' . str_repeat("\0", 508));
    $macFields = ['platform' => 'macos', 'version' => '1.3.2', 'build' => 13, 'arch' => 'universal', 'format' => 'dmg'];
    $mac = $core->addRelease($macFields, $dmgPath, false);
    check($mac['format'] === 'dmg' && $mac['arch'] === 'universal', 'macOS DMG upload');
    $core->publish($mac['id'], true);
    $macEnvelope = $core->signedUpdate('macos', 'universal', $nonce);
    $macPayload = base64_decode($macEnvelope['payload']);
    check(sodium_crypto_sign_verify_detached(base64_decode($macEnvelope['signature']), $macPayload, sodium_crypto_sign_publickey($keys)), 'macOS signed manifest');
    check(json_decode($macPayload, true)['release']['id'] === $mac['id'], 'macOS update selects own package');
    $core->publish($mac['id'], false);
    rejects(fn() => $core->addRelease(array_replace($macFields, ['arch' => 'x64']), $dmgPath, false), 422);
    rejects(fn() => $core->addRelease(array_replace($macFields, ['format' => 'exe']), $dmgPath, false), 422);
    rejects(fn() => $core->addRelease(array_replace($macFields, ['build' => 14]), $badPath, false), 422);
    $core->query('UPDATE qqm_installations SET ip_updated_at=?', [time() - 8 * 86400]); $core->prune();
    check($core->stats()['devices'][0]['last_ip'] === null, 'IP retention');
    $core->forget($token); check($core->stats()['installations'] === 0, 'Delete installation');
    check((int)$core->query('SELECT count(*) FROM qqm_daily_usage')->fetchColumn() === 0, 'Cascaded daily deletion');
    $core->rateLimit('test-limit', 'fixture', 1, 60);
    rejects(fn() => $core->rateLimit('test-limit', 'fixture', 1, 60), 429);
    $core->query('UPDATE qqm_limits SET bucket_start=0');
    $core->rateLimit('test-limit', 'fixture', 1, 60); check(true, 'New rate window resets counter');
    rejects(fn() => $core->signedUpdate('windows', 'x64', 'bad'), 422);
    echo "Backend: {$passed} checks passed.\n";
} finally {
    // Only the exact random test directory created by this script is removed.
    unset($core);
    $real = realpath($directory);
    if ($real && str_starts_with(basename($real), 'qqm-backend-test-') && dirname($real) === realpath(sys_get_temp_dir())) {
        $iterator = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($real, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
        foreach ($iterator as $file) { if ($file->isDir()) { rmdir($file->getPathname()); } else { unlink($file->getPathname()); } }
        rmdir($real);
    }
}
