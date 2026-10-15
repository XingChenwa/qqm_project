<?php
declare(strict_types=1);

require dirname(__DIR__) . '/src/Core.php';
use QQM\Core;
use QQM\Configuration;
use QQM\HttpError;

if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
$root = dirname(__DIR__); $command = $argv[1] ?? 'help';
$data = getenv('QQM_DATA_DIR') ?: $root . '/data';
if ($command === 'help') {
    echo "QQM 宝塔 MySQL 管理后台\ninstall        首次生成 config.php；填写数据库后再运行，自动生成密钥及建表（可安全重复）\ninit           兼容旧版：生成 data/config.json（只执行一次，不连接数据库）\ndb-init        使用已配置的 MySQL 账号创建本应用数据表\ndb-check       检查配置、MySQL 连接及数据表版本\npublic-key     输出客户端需内置的公开公钥\norigin-token   本机查看 EdgeOne 回源鉴权值（不要发到聊天）\nprune          执行数据保留清理\nimport         从本机文件导入草稿安装包\n"; exit;
}
try {
    if (!in_array($command, ['install', 'init', 'db-init', 'db-check', 'public-key', 'origin-token', 'prune', 'import'], true)) { throw new HttpError(422, '未知命令，运行 help 查看用法。'); }
    // Generating configuration does not depend on a working MySQL connection or ZIP/cURL extensions.
    $required = match ($command) {
        'init', 'install', 'public-key' => ['sodium'],
        'origin-token' => [],
        'db-init', 'db-check', 'prune' => ['pdo_mysql'],
        'import' => ['pdo_mysql', 'zip'],
    };
    foreach ($required as $extension) {
        if (!extension_loaded($extension)) { throw new HttpError(503, "需要当前命令行 PHP 扩展：{$extension}，请在宝塔为对应 PHP 版本启用。"); }
    }
    if ($command === 'init') {
        Configuration::initialize($root, $data, true);
        echo "配置与签名密钥已生成在 data/config.json，尚未连接数据库。\n请填写宝塔的 database 名称、专用账号、密码，以及 uuze_client_id / uuze_client_secret，再运行 db-init。\n管理员邮箱：2377130783@qq.com；没有本地密码登录后门。密钥和密码不用发到聊天。\n"; exit;
    }
    if ($command === 'install') {
        if (Configuration::createTemplate($root, $data)) {
            echo "已生成 config.php。请用宝塔文件管理填写 database 的 name、username、password；数据库需先在宝塔创建。\n填写后重新运行本命令；不要修改示例文件，也不需要手工创建 data/config.json。\n";
        }
        Configuration::initialize($root, $data);
        foreach (['pdo_mysql', 'zip', 'curl', 'session'] as $extension) {
            if (!extension_loaded($extension)) { throw new HttpError(503, "密钥已安全保留；还需启用当前 PHP 扩展：{$extension}，然后重试 install。"); }
        }
        $core = new Core($root, null, [], false); $core->initializeSchema();
        echo "安装完成：MySQL 连接正常，五张 qqm_ 数据表已就绪；现有记录、签名密钥和回源鉴权值保持不变。\n";
        echo "网站运行目录设为 public，后台地址为 /admin。请在 config.php 填写杂鱼账号凭据，管理员邮箱仅允许 2377130783@qq.com。\n";
        exit;
    }
    if (in_array($command, ['public-key', 'origin-token'], true)) {
        $config = Core::configuration($root, $data);
        if ($command === 'origin-token') { echo $config['origin_token'] . "\n"; exit; }
        $secret = base64_decode($config['signing_secret'], true);
        if (!$secret || strlen($secret) !== SODIUM_CRYPTO_SIGN_SECRETKEYBYTES) { throw new HttpError(503, '请先运行 init 生成签名密钥。'); }
        echo 'UPDATE_PUBLIC_KEY=' . base64_encode(sodium_crypto_sign_publickey_from_secretkey($secret)) . "\n"; exit;
    }
    $core = new Core($root, null, [], $command !== 'db-init');
    if ($command === 'db-init') { $core->initializeSchema(); echo "MySQL 数据表已就绪。重复执行不删除数据、不重置密钥。\n"; exit; }
    if ($command === 'db-check') { echo 'MySQL 连接正常，数据表版本 ' . Core::SCHEMA_VERSION . '，服务器：' . $core->db->getAttribute(PDO::ATTR_SERVER_VERSION) . "\n"; exit; }
    if ($command === 'prune') { $core->prune(); echo "已执行数据保留策略清理。\n"; exit; }
    if (count($argv) !== 8) { throw new HttpError(422, '用法：php bin/manage.php import windows x64 1.3.0 11 zip /绝对路径/软件.zip'); }
    $release = $core->addRelease(['platform' => $argv[2], 'arch' => $argv[3], 'version' => $argv[4], 'build' => (int)$argv[5], 'format' => $argv[6]], $argv[7], false);
    echo json_encode($release, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR) . "\n";
} catch (HttpError $error) { fwrite(STDERR, $error->getMessage() . "\n"); exit(1); }
catch (Throwable $error) { fwrite(STDERR, '操作失败（' . get_class($error) . "），请检查 MySQL 权限、配置格式和 PHP 扩展；不要公开密码或完整配置。\n"); exit(1); }
