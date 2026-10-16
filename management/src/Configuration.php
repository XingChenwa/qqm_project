<?php
declare(strict_types=1);

namespace QQM;

/** Server-only settings. The example is documentation, never a runtime dependency. */
final class Configuration
{
    public static function defaults(): array
    {
        return [
            'app_url' => 'https://botmanager.uuze.cn', 'environment' => 'production',
            'database' => ['host' => '127.0.0.1', 'port' => 3306, 'name' => '', 'username' => '', 'password' => '', 'socket' => '', 'ssl_ca' => ''],
            'admin_email' => '2377130783@qq.com', 'uuze_client_id' => '', 'uuze_client_secret' => '',
            'signing_secret' => '', 'origin_token' => '', 'require_origin_token' => false,
            'proxy_trust_mode' => 'cidr_and_token', 'trusted_proxy_cidrs' => [], 'client_ip_header' => 'EO-Connecting-IP',
            'max_upload_bytes' => 1073741824,
        ];
    }

    private static function saved(string $dataDir): array
    {
        $file = $dataDir . '/config.json';
        if (!file_exists($file)) { return []; }
        if (!is_file($file) || !is_readable($file) || ($text = @file_get_contents($file)) === false) {
            throw new HttpError(503, '无法读取 data/config.json，请检查文件及 PHP 用户的读取权限，不要删除已有密钥。');
        }
        try { $values = json_decode($text, true, 32, JSON_THROW_ON_ERROR); }
        catch (\JsonException) { throw new HttpError(503, 'data/config.json 的 JSON 格式错误，请检查逗号和双引号，保留原有签名私钥。'); }
        if (!is_array($values) || !str_starts_with(ltrim($text), '{')) { throw new HttpError(503, 'data/config.json 顶层必须是 JSON 对象。'); }
        return $values;
    }

    public static function load(string $root, string $dataDir, array $overrides = [], bool $allowMissing = false): array
    {
        $file = $root . '/config.php'; $saved = self::saved($dataDir); $local = [];
        if (file_exists($file)) {
            if (!is_file($file) || !is_readable($file)) { throw new HttpError(503, '无法读取 config.php，请检查 PHP 用户的读取权限。'); }
            try { $local = require $file; }
            catch (\Throwable) { throw new HttpError(503, 'config.php 的 PHP 格式错误，请检查引号、逗号和 return 数组，不要公开数据库密码。'); }
            if (!is_array($local)) { throw new HttpError(503, 'config.php 必须使用 return 返回配置数组。'); }
        } elseif (!file_exists($dataDir . '/config.json') && $overrides === [] && !$allowMissing) {
            throw new HttpError(503, '尚未安装：请在网站应用目录运行 php bin/manage.php install，按提示填写 config.php 的宝塔 MySQL 信息后再次运行。网站运行目录必须为 public。');
        }
        $result = self::defaults();
        foreach ([$saved, $local, $overrides] as $values) {
            if (array_key_exists('database', $values)) {
                if (!is_array($values['database'])) { throw new HttpError(503, 'database 配置必须为对象或 PHP 数组，请检查 config.php 或旧版 data/config.json。'); }
                $values['database'] = array_replace($result['database'], $values['database']);
            }
            $result = array_replace($result, $values);
        }
        // Uploading a template must never replace an installation's existing signing identity.
        foreach (['signing_secret', 'origin_token'] as $name) {
            if (isset($saved[$name]) && $saved[$name] !== '') { $result[$name] = $saved[$name]; }
            if (!is_string($result[$name])) { throw new HttpError(503, '自动密钥配置类型无效，请检查 data/config.json，不要重置已有签名私钥。'); }
        }
        foreach (['app_url', 'environment', 'admin_email', 'uuze_client_id', 'uuze_client_secret', 'client_ip_header', 'proxy_trust_mode'] as $name) {
            if (!is_string($result[$name])) { throw new HttpError(503, '服务器配置字段类型无效：' . $name); }
        }
        if (!is_bool($result['require_origin_token']) || !is_array($result['trusted_proxy_cidrs'])
            || count(array_filter($result['trusted_proxy_cidrs'], 'is_string')) !== count($result['trusted_proxy_cidrs'])) {
            throw new HttpError(503, 'EdgeOne 配置格式错误：require_origin_token 应为布尔值，trusted_proxy_cidrs 应为字符串数组。');
        }
        if (!in_array($result['proxy_trust_mode'], ['cidr_and_token', 'edgeone_token'], true)) {
            throw new HttpError(503, 'EdgeOne proxy_trust_mode 只能是 cidr_and_token 或 edgeone_token。');
        }
        if (!preg_match('/^[a-zA-Z0-9-]{1,100}$/D', $result['client_ip_header'])) {
            throw new HttpError(503, 'EdgeOne client_ip_header 必须是有效的 HTTP 头部名称。');
        }
        if ($result['proxy_trust_mode'] === 'edgeone_token'
            && (!$result['require_origin_token'] || strcasecmp($result['client_ip_header'], 'EO-Connecting-IP') !== 0)) {
            throw new HttpError(503, 'EdgeOne 免费版模式必须同时设置 require_origin_token 为 true、client_ip_header 为 EO-Connecting-IP。先在 EdgeOne 配好回源密钥覆盖规则。');
        }
        return $result;
    }

    /** First CLI install creates the editable PHP settings without exposing a web installer. */
    public static function createTemplate(string $root, string $dataDir): bool
    {
        self::cliOnly();
        if (file_exists($root . '/config.php') || file_exists($dataDir . '/config.json')) { return false; }
        $settings = self::defaults(); unset($settings['signing_secret'], $settings['origin_token']);
        $template = $root . '/config.example.php';
        $contents = is_readable($template) ? @file_get_contents($template) : false;
        if ($contents === false) { $contents = "<?php\ndeclare(strict_types=1);\n// 在服务器填写宝塔 MySQL 及杂鱼账号凭据；不要提交 Git。\nreturn " . var_export($settings, true) . ";\n"; }
        self::createFile($root . '/config.php', $contents);
        return true;
    }

    /** Returns true only when a file was created or missing secrets were filled. */
    public static function initialize(string $root, string $dataDir, bool $refuseExisting = false): bool
    {
        self::cliOnly();
        if (!extension_loaded('sodium')) { throw new HttpError(503, '请启用当前命令行 PHP 的 sodium 扩展，用于生成更新签名密钥。'); }
        if (!is_dir($dataDir) && !@mkdir($dataDir, 0700, true) && !is_dir($dataDir)) { throw new HttpError(503, '无法创建 data 目录，请仅授予 PHP 用户 www 该目录的读写权限，不要设置全站 777。'); }
        $previous = umask(0077);
        try { $lock = @fopen($dataDir . '/install.lock', 'c'); }
        finally { umask($previous); }
        if ($lock === false) { throw new HttpError(503, 'data 目录不可写，请用 PHP 用户 www 执行安装并检查该目录的读写权限。'); }
        try {
            if (!flock($lock, LOCK_EX)) { throw new HttpError(503, '无法锁定安装配置，请稍后重试。'); }
            $file = $dataDir . '/config.json'; $exists = file_exists($file);
            if ($exists && $refuseExisting) { throw new HttpError(409, '配置已存在，拒绝覆盖签名私钥。请编辑现有配置，或运行 install 补齐安装，不要重新初始化。'); }
            $config = self::load($root, $dataDir, [], true);
            $saved = $exists ? self::saved($dataDir) : (is_file($root . '/config.php') ? [] : $config);
            $changed = !$exists;
            foreach (['signing_secret', 'origin_token'] as $name) {
                $value = $config[$name];
                if ($name === 'signing_secret' && $value !== '') {
                    $raw = base64_decode($value, true);
                    if ($raw === false || strlen($raw) !== SODIUM_CRYPTO_SIGN_SECRETKEYBYTES
                        || !hash_equals(sodium_crypto_sign_secretkey(sodium_crypto_sign_seed_keypair(substr($raw, 0, SODIUM_CRYPTO_SIGN_SEEDBYTES))), $raw)) {
                        throw new HttpError(503, '已有 signing_secret 无效，安装已停止以避免轮换密钥。请从受保护备份恢复，不要删除配置重新生成。');
                    }
                }
                if ($value === '') {
                    $value = $name === 'signing_secret' ? base64_encode(sodium_crypto_sign_secretkey(sodium_crypto_sign_keypair())) : bin2hex(random_bytes(32));
                }
                if (($saved[$name] ?? null) !== $value) { $saved[$name] = $value; $changed = true; }
            }
            if (!$changed) { return false; }
            $json = json_encode($saved, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR) . "\n";
            if (!$exists) { self::createFile($file, $json); return true; }
            // Replace only after a complete private temporary file has been written. No truncation of the live key file.
            if (is_link($file)) { throw new HttpError(503, '拒绝替换符号链接配置，请检查 data/config.json。'); }
            $temporary = @tempnam($dataDir, '.config-');
            if ($temporary === false) { throw new HttpError(503, '无法创建临时配置，请检查 data 目录权限。'); }
            try {
                if (!@chmod($temporary, 0600) || @file_put_contents($temporary, $json, LOCK_EX) !== strlen($json) || !@rename($temporary, $file)) {
                    throw new HttpError(503, '无法安全保存配置，原配置未被截断，请检查 data 目录的权限和可用空间。');
                }
            } finally { if (is_file($temporary)) { @unlink($temporary); } }
            return true;
        } finally { flock($lock, LOCK_UN); fclose($lock); }
    }

    private static function createFile(string $path, string $contents): void
    {
        $previous = umask(0077);
        try { $handle = @fopen($path, 'x'); }
        finally { umask($previous); }
        if ($handle === false) { throw new HttpError(503, '无法创建配置文件，请检查应用目录或 data 目录的权限；已有文件不会被覆盖。'); }
        try {
            if (!@chmod($path, 0600) || fwrite($handle, $contents) !== strlen($contents) || !fflush($handle)) { throw new HttpError(503, '配置未完整写入，请检查磁盘空间和权限后修复；不要删除已有密钥。'); }
        } finally { fclose($handle); }
    }

    private static function cliOnly(): void
    {
        if (PHP_SAPI !== 'cli') { throw new HttpError(403, '配置生成仅允许在服务器终端执行。'); }
    }
}
