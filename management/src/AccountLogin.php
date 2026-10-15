<?php
declare(strict_types=1);

namespace QQM;

use Closure;

/** Server-side OAuth only. Never accepts an email or access token from the browser. */
final class AccountLogin
{
    public const AUTHORIZE_URL = 'https://account.uuze.cn/oauth/authorize';
    public const TOKEN_URL = 'https://zhapi.uuze.cn/oauth/token';
    public const PROFILE_URL = 'https://zhapi.uuze.cn/v1/oauth/me';
    private readonly Closure $request;

    // A transport can be injected by isolated tests; production always uses verified HTTPS/cURL.
    public function __construct(private readonly Core $core, ?Closure $request = null)
    {
        $this->request = $request ?? self::https(...);
    }

    public function configured(): bool
    {
        return is_string($this->core->config['uuze_client_id']) && $this->core->config['uuze_client_id'] !== ''
            && is_string($this->core->config['uuze_client_secret']) && $this->core->config['uuze_client_secret'] !== '';
    }

    public function callbackUrl(): string { return rtrim($this->core->config['app_url'], '/') . '/api/admin/oauth/callback'; }

    public function start(array &$session): string
    {
        if (!$this->configured()) { throw new HttpError(503, '尚未配置杂鱼账号登录，请在服务器填写 Client ID 和 Client Secret'); }
        $session['oauth_state'] = bin2hex(random_bytes(32)); $session['oauth_started'] = time();
        return self::AUTHORIZE_URL . '?' . http_build_query([
            'response_type' => 'code', 'client_id' => $this->core->config['uuze_client_id'],
            'redirect_uri' => $this->callbackUrl(), 'scope' => 'public_profile user_email', 'state' => $session['oauth_state'],
        ], '', '&', PHP_QUERY_RFC3986);
    }

    public function complete(array &$session, array $query): void
    {
        $state = $query['state'] ?? null;
        if (!is_string($state) || !isset($session['oauth_state'], $session['oauth_started'])
            || time() - $session['oauth_started'] > 600 || time() < $session['oauth_started']
            || !hash_equals($session['oauth_state'], $state)) { throw new HttpError(403, '授权校验失败或已过期，请重新登录'); }
        // Consume the state before any network call. Never retry a one-time authorization code.
        unset($session['oauth_state'], $session['oauth_started']);
        if (isset($query['error'])) { throw new HttpError(403, '已取消账号授权，请重新登录'); }
        $code = $query['code'] ?? null;
        if (!is_string($code) || $code === '' || strlen($code) > 2048 || preg_match('/[\x00-\x1f]/', $code)) { throw new HttpError(403, '缺少有效授权码，请重新登录'); }
        if (!$this->configured()) { throw new HttpError(503, '尚未配置杂鱼账号登录'); }
        $token = ($this->request)(self::TOKEN_URL, [
            'grant_type' => 'authorization_code', 'code' => $code,
            'client_id' => $this->core->config['uuze_client_id'], 'client_secret' => $this->core->config['uuze_client_secret'],
            'redirect_uri' => $this->callbackUrl(),
        ], null);
        $access = $token['access_token'] ?? null; $expires = $token['expires_in'] ?? 0;
        if (!is_string($access) || $access === '' || strlen($access) > 8192 || preg_match('/[\x00-\x20\x7f]/', $access)
            || !is_string($token['token_type'] ?? null) || strcasecmp($token['token_type'], 'Bearer') !== 0
            || !is_numeric($expires) || (int)$expires < 1
            || !is_string($token['scope'] ?? null) || !in_array('user_email', explode(' ', $token['scope']), true)) {
            throw new HttpError(403, '授权未包含邮箱权限，请在账号中心申请并重新授予 user_email');
        }
        $identity = $this->identity(($this->request)(self::PROFILE_URL, null, $access));
        $session['admin'] = $identity;
        $session['oauth_access_token'] = $access;
        $session['login_expires'] = time() + min(3600, (int)$expires);
        $session['profile_checked'] = time(); $session['last_activity'] = time();
        // The refresh token is deliberately discarded. Re-authorize after one hour instead of storing it.
    }

    public function authenticated(array &$session): bool
    {
        if (empty($session['admin'])) { return false; }
        if (($session['login_expires'] ?? 0) <= time() || ($session['last_activity'] ?? 0) < time() - 1800
            || !isset($session['admin']['email'], $session['admin']['open_id'], $session['oauth_access_token'])
            || !hash_equals(strtolower($this->core->config['admin_email']), strtolower($session['admin']['email']))) {
            self::clear($session); return false;
        }
        if (($session['profile_checked'] ?? 0) < time() - 300) {
            try {
                $identity = $this->identity(($this->request)(self::PROFILE_URL, null, $session['oauth_access_token']));
                if (!hash_equals($session['admin']['open_id'], $identity['open_id'])) { throw new HttpError(403, '登录身份已变化，请重新登录'); }
                $session['admin'] = $identity; $session['profile_checked'] = time();
            } catch (HttpError $error) {
                if (in_array($error->status, [401, 403], true)) { self::clear($session); return false; }
                throw $error;
            }
        }
        $session['last_activity'] = time(); return true;
    }

    public static function clear(array &$session): void
    {
        foreach (['admin', 'oauth_access_token', 'login_expires', 'profile_checked', 'last_activity', 'oauth_state', 'oauth_started'] as $key) { unset($session[$key]); }
    }

    private function identity(array $response): array
    {
        $user = $response['user'] ?? null;
        $email = is_array($user) && is_string($user['email'] ?? null) ? strtolower(trim($user['email'])) : '';
        $openId = is_array($user) ? ($user['open_id'] ?? null) : null;
        // The provider documents a bound email, not an email_verified field. Reject an explicit false flag if supplied.
        if (!filter_var($email, FILTER_VALIDATE_EMAIL) || !hash_equals(strtolower($this->core->config['admin_email']), $email)
            || ($user['email_verified'] ?? true) === false || !is_string($openId) || $openId === '' || strlen($openId) > 256) {
            throw new HttpError(403, '此账号没有后台管理权限；请使用 2377130783@qq.com 绑定的杂鱼账号');
        }
        $nickname = '管理员';
        if (is_string($user['nickname'] ?? null) && preg_match('/^.{0,80}/us', $user['nickname'], $match)) { $nickname = $match[0]; }
        return ['open_id' => $openId, 'email' => $email, 'nickname' => $nickname];
    }

    private static function https(string $url, ?array $form, ?string $bearer): array
    {
        if (!function_exists('curl_init')) { throw new HttpError(503, '服务器需要启用 PHP cURL 扩展及有效的 CA 证书'); }
        if (!in_array($url, [self::TOKEN_URL, self::PROFILE_URL], true)) { throw new HttpError(500, '授权接口配置无效'); }
        $response = ''; $handle = curl_init($url);
        curl_setopt_array($handle, [
            CURLOPT_CONNECTTIMEOUT => 5, CURLOPT_TIMEOUT => 15, CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_PROTOCOLS => CURLPROTO_HTTPS, CURLOPT_SSL_VERIFYPEER => true, CURLOPT_SSL_VERIFYHOST => 2,
            CURLOPT_HTTPHEADER => $form !== null ? ['Accept: application/json', 'Content-Type: application/x-www-form-urlencoded'] : ['Accept: application/json', 'Authorization: Bearer ' . $bearer],
            CURLOPT_WRITEFUNCTION => static function ($curl, string $chunk) use (&$response): int {
                if (strlen($response) + strlen($chunk) > 65536) { return 0; }
                $response .= $chunk; return strlen($chunk);
            },
        ]);
        if ($form !== null) { curl_setopt_array($handle, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => http_build_query($form, '', '&', PHP_QUERY_RFC3986)]); }
        $ok = curl_exec($handle); $status = (int)curl_getinfo($handle, CURLINFO_RESPONSE_CODE); curl_close($handle);
        if ($status === 401 || $status === 403) { throw new HttpError(401, '账号授权已失效，请重新登录'); }
        if ($ok === false || $status !== 200) { throw new HttpError(502, '账号中心暂不可用或授权码已失效，请重新发起登录'); }
        try { $decoded = json_decode($response, true, 32, JSON_THROW_ON_ERROR); } catch (\JsonException) { throw new HttpError(502, '账号中心返回异常，请稍后重新登录'); }
        if (!is_array($decoded) || isset($decoded['error'])) { throw new HttpError(502, '账号授权失败，请检查应用凭据、回调和权限'); }
        return $decoded;
    }
}
