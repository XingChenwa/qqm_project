<?php
declare(strict_types=1);

namespace QQM;

require_once __DIR__ . '/Configuration.php';

use PDO;
use RuntimeException;
use ZipArchive;

final class HttpError extends RuntimeException
{
    public function __construct(public readonly int $status, string $message) { parent::__construct($message); }
}

final class Core
{
    public const SCHEMA_VERSION = 2;
    private const DEVICE_COLUMNS = ['device_name' => 128, 'device_model' => 128, 'system_version' => 255, 'system_arch' => 64];
    public readonly PDO $db;
    public readonly array $config;
    public readonly string $dataDir;

    public function __construct(private readonly string $root, ?string $dataDir = null, array $overrides = [], bool $requireSchema = true)
    {
        $this->dataDir = $dataDir ?? (getenv('QQM_DATA_DIR') ?: $root . '/data');
        $this->config = self::configuration($root, $this->dataDir, $overrides);
        if ($overrides === [] && !is_file($this->dataDir . '/config.json')) { throw new HttpError(503, '已读取 config.php，但安装尚未完成。请用 PHP 用户 www 运行 php bin/manage.php install，自动生成密钥并创建 MySQL 数据表。'); }
        if (!is_dir($this->dataDir) && !@mkdir($this->dataDir, 0700, true) && !is_dir($this->dataDir)) { throw new HttpError(503, 'data 目录不可创建，请检查 PHP 用户的读写权限。'); }
        if (!extension_loaded('pdo_mysql')) { throw new HttpError(503, '请在宝塔启用当前 PHP 的 pdo_mysql 扩展'); }
        $database = $this->config['database'];
        if (($database['name'] ?? '') === '' || ($database['username'] ?? '') === '') { throw new HttpError(503, '请先在 config.php 填写宝塔 MySQL 的数据库名、专用账号和密码，再运行 php bin/manage.php install。旧版也可编辑 data/config.json 的 database 字段。'); }
        if (!is_string($database['host']) || !preg_match('/^[a-zA-Z0-9_.:\[\]-]{1,255}$/D', $database['host'])
            || !is_string($database['name']) || !preg_match('/^[a-zA-Z0-9_]{1,64}$/D', $database['name'])
            || !is_string($database['username']) || $database['username'] === '' || strlen($database['username']) > 128
            || !is_string($database['password']) || !is_string($database['socket']) || strpbrk($database['socket'], ";\r\n\0") !== false
            || filter_var($database['port'], FILTER_VALIDATE_INT, ['options' => ['min_range' => 1, 'max_range' => 65535]]) === false) {
            throw new HttpError(503, 'MySQL 配置无效，请检查 config.php 的 database 字段；旧版配置位于 data/config.json。');
        }
        $dsn = $database['socket'] !== '' ? 'mysql:unix_socket=' . $database['socket'] : 'mysql:host=' . $database['host'] . ';port=' . $database['port'];
        $options = [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false, PDO::ATTR_STRINGIFY_FETCHES => false, PDO::ATTR_TIMEOUT => 5];
        $mysqlConstant = static fn(string $name): int => constant(class_exists('Pdo\\Mysql') ? 'Pdo\\Mysql::' . $name : 'PDO::MYSQL_' . $name);
        $options[$mysqlConstant('ATTR_MULTI_STATEMENTS')] = false;
        $options[$mysqlConstant('ATTR_LOCAL_INFILE')] = false;
        if ($database['ssl_ca'] !== '') {
            if (!is_string($database['ssl_ca']) || !is_file($database['ssl_ca'])) { throw new HttpError(503, 'MySQL CA 证书文件不存在'); }
            $options[$mysqlConstant('ATTR_SSL_CA')] = $database['ssl_ca'];
            $options[$mysqlConstant('ATTR_SSL_VERIFY_SERVER_CERT')] = true;
        }
        try { $this->db = new PDO($dsn . ';dbname=' . $database['name'] . ';charset=utf8mb4', $database['username'], $database['password'], $options); }
        catch (\PDOException $error) {
            $reason = match ((int)($error->errorInfo[1] ?? 0)) {
                1045 => 'MySQL 拒绝登录，请核对宝塔数据库专用账号、密码和允许访问的主机。',
                1049 => 'MySQL 数据库不存在，请先在宝塔创建数据库并核对库名。',
                1044, 1142 => 'MySQL 账号权限不足，请在宝塔为专用账号授权此数据库。',
                2002, 2003, 2005 => '无法连接 MySQL 服务，请检查服务是否启动及 host、port 或 socket 配置。',
                default => '无法连接 MySQL，请检查宝塔数据库名称、专用账号、密码和访问权限。',
            };
            throw new HttpError(503, $reason);
        }
        if ($requireSchema) { $this->requireSchema(); }
    }

    public static function configuration(string $root, string $dataDir, array $overrides = []): array
    {
        return Configuration::load($root, $dataDir, $overrides);
    }

    public function initializeSchema(): void
    {
        if (PHP_SAPI !== 'cli') { throw new HttpError(403, '数据库初始化仅允许在服务器终端执行'); }
        $lock = 'qqm-schema-' . substr(hash('sha256', (string)$this->query('SELECT DATABASE()')->fetchColumn()), 0, 48);
        if ((int)$this->query('SELECT GET_LOCK(?,10)', [$lock])->fetchColumn() !== 1) { throw new HttpError(503, '数据库结构正在升级，请稍后重新运行 install。'); }
        try {
            // Fixed DDL only. Existing records and release-signing keys are never recreated.
            foreach (explode(';', file_get_contents($this->root . '/database/schema.sql')) as $statement) {
                if (trim($statement) !== '') { $this->db->exec($statement); }
            }
            if ((int)$this->query('SELECT MAX(version) FROM qqm_schema_migrations')->fetchColumn() > self::SCHEMA_VERSION) {
                throw new HttpError(503, '数据库结构比当前代码新，请部署匹配版本，不要降级或重建数据表。');
            }
            $existing = array_column($this->query('SHOW COLUMNS FROM qqm_installations')->fetchAll(), 'Field');
            foreach (self::DEVICE_COLUMNS as $name => $length) {
                if (!in_array($name, $existing, true)) { $this->db->exec("ALTER TABLE qqm_installations ADD COLUMN `{$name}` VARCHAR({$length}) NULL"); }
            }
            $this->query('INSERT INTO qqm_schema_migrations(version,installed_at) VALUES(?,?) ON DUPLICATE KEY UPDATE version=version', [self::SCHEMA_VERSION, time()]);
            $this->requireSchema();
        } finally {
            $this->query('SELECT RELEASE_LOCK(?)', [$lock]);
        }
    }

    private function requireSchema(): void
    {
        try { $version = (int)$this->query('SELECT MAX(version) FROM qqm_schema_migrations')->fetchColumn(); }
        catch (\PDOException) { throw new HttpError(503, 'MySQL 数据表尚未就绪，请在服务器运行 php bin/manage.php db-init'); }
        if ($version !== self::SCHEMA_VERSION) { throw new HttpError(503, '数据库结构版本不匹配，请先备份，再用 PHP 用户运行 php bin/manage.php install；保留已有配置、数据及签名私钥。'); }
    }

    public function query(string $sql, array $params = []): \PDOStatement
    {
        $statement = $this->db->prepare($sql); $statement->execute($params); return $statement;
    }

    public static function inCidr(string $ip, string $cidr): bool
    {
        $parts = explode('/', $cidr, 2); $address = @inet_pton($ip); $network = @inet_pton($parts[0]);
        if ($address === false || $network === false || strlen($address) !== strlen($network)) { return false; }
        $bits = $parts[1] ?? (string)(strlen($address) * 8);
        if (!ctype_digit($bits) || (int)$bits < 1 || (int)$bits > strlen($address) * 8) { return false; }
        $whole = intdiv((int)$bits, 8); $remaining = (int)$bits % 8;
        return substr($address, 0, $whole) === substr($network, 0, $whole)
            && ($remaining === 0 || (ord($address[$whole]) & (255 << (8 - $remaining))) === (ord($network[$whole]) & (255 << (8 - $remaining))));
    }

    public function clientIp(array $server): array
    {
        return $this->proxyDiagnostics($server)['detected'];
    }

    /** Admin-only diagnostic data: never return the received or configured secret. */
    public function proxyDiagnostics(array $server): array
    {
        $peer = $server['QQM_PROXY_ADDR'] ?? $server['REMOTE_ADDR'] ?? '';
        $peerValid = is_string($peer) && filter_var($peer, FILTER_VALIDATE_IP) !== false;
        $secret = (string)$this->config['origin_token'];
        $received = $server['HTTP_X_QQM_ORIGIN_TOKEN'] ?? '';
        $tokenPresent = is_string($received) && $received !== '';
        $tokenMatches = $secret !== '' && $tokenPresent && hash_equals($secret, $received);
        $peerTrusted = $peerValid && count(array_filter($this->config['trusted_proxy_cidrs'], fn($cidr) => self::inCidr($peer, $cidr))) > 0;
        $mode = $this->config['proxy_trust_mode'];
        $key = 'HTTP_' . strtoupper(str_replace('-', '_', $this->config['client_ip_header']));
        $forwarded = $server[$key] ?? '';
        // A single address only. Never split XFF or duplicate IP headers and trust the first item.
        if (is_string($forwarded)) { $forwarded = trim($forwarded, " \t"); }
        $headerPresent = is_string($forwarded) && $forwarded !== '';
        $headerValid = $headerPresent && filter_var($forwarded, FILTER_VALIDATE_IP) !== false;
        $reason = match (true) {
            !$peerValid => 'invalid_peer',
            $secret === '' => 'origin_token_not_configured',
            !$tokenPresent => 'origin_token_missing',
            !$tokenMatches => 'origin_token_mismatch',
            $mode === 'cidr_and_token' && !$peerTrusted => 'proxy_not_in_trusted_cidrs',
            !$headerPresent => 'client_ip_header_missing',
            !$headerValid => 'client_ip_header_invalid',
            default => 'accepted',
        };
        $detected = $reason === 'accepted'
            ? ['ip' => $forwarded, 'source' => $this->config['client_ip_header']]
            : ['ip' => $peerValid ? $peer : null, 'source' => $peerValid ? 'direct-or-unconfigured-proxy' : 'unknown'];
        $message = match ($reason) {
            'accepted' => $mode === 'edgeone_token'
                ? '已通过回源密钥校验，正在使用 EO-Connecting-IP。当前为免费版模式，不校验回源网段。'
                : '回源密钥和可信网段均匹配，正在使用转发的客户端 IP。',
            'invalid_peer' => '无法识别连接地址，请检查 Nginx 的 QQM_PROXY_ADDR / REMOTE_ADDR 配置。',
            'origin_token_not_configured' => '服务器尚未生成回源密钥，请用 PHP 用户运行 install，保留已有签名私钥。',
            'origin_token_missing' => '没有收到回源密钥，仅显示连接地址。请检查 EdgeOne 的设置/覆盖请求头规则。',
            'origin_token_mismatch' => '回源密钥不匹配，仅显示连接地址。请在服务器本机核对 origin-token，不要公开密钥。',
            'proxy_not_in_trusted_cidrs' => '回源密钥已匹配，但节点不在可信网段内。免费版可按部署文档改为 edgeone_token 模式。',
            'client_ip_header_missing' => '回源鉴权已通过，但没有收到客户端 IP 头。请检查 EdgeOne 回源及 Nginx FastCGI 请求头传递。',
            default => '客户端 IP 头不是单个有效 IPv4/IPv6 地址，已拒绝采信；不会回退到 X-Forwarded-For。',
        };
        return ['detected' => $detected, 'proxy_peer' => $peerValid ? $peer : null, 'trust_mode' => $mode,
            'origin_check_enabled' => $this->config['require_origin_token'], 'origin_token_configured' => $secret !== '',
            'origin_token_received' => $tokenPresent, 'origin_token_matches' => $tokenMatches,
            'trusted_cidrs_count' => count($this->config['trusted_proxy_cidrs']), 'proxy_peer_trusted' => $peerTrusted,
            'client_ip_header' => $this->config['client_ip_header'], 'client_ip_header_present' => $headerPresent,
            'client_ip_header_valid' => $headerValid, 'reason' => $reason, 'message' => $message];
    }

    public function checkOriginToken(array $server): void
    {
        $received = $server['HTTP_X_QQM_ORIGIN_TOKEN'] ?? '';
        if ($this->config['require_origin_token'] && ((string)$this->config['origin_token'] === ''
            || !is_string($received) || !hash_equals((string)$this->config['origin_token'], $received))) {
            throw new HttpError(403, '回源鉴权失败');
        }
    }

    public function rateLimit(string $action, string $identity, int $maximum, int $seconds): void
    {
        $now = time(); $window = intdiv($now, $seconds) * $seconds;
        $key = hash_hmac('sha256', $action . ':' . $identity, $this->config['signing_secret'] ?: 'local-unconfigured');
        $this->query('INSERT INTO qqm_limits(id,bucket_start,hits) VALUES(?,?,1)
          ON DUPLICATE KEY UPDATE hits=CASE WHEN bucket_start=? THEN hits+1 ELSE 1 END,bucket_start=?', [$key, $window, $window, $window]);
        if ((int)$this->query('SELECT hits FROM qqm_limits WHERE id=?', [$key])->fetchColumn() > $maximum) { throw new HttpError(429, '操作过于频繁，请稍后重试'); }
    }

    public static function clientFields(array $body): array
    {
        $platform = $body['platform'] ?? ''; $version = $body['version'] ?? ''; $build = $body['build'] ?? null;
        if (!in_array($platform, ['windows', 'android', 'ios', 'macos', 'linux'], true)
            || !is_string($version) || !preg_match('/^\d{1,4}\.\d{1,4}\.\d{1,4}(?:-[a-zA-Z0-9.-]{1,32})?$/D', $version)
            || !is_int($build) || $build < 1 || $build > 2147483647) { throw new HttpError(422, '平台、版本或构建号无效'); }
        return [$platform, $version, $build];
    }

    public function register(array $body, array $ip): array
    {
        [$platform, $version, $build] = self::clientFields($body);
        $device = self::deviceFields($body);
        $id = $body['installation_id'] ?? '';
        if (!in_array($body['consent_version'] ?? '', ['1', '2'], true) || !is_string($id) || !preg_match('/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/D', $id)) { throw new HttpError(422, '需有效统计协议版本和随机安装 ID'); }
        $this->rateLimit('registration', $ip['ip'] ?? 'unknown', 60, 3600);
        $token = bin2hex(random_bytes(32)); $now = time();
        if ($this->query('SELECT 1 FROM qqm_installations WHERE id=?', [$id])->fetchColumn()) { throw new HttpError(409, '安装 ID 已注册，请使用原令牌或新的随机 ID'); }
        $this->query('INSERT INTO qqm_installations(id,token_hash,platform,version,build,first_seen,last_seen,last_ip,ip_source,ip_updated_at,device_name,device_model,system_version,system_arch) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)', [$id, hash('sha256', $token), $platform, $version, $build, $now, $now, $ip['ip'], $ip['source'], $now, ...array_values($device)]);
        // Fixed metadata allowlist only; no QQ identifiers, messages or persistent hardware IDs.
        $this->touchDay($id);
        return ['token' => $token];
    }

    private function touchDay(string $id): void
    {
        $day = (new \DateTimeImmutable('now', new \DateTimeZone('Asia/Shanghai')))->format('Y-m-d');
        $this->query('INSERT INTO qqm_daily_usage(day,installation_id) VALUES(?,?) ON DUPLICATE KEY UPDATE installation_id=installation_id', [$day, $id]);
    }

    public static function deviceFields(array $body): array
    {
        $result = [];
        foreach (self::DEVICE_COLUMNS as $name => $length) {
            $value = $body[$name] ?? null;
            if ($value !== null && (!is_string($value) || preg_match('/^.{0,' . $length . '}$/usD', $value) !== 1
                || preg_match('/[\x00-\x1f\x7f-\x9f]/u', $value))) { throw new HttpError(422, '设备资料字段无效或过长：' . $name); }
            $result[$name] = $value === null || trim($value) === '' ? null : trim($value);
        }
        return $result;
    }

    public function installation(string $token): array
    {
        if (!preg_match('/^[a-f0-9]{64}$/D', $token)) { throw new HttpError(401, '安装令牌无效'); }
        $row = $this->query('SELECT * FROM qqm_installations WHERE token_hash=?', [hash('sha256', $token)])->fetch();
        if (!$row) { throw new HttpError(401, '安装令牌无效'); } return $row;
    }

    public function heartbeat(array $body, string $token, array $ip): void
    {
        [$platform, $version, $build] = self::clientFields($body); $row = $this->installation($token);
        $device = self::deviceFields($body);
        if ($row['platform'] !== $platform) { throw new HttpError(422, '安装平台不匹配'); }
        $this->rateLimit('heartbeat', $row['id'], 15, 60);
        $this->query('UPDATE qqm_installations SET version=?,build=?,last_seen=?,last_ip=?,ip_source=?,ip_updated_at=?,device_name=COALESCE(?,device_name),device_model=COALESCE(?,device_model),system_version=COALESCE(?,system_version),system_arch=COALESCE(?,system_arch) WHERE id=?', [$version, $build, time(), $ip['ip'], $ip['source'], time(), ...array_values($device), $row['id']]);
        $this->touchDay($row['id']);
    }

    public function forget(string $token): void
    {
        $row = $this->installation($token); $this->query('DELETE FROM qqm_installations WHERE id=?', [$row['id']]);
    }

    public function prune(): void
    {
        $this->query('UPDATE qqm_installations SET last_ip=NULL,ip_source=NULL WHERE ip_updated_at < ?', [time() - max(1, (int)$this->config['ip_retention_days']) * 86400]);
        $this->query('DELETE FROM qqm_installations WHERE last_seen < ?', [time() - max(7, (int)$this->config['device_retention_days']) * 86400]);
        $this->query('DELETE FROM qqm_daily_usage WHERE day < ?', [gmdate('Y-m-d', time() - 90 * 86400)]);
        $this->query('DELETE FROM qqm_limits WHERE bucket_start < ?', [time() - 86400]);
    }

    public function stats(): array
    {
        $this->prune(); $today = (new \DateTimeImmutable('now', new \DateTimeZone('Asia/Shanghai')))->format('Y-m-d');
        return [
            'online' => (int)$this->query('SELECT count(*) FROM qqm_installations WHERE last_seen>=?', [time() - 300])->fetchColumn(),
            'today' => (int)$this->query('SELECT count(*) FROM qqm_daily_usage WHERE day=?', [$today])->fetchColumn(),
            'installations' => (int)$this->query('SELECT count(*) FROM qqm_installations')->fetchColumn(),
            'versions' => $this->query('SELECT platform,version,build,count(*) AS count FROM qqm_installations GROUP BY platform,version,build ORDER BY count DESC')->fetchAll(),
            'trend' => $this->query('SELECT day,count(*) AS count FROM qqm_daily_usage WHERE day>=? GROUP BY day ORDER BY day', [gmdate('Y-m-d', time() - 13 * 86400)])->fetchAll(),
            'devices' => $this->query('SELECT id,platform,version,build,first_seen,last_seen,last_ip,ip_source,device_name,device_model,system_version,system_arch FROM qqm_installations ORDER BY last_seen DESC LIMIT 200')->fetchAll(),
            'definitions' => '统计已开启使用统计并成功上报的安装；在线=近5分钟有心跳。安装数不等于真实人数，重装可能形成新 ID；显示最近200条设备详情。',
        ];
    }

    public function releases(bool $publishedOnly = true): array
    {
        return array_map(fn($row) => $this->publicRelease($row), $this->query('SELECT * FROM qqm_releases' . ($publishedOnly ? ' WHERE published=1' : '') . ' ORDER BY build DESC,created_at DESC LIMIT 100')->fetchAll());
    }

    public function publicRelease(array $row): array
    {
        $row['build'] = (int)$row['build']; $row['size'] = (int)$row['size']; $row['published'] = (bool)$row['published'];
        $row['url'] = rtrim($this->config['app_url'], '/') . '/packages/' . $row['sha256'] . '/' . rawurlencode($row['filename']);
        $row['package_id'] = 'cn.uuze.botmanager'; $row['requires_resigning'] = $row['platform'] === 'ios'; return $row;
    }

    public function signedUpdate(string $platform, string $arch, string $nonce): array
    {
        if (!in_array($platform, ['windows', 'android', 'ios', 'macos'], true) || !in_array($arch, ['x64', 'arm64', 'universal'], true) || !preg_match('/^[a-f0-9-]{16,64}$/D', $nonce)) { throw new HttpError(422, '更新请求参数无效'); }
        $secret = base64_decode($this->config['signing_secret'], true);
        if ($secret === false || strlen($secret) !== SODIUM_CRYPTO_SIGN_SECRETKEYBYTES) { throw new HttpError(503, '更新签名公钥尚未初始化'); }
        $row = $this->query('SELECT * FROM qqm_releases WHERE published=1 AND platform=? AND arch=? ORDER BY build DESC LIMIT 1', [$platform, $arch])->fetch();
        $payload = json_encode(['schema' => 1, 'nonce' => $nonce, 'platform' => $platform, 'arch' => $arch, 'expires_at' => time() + 900, 'release' => $row ? $this->publicRelease($row) : null], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
        return ['payload' => base64_encode($payload), 'signature' => base64_encode(sodium_crypto_sign_detached($payload, $secret))];
    }

    public function addRelease(array $fields, string $temporaryFile, bool $httpUpload = true): array
    {
        [$platform, $version, $build] = self::clientFields($fields); $format = $fields['format'] ?? ''; $arch = $fields['arch'] ?? '';
        if (!in_array($platform, ['windows', 'android', 'ios', 'macos'], true)
            || !in_array($arch, $platform === 'windows' ? ['x64'] : ($platform === 'ios' ? ['arm64'] : ['universal']), true)
            || !in_array($format, match ($platform) { 'windows' => ['zip', 'exe'], 'android' => ['apk'], 'macos' => ['dmg'], default => ['ipa'] }, true)) { throw new HttpError(422, '平台、架构或包类型不匹配'); }
        $size = is_file($temporaryFile) ? filesize($temporaryFile) : 0;
        if ($size < 1 || $size > (int)$this->config['max_upload_bytes']) { throw new HttpError(422, '安装包为空或超过上传限制'); }
        $notes = $fields['notes'] ?? '';
        if (!is_string($notes) || strlen($notes) > 12000) { throw new HttpError(422, '更新说明过长'); }
        if ($format === 'dmg') {
            // UDIF trailer; uploads are opaque and are never mounted/executed by PHP.
            if ($size < 512 || file_get_contents($temporaryFile, false, null, $size - 512, 4) !== 'koly') { throw new HttpError(422, '不是有效的 macOS DMG 镜像'); }
        } elseif ($format !== 'exe') {
            $zip = new ZipArchive();
            if ($zip->open($temporaryFile) !== true) { throw new HttpError(422, '安装包不是有效 ZIP/APK/IPA'); }
            try {
                if ($zip->numFiles > 20000) { throw new HttpError(422, '包内文件过多'); }
                $expanded = 0; $names = [];
                for ($i = 0; $i < $zip->numFiles; $i++) {
                    $stat = $zip->statIndex($i); $name = str_replace('\\', '/', $stat['name']);
                    if ($name === '' || preg_match('~(^/|:|(^|/)\.\.?(/|$)|[\x00-\x1f])~', $name)) { throw new HttpError(422, '安装包存在不安全路径'); }
                    $zip->getExternalAttributesIndex($i, $opsys, $attributes);
                    if ($opsys === 3 && (($attributes >> 16) & 0170000) === 0120000) { throw new HttpError(422, '安装包不允许符号链接'); }
                    if (isset($names[strtolower($name)])) { throw new HttpError(422, '安装包有重复文件'); }
                    $names[strtolower($name)] = true; $expanded += $stat['size'];
                    if ($expanded > 2147483648) { throw new HttpError(422, '解压后体积过大'); }
                }
                $required = $platform === 'windows' ? ['qq_bot_manager.exe', 'flutter_windows.dll', 'data/app.so'] : ($platform === 'android' ? ['AndroidManifest.xml', 'classes.dex'] : ['Payload/Runner.app/Info.plist', 'Payload/Runner.app/Runner']);
                foreach ($required as $name) { if ($zip->locateName($name) === false) { throw new HttpError(422, '安装包结构不正确：' . $name); } }
            } finally { $zip->close(); }
        } elseif (file_get_contents($temporaryFile, false, null, 0, 2) !== 'MZ') { throw new HttpError(422, '不是有效的 Windows 安装程序'); }
        $hash = hash_file('sha256', $temporaryFile); $id = bin2hex(random_bytes(12));
        $filename = "qqbotmanager-{$platform}-{$version}-{$build}.{$format}";
        $directory = $this->dataDir . '/packages/' . $hash;
        if (!is_dir($directory)) { mkdir($directory, 0700, true); }
        $destination = $directory . '/' . $filename;
        if (!is_file($destination)) {
            $ok = $httpUpload ? move_uploaded_file($temporaryFile, $destination) : copy($temporaryFile, $destination);
            if (!$ok) { throw new HttpError(500, '安装包保存失败'); }
            chmod($destination, 0600);
        }
        try {
            $this->query('INSERT INTO qqm_releases(id,platform,arch,version,build,`format`,filename,sha256,size,notes,published,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,0,?)', [$id, $platform, $arch, $version, $build, $format, $filename, $hash, $size, $notes, time()]);
        } catch (\PDOException $error) { if ($error->getCode() === '23000') { throw new HttpError(409, '该平台/架构的构建号已经存在'); } throw $error; }
        return $this->publicRelease($this->query('SELECT * FROM qqm_releases WHERE id=?', [$id])->fetch());
    }

    public function publish(string $id, bool $published): void
    {
        if (!$this->query('SELECT 1 FROM qqm_releases WHERE id=?', [$id])->fetchColumn()) { throw new HttpError(404, '版本不存在'); }
        $this->query('UPDATE qqm_releases SET published=? WHERE id=?', [$published ? 1 : 0, $id]);
    }
}
