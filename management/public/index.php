<?php
declare(strict_types=1);

try {
    require dirname(__DIR__) . '/src/Core.php';
    require dirname(__DIR__) . '/src/AccountLogin.php';
    require dirname(__DIR__) . '/src/Http.php';
    $core = new QQM\Core(dirname(__DIR__));
    return QQM\serve($core, new QQM\AccountLogin($core));
} catch (QQM\HttpError $error) {
    QQM\respond(['error' => $error->getMessage()], $error->status);
} catch (Throwable $error) {
    error_log('QQM startup failed: ' . get_class($error));
    $body = ['error' => '服务暂不可用，请在应用目录运行 php bin/manage.php db-check 检查配置与 MySQL，并确认 src 文件上传完整。'];
    if (function_exists('QQM\\respond')) { QQM\respond($body, 500); }
    else {
        http_response_code(500); header('Content-Type: application/json; charset=utf-8'); header('Cache-Control: no-store');
        echo json_encode($body, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
    }
}
