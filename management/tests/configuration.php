<?php
declare(strict_types=1);
require dirname(__DIR__) . '/src/Core.php';
use QQM\Configuration;
use QQM\Core;
use QQM\HttpError;

$directory = sys_get_temp_dir() . '/qqm-config-test-' . bin2hex(random_bytes(8));
$data = $directory . '/data'; mkdir($data, 0700, true); $passed = 0;
function check(bool $condition, string $name): void { global $passed; if (!$condition) { throw new RuntimeException($name); } $passed++; }
function rejects(callable $call, string $text): void
{
    try { $call(); }
    catch (HttpError $error) { check($error->status === 503 && str_contains($error->getMessage(), $text), 'Actionable configuration error: ' . $text); return; }
    throw new RuntimeException('Expected safe configuration failure');
}
function phpSettings(string $path, array $values): void { file_put_contents($path, "<?php\nreturn " . var_export($values, true) . ";\n"); }
try {
    rejects(fn() => Core::configuration($directory, $data), 'install');
    check(!is_file($data . '/config.json'), 'Web configuration reads do not generate keys');
    check(Configuration::createTemplate($directory, $data), 'CLI generates PHP template even when example file is missing');
    check(is_file($directory . '/config.php'), 'Editable config.php created');
    check(!Configuration::createTemplate($directory, $data), 'Existing PHP settings never overwritten');
    $template = Core::configuration($directory, $data);
    check($template['database']['name'] === '' && $template['database']['port'] === 3306, 'MySQL template requires real database name');
    check($template['proxy_trust_mode'] === 'cidr_and_token', 'Existing deployments keep strict proxy trust by default');
    rejects(fn() => new Core($directory, $data), '安装尚未完成');
    check(Configuration::initialize($directory, $data), 'Secrets generated independently of database connection');
    $original = file_get_contents($data . '/config.json'); $secrets = json_decode($original, true, 32, JSON_THROW_ON_ERROR);
    check(count($secrets) === 2 && isset($secrets['signing_secret'], $secrets['origin_token']), 'New install stores only automatic secrets in JSON');
    check(strlen(base64_decode($secrets['signing_secret'], true)) === SODIUM_CRYPTO_SIGN_SECRETKEYBYTES, 'Valid signing secret');
    check(strlen($secrets['origin_token']) === 64, 'Random origin token');
    check(!Configuration::initialize($directory, $data), 'Repeated install does not rewrite keys');
    check(file_get_contents($data . '/config.json') === $original, 'Private configuration bytes preserved');
    phpSettings($directory . '/config.php', ['database' => ['name' => 'php_database', 'username' => 'php_user', 'password' => "fixture'pass\\word"], 'uuze_client_id' => 'php-client']);
    $current = Core::configuration($directory, $data);
    check($current['database']['name'] === 'php_database' && $current['database']['host'] === '127.0.0.1', 'Partial PHP database configuration merged with defaults');
    check($current['signing_secret'] === $secrets['signing_secret'], 'PHP configuration preserves signing identity');
    $legacy = array_replace($secrets, ['database' => ['name' => 'legacy_db', 'username' => 'legacy_user', 'port' => 3307], 'custom_setting' => 'preserved']);
    file_put_contents($data . '/config.json', json_encode($legacy, JSON_THROW_ON_ERROR));
    $current = Core::configuration($directory, $data);
    check($current['database']['name'] === 'php_database' && $current['database']['port'] === 3307 && $current['custom_setting'] === 'preserved', 'PHP overrides legacy database fields without erasing other fields');
    phpSettings($directory . '/config.php', ['signing_secret' => '', 'origin_token' => '']);
    check(Core::configuration($directory, $data)['signing_secret'] === $secrets['signing_secret'], 'Blank PHP template cannot reset existing key');
    unlink($directory . '/config.php');
    check(Core::configuration($directory, $data)['database']['name'] === 'legacy_db', 'Legacy JSON still works without either PHP config or example');
    check(!Configuration::initialize($directory, $data), 'Legacy settings remain unchanged on install');
    file_put_contents($data . '/config.json', '{"database": fixture-secret-not-for-output}');
    rejects(fn() => Core::configuration($directory, $data), 'JSON 格式错误');
    file_put_contents($data . '/config.json', '[]');
    rejects(fn() => Core::configuration($directory, $data), '顶层');
    file_put_contents($data . '/config.json', json_encode($secrets, JSON_THROW_ON_ERROR));
    file_put_contents($directory . '/config.php', '<?php return ["database" => fixture-secret-not-for-output];');
    rejects(fn() => Core::configuration($directory, $data), 'PHP 格式错误');
    file_put_contents($directory . '/config.php', '<?php return "not-an-array";');
    rejects(fn() => Core::configuration($directory, $data), '返回配置数组');
    phpSettings($directory . '/config.php', ['database' => null]);
    rejects(fn() => Core::configuration($directory, $data), 'database 配置必须');
    phpSettings($directory . '/config.php', ['trusted_proxy_cidrs' => [null]]);
    rejects(fn() => Core::configuration($directory, $data), 'EdgeOne');
    phpSettings($directory . '/config.php', ['proxy_trust_mode' => 'trust_everyone']);
    rejects(fn() => Core::configuration($directory, $data), 'proxy_trust_mode');
    phpSettings($directory . '/config.php', ['proxy_trust_mode' => []]);
    rejects(fn() => Core::configuration($directory, $data), 'proxy_trust_mode');
    phpSettings($directory . '/config.php', ['proxy_trust_mode' => 'edgeone_token']);
    rejects(fn() => Core::configuration($directory, $data), 'require_origin_token');
    phpSettings($directory . '/config.php', ['proxy_trust_mode' => 'edgeone_token', 'require_origin_token' => true, 'client_ip_header' => 'X-Forwarded-For']);
    rejects(fn() => Core::configuration($directory, $data), 'EO-Connecting-IP');
    phpSettings($directory . '/config.php', ['client_ip_header' => "EO-Connecting-IP\r\nInjected"]);
    rejects(fn() => Core::configuration($directory, $data), 'client_ip_header');
    phpSettings($directory . '/config.php', ['proxy_trust_mode' => 'edgeone_token', 'require_origin_token' => true]);
    $free = Core::configuration($directory, $data);
    check($free['proxy_trust_mode'] === 'edgeone_token' && $free['trusted_proxy_cidrs'] === [], 'Free mode does not require paid-plan CIDRs');
    check($free['signing_secret'] === $secrets['signing_secret'] && $free['origin_token'] === $secrets['origin_token'], 'Changing proxy trust preserves both installed secrets');
    phpSettings($directory . '/config.php', []);
    $invalid = array_replace($secrets, ['signing_secret' => 'not-a-private-key']);
    file_put_contents($data . '/config.json', json_encode($invalid, JSON_THROW_ON_ERROR)); $before = file_get_contents($data . '/config.json');
    rejects(fn() => Configuration::initialize($directory, $data), '已有 signing_secret 无效');
    check(file_get_contents($data . '/config.json') === $before, 'Damaged signing key is never silently rotated');
    $partial = array_replace($legacy, ['origin_token' => '']); file_put_contents($data . '/config.json', json_encode($partial, JSON_THROW_ON_ERROR));
    check(Configuration::initialize($directory, $data), 'Only missing origin token filled');
    $repaired = Core::configuration($directory, $data);
    check($repaired['signing_secret'] === $secrets['signing_secret'] && $repaired['custom_setting'] === 'preserved', 'Atomic repair keeps signing key and legacy settings');
    echo "Configuration/install: {$passed} checks passed.\n";
} finally {
    $real = realpath($directory);
    if ($real && dirname($real) === realpath(sys_get_temp_dir()) && str_starts_with(basename($real), 'qqm-config-test-')) {
        $iterator = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($real, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
        foreach ($iterator as $file) { if ($file->isDir()) { rmdir($file->getPathname()); } else { unlink($file->getPathname()); } }
        rmdir($real);
    }
}
