<?php
declare(strict_types=1);

namespace QQM;

function respond(mixed $value, int $status = 200): never {
    http_response_code($status); header('Content-Type: application/json; charset=utf-8'); header('Cache-Control: no-store');
    header_remove('Content-Disposition'); header_remove('ETag');
    echo json_encode($value, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR); exit;
}
function body(): array {
    if ((int)($_SERVER['CONTENT_LENGTH'] ?? 0) > 16384) { throw new HttpError(413, '请求体过大'); }
    $value = json_decode(file_get_contents('php://input', false, null, 0, 16385), true, 32, JSON_THROW_ON_ERROR);
    if (!is_array($value) || array_is_list($value)) { throw new HttpError(422, '需要 JSON 对象'); } return $value;
}
function bearer(): string { return preg_replace('/^Bearer /', '', $_SERVER['HTTP_AUTHORIZATION'] ?? '') ?? ''; }

function serve(Core $core, AccountLogin $account): bool
{
    $path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH) ?: '/';
    $public = realpath(dirname(__DIR__) . '/public');
    if (PHP_SAPI === 'cli-server' && str_starts_with($path, '/assets/')) {
        $file = realpath($public . $path);
        if ($file && str_starts_with($file, $public . DIRECTORY_SEPARATOR . 'assets' . DIRECTORY_SEPARATOR) && is_file($file)) { return false; }
    }
    header('X-Content-Type-Options: nosniff'); header('Referrer-Policy: no-referrer');
    header('Content-Security-Policy: default-src \'self\'; script-src \'self\'; style-src \'self\'; img-src \'self\' data:; connect-src \'self\'; object-src \'none\'; base-uri \'self\'; frame-ancestors \'none\'; form-action \'self\'');
    header('Cache-Control: no-store');
    try {
        $core->checkOriginToken($_SERVER); $method = $_SERVER['REQUEST_METHOD']; $ip = $core->clientIp($_SERVER);
        if (in_array($path, ['/', '/admin', '/admin/', '/privacy'], true) && $method === 'GET') {
            header('Content-Type: text/html; charset=utf-8');
            readfile($public . ($path === '/' ? '/home.html' : ($path === '/privacy' ? '/privacy.html' : '/admin.html'))); exit;
        }
        if ($path === '/api/v1/releases' && $method === 'GET') { respond(['releases' => $core->releases(), 'preview' => $core->config['environment'] === 'development']); }
        if ($path === '/api/v1/update' && $method === 'GET') { respond($core->signedUpdate((string)($_GET['platform'] ?? ''), (string)($_GET['arch'] ?? ''), (string)($_GET['nonce'] ?? ''))); }
        if (str_starts_with($path, '/api/v1/telemetry/')) { throw new HttpError(410, '设备统计已移除，不再接收或查询设备资料'); }
        if (preg_match('~^/packages/([a-f0-9]{64})/([a-zA-Z0-9.-]+)$~D', $path, $match) && in_array($method, ['GET', 'HEAD'], true)) {
            $row = $core->query('SELECT * FROM qqm_releases WHERE sha256=? AND filename=? AND published=1', [$match[1], $match[2]])->fetch();
            $file = $core->dataDir . '/packages/' . $match[1] . '/' . $match[2];
            if (!$row || !is_file($file)) { throw new HttpError(404, '安装包不存在或已撤下'); }
            $size = filesize($file); $start = 0; $end = $size - 1;
            header('Content-Type: application/octet-stream'); header('Content-Disposition: attachment; filename="' . $match[2] . '"');
            header('Cache-Control: public, max-age=31536000, immutable'); header('Accept-Ranges: bytes'); header('ETag: "' . $match[1] . '"');
            if (isset($_SERVER['HTTP_RANGE'])) {
                if (!preg_match('/^bytes=(\d*)-(\d*)$/D', $_SERVER['HTTP_RANGE'], $range) || ($range[1] === '' && $range[2] === '')) { throw new HttpError(416, '不支持的范围请求'); }
                if ($range[1] === '') { $start = max(0, $size - (int)$range[2]); }
                else { $start = (int)$range[1]; if ($range[2] !== '') { $end = min($end, (int)$range[2]); } }
                if ($start > $end || $start >= $size) { header('Content-Range: bytes */' . $size); throw new HttpError(416, '范围超出文件'); }
                http_response_code(206); header("Content-Range: bytes {$start}-{$end}/{$size}");
            } elseif (($_SERVER['HTTP_IF_NONE_MATCH'] ?? '') === '"' . $match[1] . '"') { http_response_code(304); exit; }
            header('Content-Length: ' . ($end - $start + 1));
            if ($method === 'HEAD') { exit; }
            $handle = fopen($file, 'rb'); fseek($handle, $start); $left = $end - $start + 1;
            while ($left > 0 && !feof($handle) && !connection_aborted()) { $chunk = fread($handle, min(1048576, $left)); echo $chunk; $left -= strlen($chunk); }
            fclose($handle); exit;
        }
        if (str_starts_with($path, '/api/admin/')) {
            $secure = $core->config['environment'] !== 'development';
            // OAuth returns via a cross-site top-level GET. Lax admits that callback, not cross-site POSTs.
            session_name('qqm_admin'); session_start(['use_strict_mode' => 1, 'use_only_cookies' => 1, 'cookie_httponly' => 1, 'cookie_secure' => $secure, 'cookie_samesite' => 'Lax', 'cookie_path' => '/api/admin']);
            $_SESSION['csrf'] ??= bin2hex(random_bytes(32));
            if (!in_array($method, ['GET', 'HEAD'], true)) {
                if (!hash_equals($_SESSION['csrf'], (string)($_SERVER['HTTP_X_CSRF_TOKEN'] ?? ''))) { throw new HttpError(403, '页面已过期，请刷新后重试'); }
                $origin = $_SERVER['HTTP_ORIGIN'] ?? '';
                if ($origin !== '' && $origin !== rtrim($core->config['app_url'], '/')) { throw new HttpError(403, '请求来源不受信任'); }
            }
            if ($path === '/api/admin/oauth/start' && $method === 'POST') {
                $core->rateLimit('login', $ip['ip'] ?? 'unknown', 8, 900); session_regenerate_id(true);
                respond(['url' => $account->start($_SESSION)]);
            }
            if ($path === '/api/admin/oauth/callback' && $method === 'GET') {
                $pendingState = $_SESSION['oauth_state'] ?? null;
                try {
                    $account->complete($_SESSION, $_GET); session_regenerate_id(true); $_SESSION['csrf'] = bin2hex(random_bytes(32));
                    $status = 'success';
                } catch (HttpError $error) {
                    // A forged cross-site callback must not log an existing admin out.
                    // Only a valid, consumed state is allowed to replace/clear identity.
                    if (is_string($pendingState) && !isset($_SESSION['oauth_state'])) { AccountLogin::clear($_SESSION); }
                    $status = $error->status === 502 || $error->status === 503 ? 'unavailable' : 'denied';
                }
                // Neither provider code, token nor upstream errors are ever reflected into the page URL.
                header('Location: /admin?login=' . $status, true, 303); exit;
            }
            $authenticated = $account->authenticated($_SESSION);
            if ($path === '/api/admin/session' && $method === 'GET') {
                respond(['authenticated' => $authenticated, 'csrf' => $_SESSION['csrf'], 'oauth_configured' => $account->configured(),
                    'admin' => $authenticated ? $_SESSION['admin'] : null]);
            }
            if (!$authenticated) { throw new HttpError(401, '请使用杂鱼账号登录管理后台'); }
            if ($path === '/api/admin/logout' && $method === 'POST') { $_SESSION = []; session_destroy(); respond(['ok' => true]); }
            session_write_close();
            if ($path === '/api/admin/stats' || str_starts_with($path, '/api/admin/devices/')) { throw new HttpError(410, '设备统计已移除；已有历史记录未被删除'); }
            if ($path === '/api/admin/releases' && $method === 'GET') { respond(['releases' => $core->releases(false)]); }
            if ($path === '/api/admin/releases' && $method === 'POST') {
                $upload = $_FILES['package'] ?? null;
                if (!$upload || $upload['error'] !== UPLOAD_ERR_OK) { throw new HttpError(422, '上传失败，请检查宝塔 PHP 的上传大小和超时设置'); }
                $fields = $_POST; $fields['build'] = filter_var($_POST['build'] ?? '', FILTER_VALIDATE_INT);
                respond($core->addRelease($fields, $upload['tmp_name']), 201);
            }
            if (preg_match('~^/api/admin/releases/([a-f0-9]{24})$~D', $path, $match) && $method === 'PATCH') {
                $input = body(); $touched = false;
                if (array_key_exists('published', $input)) {
                    if (!is_bool($input['published'])) { throw new HttpError(422, '发布状态需要布尔值'); }
                    $core->publish($match[1], $input['published']); $touched = true;
                }
                if (array_key_exists('force_update', $input)) {
                    if (!is_bool($input['force_update'])) { throw new HttpError(422, '强制更新需要布尔值'); }
                    $core->setForceUpdate($match[1], $input['force_update']); $touched = true;
                }
                if (!$touched) { throw new HttpError(422, '需要发布状态或强制更新开关'); }
                respond(['ok' => true]);
            }
            if ($path === '/api/admin/proxy' && $method === 'GET') {
                respond($core->proxyDiagnostics($_SERVER));
            }
        }
        throw new HttpError(404, '页面或接口不存在');
    } catch (HttpError $error) { respond(['error' => $error->getMessage()], $error->status); }
    catch (\JsonException) { respond(['error' => 'JSON 格式无效'], 400); }
    catch (\Throwable $error) { error_log('QQM request failed: ' . get_class($error)); respond(['error' => '服务暂不可用，请检查 PHP 扩展与服务端日志'], 500); }
}
