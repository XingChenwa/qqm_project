<?php
// No network requests, no real OAuth credentials or user records.
declare(strict_types=1);
require dirname(__DIR__) . '/src/Core.php';
require dirname(__DIR__) . '/src/AccountLogin.php';
require __DIR__ . '/database.php';
use QQM\Core;
use QQM\AccountLogin;
use QQM\HttpError;

$path = sys_get_temp_dir() . '/qqm-oauth-test-' . bin2hex(random_bytes(10));
$passed = 0; $calls = [];
function check(bool $condition, string $name): void { global $passed; if (!$condition) { throw new RuntimeException($name); } $passed++; }
function rejects(Closure $task, int $status): void { try { $task(); } catch (HttpError $error) { check($error->status === $status, 'Expected error status'); return; } throw new RuntimeException('Expected rejection'); }
$token = ['access_token' => 'test-only-access', 'token_type' => 'Bearer', 'expires_in' => 3600, 'scope' => 'public_profile user_email', 'refresh_token' => 'test-only-refresh'];
$profile = ['user' => ['open_id' => 'fixture-open-id', 'email' => '2377130783@qq.com', 'nickname' => '本地测试']];
try {
    $database = testDatabase('oauth');
    $core = new Core(dirname(__DIR__), $path, ['database' => $database, 'uuze_client_id' => 'test-only-client', 'uuze_client_secret' => 'test-only-secret'], false);
    $core->initializeSchema();
    $login = new AccountLogin($core, static function ($url, $form, $bearer) use (&$calls, &$token, &$profile): array {
        $calls[] = [$url, $form, $bearer]; return $url === AccountLogin::TOKEN_URL ? $token : $profile;
    });
    $session = []; parse_str(parse_url($login->start($session), PHP_URL_QUERY), $query);
    check($query['response_type'] === 'code' && strlen($query['state']) === 64, 'Strong state and explicit grant');
    check($query['redirect_uri'] === 'https://botmanager.uuze.cn/api/admin/oauth/callback', 'Exact callback');
    check(!isset($query['client_secret']) && str_contains($query['scope'], 'user_email'), 'Secret stays server-side');
    rejects(fn() => $login->complete($session, ['code' => 'one-time', 'state' => 'forged', 'email' => '2377130783@qq.com']), 403);
    check(count($calls) === 0, 'State checked before transport');
    $login->complete($session, ['state' => $query['state'], 'code' => 'one-time']);
    check($login->authenticated($session), 'Authorized email accepted');
    check($session['admin']['open_id'] === 'fixture-open-id', 'Provider open_id as identity');
    check(!isset($session['refresh_token']), 'No refresh token persistence');
    check($calls[0][0] === AccountLogin::TOKEN_URL && $calls[0][1]['client_secret'] === 'test-only-secret', 'Token form server-side');
    check($calls[1][0] === AccountLogin::PROFILE_URL && $calls[1][2] === 'test-only-access', 'Authenticated provider profile');
    rejects(fn() => $login->complete($session, ['state' => $query['state'], 'code' => 'one-time']), 403);
    $profile['user']['email'] = 'someone-else@qq.com';
    $other = []; $login->start($other); $otherState = $other['oauth_state'];
    rejects(fn() => $login->complete($other, ['state' => $otherState, 'code' => 'other', 'email' => '2377130783@qq.com']), 403);
    $profile['user']['email'] = '2377130783@qq.com';
    unset($profile['user']['email']); $missing = []; $login->start($missing); $missingState = $missing['oauth_state'];
    rejects(fn() => $login->complete($missing, ['state' => $missingState, 'code' => 'missing']), 403);
    $profile['user']['email'] = '2377130783@qq.com'; $token['scope'] = 'public_profile';
    $noScope = []; $login->start($noScope); $noScopeState = $noScope['oauth_state'];
    rejects(fn() => $login->complete($noScope, ['state' => $noScopeState, 'code' => 'no-scope']), 403);
    $token['scope'] = 'public_profile user_email';
    $old = []; $login->start($old); $old['oauth_started'] -= 601; $oldState = $old['oauth_state'];
    rejects(fn() => $login->complete($old, ['state' => $oldState, 'code' => 'old']), 403);
    $denied = []; $login->start($denied); $deniedState = $denied['oauth_state'];
    rejects(fn() => $login->complete($denied, ['state' => $deniedState, 'error' => 'access_denied', 'code' => 'ignored']), 403);
    $session['profile_checked'] -= 301; $profile['user']['email'] = 'changed@qq.com';
    check(!$login->authenticated($session) && !isset($session['oauth_access_token']), 'Recheck rejects revoked admin identity');
    $profile['user']['email'] = '2377130783@qq.com';
    $login->start($session); $login->complete($session, ['state' => $session['oauth_state'], 'code' => 'renew']);
    $session['login_expires'] = time() - 1;
    check(!$login->authenticated($session), 'Absolute session expiry');
    $unconfigured = new AccountLogin(new Core(dirname(__DIR__), $path, ['database' => $database])); $blank = [];
    rejects(fn() => $unconfigured->start($blank), 503);
    echo "OAuth: {$passed} checks passed.\n";
} finally {
    unset($core, $login, $unconfigured); $resolved = realpath($path);
    if ($resolved && str_starts_with(basename($resolved), 'qqm-oauth-test-') && dirname($resolved) === realpath(sys_get_temp_dir())) {
        foreach (new DirectoryIterator($resolved) as $file) { if ($file->isFile()) { unlink($file->getPathname()); } }
        rmdir($resolved);
    }
}
