<?php
// Test router is outside the public root. NEVER use it as the production entrypoint.
declare(strict_types=1);
if (PHP_SAPI !== 'cli-server' || !in_array($_SERVER['REMOTE_ADDR'] ?? '', ['127.0.0.1', '::1'], true)
    || !str_starts_with(basename(getenv('QQM_DATA_DIR') ?: ''), 'qqm-http-test-')) { http_response_code(404); exit; }
require dirname(__DIR__) . '/src/Core.php';
require dirname(__DIR__) . '/src/AccountLogin.php';
require dirname(__DIR__) . '/src/Http.php';
$core = new QQM\Core(dirname(__DIR__));
$transport = static function (string $url, ?array $form, ?string $bearer): array {
    if ($url === QQM\AccountLogin::TOKEN_URL) {
        if (!in_array($form['code'], ['test-admin-code', 'test-other-code', 'test-no-email-code'], true)) { throw new QQM\HttpError(401, 'Fixture rejected unknown code'); }
        return ['access_token' => $form['code'], 'token_type' => 'Bearer', 'expires_in' => 3600, 'scope' => 'public_profile user_email'];
    }
    $user = ['open_id' => 'test-open-id', 'email' => $bearer === 'test-other-code' ? 'not-admin@qq.com' : '2377130783@qq.com', 'nickname' => '测试管理员'];
    if ($bearer === 'test-no-email-code') { unset($user['email']); }
    return ['user' => $user];
};
return QQM\serve($core, new QQM\AccountLogin($core, $transport));
