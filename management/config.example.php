<?php
declare(strict_types=1);

// 新安装：在宝塔文件管理复制本文件为同级的 config.php，填写数据库和 OAuth 凭据。
// 或先运行 php bin/manage.php install，自动创建 config.php，再填写并重新执行。
// config.php 只能放在 public 之外；不要发到聊天、提交 Git 或覆盖已有服务器配置。
return [
    'app_url' => 'https://botmanager.uuze.cn',
    'environment' => 'production',
    'database' => [
        'host' => '127.0.0.1',
        'port' => 3306,
        'name' => '', // 宝塔“数据库”中创建的数据库名，例如 botmanager。
        'username' => '', // 该数据库的专用账号，不使用 MySQL root。
        'password' => '', // 仅在服务器填写宝塔数据库密码。
        'socket' => '', // 本机 Unix socket 可选，例如 /tmp/mysql.sock。
        'ssl_ca' => '', // 远程数据库请配置受信任的 CA 并限制网络访问。
    ],
    'admin_email' => '2377130783@qq.com',
    // 在杂鱼账号中心申请 public_profile + user_email，凭据仅保存在服务器。
    'uuze_client_id' => '',
    'uuze_client_secret' => '',
    // 签名私钥与 origin_token 由 install 自动生成到 data/config.json，不要手填或重置。
    'require_origin_token' => false, // EdgeOne 配置完成后改为 true。
    // 免费版：配好 HTTPS 回源和回源密钥覆盖规则后，设为 edgeone_token，并把上一项设为 true。
    // 默认 cidr_and_token 保留网段 + 密钥双重校验，不自动放宽旧部署。
    'proxy_trust_mode' => 'cidr_and_token',
    'trusted_proxy_cidrs' => [], // 严格模式填当前实际回源网段；免费版模式可留空，禁止填 /0。
    'client_ip_header' => 'EO-Connecting-IP',
    'max_upload_bytes' => 1073741824,
];
