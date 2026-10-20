#!/usr/bin/env bash
# QQ Bot Manager: systemd installation with verified Release downloads.
# No admin password is collected here; the administrator sets it in the browser.
set -Eeuo pipefail
umask 077

die() { printf '安装未完成：%s\n' "$*" >&2; exit 1; }
help() {
  printf '%s\n' 'QQ机器人管理器 Linux 安装器' \
    'sudo bash install.sh --channel beta --install-deps' \
    '--channel stable|beta       选择正式版或 Beta（默认 stable）' \
    '--version v1.2.3            安装指定 Release，不覆盖已发布的文件' \
    '--host 0.0.0.0|127.0.0.1|:: 默认允许局域网/公网连接；防火墙需自行放行' \
    '--port 23336               修改监听端口' \
    '--public-url https://域名  HTTPS 反代的源地址；未指定 host 时改为仅本机监听' \
    '--access-url http://IP:端口 仅用于显示私有设置/访问链接' \
    '--install-deps             允许通过系统包管理器安装必要工具' \
    '--archive /路径/安装包.tar.gz  离线包，自动验证同名 .sha256 文件' \
    '--local                    安装此脚本旁已解压的服务包（须来自可信来源）' \
    '--print-link               仅显示已安装服务的私有链接' \
    '--check-only               只检查系统环境，不安装或修改文件' \
    '支持 x86_64、glibc >= 2.31 的 Linux + systemd；不支持 ARM 或 Alpine/musl。' \
    '程序 /opt/qqbotmanager，私有数据 /var/lib/qqbotmanager，升级保留密码与聊天。'
}

validate_archive() {
  local archive=$1 temp_dir=$2 name expected listed extra actual entry
  name=${archive##*/}
  [[ -f "$archive" && ! -L "$archive" && -f "$archive.sha256" && ! -L "$archive.sha256" ]] || die '缺少安装包或同名 .sha256 文件'
  [[ "$name" =~ ^qqbotmanager-linux-v[0-9A-Za-z.-]+-build[0-9]+-web-x64\.tar\.gz$ ]] || die '安装包文件名不符合 Linux 服务包格式'
  [[ $(wc -c < "$archive") -lt 67108864 ]] || die '安装包异常过大'
  read -r expected listed extra < "$archive.sha256" || die '校验文件无效'
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ && "${listed#\*}" == "$name" && -z "${extra:-}" && $(wc -l < "$archive.sha256") == 1 ]] || die '校验文件内容与安装包不匹配'
  actual=$(sha256sum -- "$archive"); actual=${actual%% *}
  [[ "${expected,,}" == "$actual" ]] || die 'SHA-256 不一致，文件损坏或被修改；不会安装'
  printf 'SHA-256 自动校验通过，无需手动操作。\n'
  # No absolute paths, traversal, symlinks, hardlinks or special files, even in
  # an explicitly supplied offline archive. Extract into a new private folder.
  LC_ALL=C tar -tzf "$archive" > "$temp_dir/entries"
  [[ $(wc -l < "$temp_dir/entries") -le 2000 ]] || die '压缩包条目异常过多'
  while IFS= read -r entry; do
    [[ "$entry" =~ ^qqbotmanager(/[A-Za-z0-9._/-]+)?/?$ && ! "$entry" =~ (^|/)\.\.?(/|$) && "$entry" != *'//'* ]] || die '压缩包包含不安全路径'
  done < "$temp_dir/entries"
  LC_ALL=C tar -tvzf "$archive" > "$temp_dir/listing"
  awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {exit 1} {total+=$3} END {if(total>268435456) exit 1}' "$temp_dir/listing" || die '压缩包含链接/特殊文件或展开大小异常'
}

channel=stable version='' archive='' local_package=false deps=false check_only=false print_link=false
bind_host='' port='' public_url='' access_url='' public_set=false
while (($#)); do
  case "$1" in
    --help|-h) help; exit 0 ;;
    --channel|--version|--archive|--host|--port|--public-url|--access-url)
      (($# >= 2)) && [[ "$2" != --* ]] || die "$1 缺少参数"
      case "$1" in
        --channel) channel=$2 ;; --version) version=$2 ;; --archive) archive=$2 ;;
        --host) bind_host=$2 ;; --port) port=$2 ;;
        --public-url) public_url=$2; public_set=true ;; --access-url) access_url=$2 ;;
      esac
      shift 2 ;;
    --local) local_package=true; shift ;;
    --install-deps) deps=true; shift ;;
    --check-only) check_only=true; shift ;;
    --print-link) print_link=true; shift ;;
    *) die "未知选项 $1；请用 --help 查看帮助" ;;
  esac
done
[[ "$channel" == stable || "$channel" == beta ]] || die 'channel 只能是 stable 或 beta'
[[ -z "$version" || "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]] || die '版本标签格式无效'
[[ -z "$archive" || "$local_package" == false ]] || die '--archive 与 --local 不能同时使用'

check_platform() {
  [[ $(uname -s) == Linux ]] || die '请在 Linux 服务器执行安装器'
  [[ $(uname -m) == x86_64 ]] || die '当前下载包只支持 x86_64 / amd64，不能在 ARM 上安装'
  local libc major minor
  libc=$(getconf GNU_LIBC_VERSION 2>/dev/null) || die '当前包需要 glibc，不适用于 Alpine/musl'
  [[ "$libc" =~ ^glibc\ ([0-9]+)\.([0-9]+)$ ]] || die '无法确认 glibc 版本'
  major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[2]}
  ((major > 2 || (major == 2 && minor >= 31))) || die '需要 glibc >= 2.31，请升级系统；不会修改系统 glibc'
  [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null || die '此自动安装方式需要运行中的 systemd；其他 init 系统请按文档手动启动'
  printf '系统检查通过：Linux x86_64，%s，systemd。\n' "$libc"
}

check_platform
if $check_only; then exit 0; fi
((EUID == 0)) || die '需要安装系统服务，请使用 sudo bash install.sh ...'

# Fixed, validated targets only. Never follow a user-controlled link as root.
for target in /var /var/lib /etc /etc/systemd /run; do
  [[ -d "$target" && ! -L "$target" ]] || die "系统目录不可用或是符号链接：$target"
done
for target in /opt /var/backups /etc/systemd/system; do
  [[ ! -L "$target" && ( ! -e "$target" || -d "$target" ) ]] || die "系统目录不可用或是符号链接：$target"
  if [[ ! -d "$target" ]]; then install -d -m 755 "$target"; fi
done
for target in /opt/qqbotmanager /var/lib/qqbotmanager /etc/qqbotmanager.env /etc/systemd/system/qqbotmanager.service /var/backups/qqbotmanager; do
  [[ ! -L "$target" ]] || die "目标是符号链接，不会写入：$target"
done

# Do not source configuration as shell code. Preserve installer-owned settings
# across updates, and only replace fields explicitly supplied by this run.
saved_host=0.0.0.0 saved_port=23336 saved_public=''
if [[ -f /etc/qqbotmanager.env ]]; then
  while IFS='=' read -r key value; do
    case "$key" in
      QQM_HOST) saved_host=$value ;; QQM_PORT) saved_port=$value ;;
      QQM_PUBLIC_URL) saved_public=$value ;;
      ''|'#'*) ;; *) die '已有环境配置包含未知项目，请先备份并人工检查 /etc/qqbotmanager.env' ;;
    esac
  done < /etc/qqbotmanager.env
fi
[[ -n "$bind_host" ]] || { bind_host=$saved_host; if $public_set; then bind_host=127.0.0.1; fi; }
port=${port:-$saved_port}
if ! $public_set; then public_url=$saved_public; fi
[[ "$bind_host" == 0.0.0.0 || "$bind_host" == 127.0.0.1 || "$bind_host" == :: ]] || die 'host 仅接受 0.0.0.0、127.0.0.1 或 ::'
[[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && ((port <= 65535)) || die '端口必须为 1–65535'
[[ -z "$public_url" || "$public_url" =~ ^https://[A-Za-z0-9.:-]+$ ]] || die 'public-url 必须为 HTTPS 源地址，不含路径、账号或查询参数'
access_pattern='^https?://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(:[0-9]{1,5})?/?$'
[[ -z "$access_url" || "$access_url" =~ $access_pattern ]] || die 'access-url 必须为 http(s)://主机:端口'
if [[ -z "$access_url" ]]; then
  address=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print $i; exit}}' || true)
  if [[ "$bind_host" == 127.0.0.1 || -z "$address" ]]; then address=127.0.0.1; fi
  access_url=${public_url:-http://$address:$port}
fi
show_link() {
  command -v runuser >/dev/null || die '缺少 runuser（util-linux）'
  runuser -u qqbotmanager -- /opt/qqbotmanager/qqm-server --data /var/lib/qqbotmanager --access-link "$access_url"
}
if $print_link; then
  [[ -x /opt/qqbotmanager/qqm-server ]] || die '尚未安装服务'
  show_link; exit 0
fi

if $deps; then
  # Dependency installation is opt-in. Never change firewall or SSH settings.
  # Keep existing compatible providers (e.g. curl-minimal/coreutils-single on
  # RPM systems) rather than replacing them or using --allowerasing.
  packages=(ca-certificates)
  for mapping in curl:curl tar:tar gzip:gzip jq:jq sha256sum:coreutils install:coreutils readlink:coreutils runuser:util-linux flock:util-linux; do
    command -v "${mapping%%:*}" >/dev/null || packages+=("${mapping#*:}")
  done
  need_user_tools=false
  if ! command -v useradd >/dev/null || ! command -v groupadd >/dev/null; then need_user_tools=true; fi
  if command -v apt-get >/dev/null; then
    if $need_user_tools; then packages+=(passwd); fi
    apt-get update
    apt-get install -y "${packages[@]}"
  elif command -v dnf >/dev/null; then
    if $need_user_tools; then packages+=(shadow-utils); fi
    dnf install -y "${packages[@]}"
  elif command -v yum >/dev/null; then
    if $need_user_tools; then packages+=(shadow-utils); fi
    yum install -y "${packages[@]}"
  elif command -v zypper >/dev/null; then
    if $need_user_tools; then packages+=(shadow); fi
    zypper --non-interactive install "${packages[@]}"
  elif command -v pacman >/dev/null; then
    if $need_user_tools; then packages+=(shadow); fi
    pacman -S --needed --noconfirm "${packages[@]}"
  else die '无法识别包管理器，请自行安装 curl、jq、tar、gzip、coreutils、util-linux 和 useradd'; fi
fi
for cmd in curl jq sha256sum tar gzip install readlink runuser flock useradd groupadd getent; do
  command -v "$cmd" >/dev/null || die "缺少工具 $cmd；可加 --install-deps 自动安装"
done
[[ ! -L /run/qqbotmanager-install.lock ]] || die '安装锁是符号链接，不会写入'
exec 9>/run/qqbotmanager-install.lock
flock -n 9 || die '另一个安装器正在运行，请等待它完成，不要并发替换程序'

download_dir=$(mktemp -d /tmp/qqm-download.XXXXXXXX)
stage_dir=''
cleanup() {
  # Only our mktemp directories can ever be recursively removed.
  if [[ "$download_dir" =~ ^/tmp/qqm-download\.[A-Za-z0-9]+$ && -d "$download_dir" && ! -L "$download_dir" && $(readlink -f -- "$download_dir") == "$download_dir" ]]; then
    rm -rf -- "$download_dir"
  fi
  if [[ "$stage_dir" =~ ^/opt/\.qqm-install\.[A-Za-z0-9]+$ && -d "$stage_dir" && ! -L "$stage_dir" && $(readlink -f -- "$stage_dir") == "$stage_dir" ]]; then
    rm -rf -- "$stage_dir"
  fi
}
trap cleanup EXIT
download() {
  curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 15 --max-time 300 --retry 3 --silent --show-error "$1" -o "$2"
}

if $local_package; then
  package_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
else
  if [[ -z "$archive" ]]; then
    api=https://api.github.com/repos/XingChenwa/qqm_project/releases
    if [[ -n "$version" ]]; then
      download "$api/tags/$version" "$download_dir/release.json"
    else
      download "$api?per_page=100" "$download_dir/releases.json"
      jq --argjson beta "$([[ "$channel" == beta ]] && printf true || printf false)" \
        'map(select(.draft == false and .prerelease == $beta)) | sort_by(.published_at) | reverse |
         map(select(any(.assets[]; .name | test("^qqbotmanager-linux-v[0-9A-Za-z.-]+-build[0-9]+-web-x64\\.tar\\.gz$")))) | .[0]' \
        "$download_dir/releases.json" > "$download_dir/release.json"
    fi
    asset=$(jq -r '.assets[]? | select(.name | test("^qqbotmanager-linux-v[0-9A-Za-z.-]+-build[0-9]+-web-x64\\.tar\\.gz$")) | .browser_download_url' "$download_dir/release.json")
    [[ "$asset" =~ ^https://github.com/XingChenwa/qqm_project/releases/download/v[0-9A-Za-z.-]+/qqbotmanager-linux-v[0-9A-Za-z.-]+-build[0-9]+-web-x64\.tar\.gz$ ]] || die '所选渠道/版本暂无可用的 Linux 安装包，请查看 Releases'
    name=${asset##*/}
    archive=$download_dir/$name
    printf '下载安装包：%s\n' "$name"
    download "$asset" "$archive"
    download "$asset.sha256" "$archive.sha256"
  else
    archive=$(readlink -f -- "$archive")
    name=${archive##*/}
  fi
  [[ -f "$archive" && ! -L "$archive" && -f "$archive.sha256" && ! -L "$archive.sha256" ]] || die '缺少安装包或同名 .sha256 文件'
  [[ "$name" =~ ^qqbotmanager-linux-v[0-9A-Za-z.-]+-build[0-9]+-web-x64\.tar\.gz$ ]] || die '安装包文件名不符合 Linux 服务包格式'
  validate_archive "$archive" "$download_dir"
  mkdir "$download_dir/unpacked"
  tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$download_dir/unpacked"
  package_dir=$download_dir/unpacked/qqbotmanager
fi

for file in qqm-server start.sh install.sh qqbotmanager.service server/web/index.html server/web/app.js server/web/style.css server/web/group-management.js plugins/index.json assets/branding/logo.png LICENSE README.md; do
  [[ -f "$package_dir/$file" && ! -L "$package_dir/$file" ]] || die "服务包不完整：$file"
done
[[ -z $(find "$package_dir" -type l -print -quit) ]] || die '服务包中不允许符号链接'
for private_file in data setup-token.txt admin-auth.json admin-password.txt; do
  [[ ! -e "$package_dir/$private_file" ]] || die '服务包不能包含私有数据'
done
stage_dir=$(mktemp -d /opt/.qqm-install.XXXXXXXX)
cp -R "$package_dir/." "$stage_dir/"
find "$stage_dir" -type d -exec chmod 755 {} +
find "$stage_dir" -type f -exec chmod 644 {} +
chmod 755 "$stage_dir/qqm-server" "$stage_dir/start.sh" "$stage_dir/install.sh"
# Do not execute downloaded files from /tmp: hardened Linux installations may
# mount it noexec. The private staging directory stays on the target filesystem.
package_dir=$stage_dir
"$package_dir/qqm-server" --help > "$download_dir/help"
grep -q -- '--access-link' "$download_dir/help" || die '此旧包不支持网页安全入口，请等待包含本次功能的新版本；不会安装旧行为的服务'
# Let the native URL parser reject malformed ports/authorities before any
# service files or user data are touched. The synthetic setup file is private.
"$package_dir/qqm-server" --data "$download_dir/url-check" --access-link "$access_url" > /dev/null
if [[ -n "$public_url" ]]; then
  "$package_dir/qqm-server" --data "$download_dir/url-check" --access-link "$public_url" > /dev/null
fi

if [[ -e /opt/qqbotmanager && ! -f /opt/qqbotmanager/.qqm-managed ]]; then
  die '/opt/qqbotmanager 已存在且不是此安装器创建的目录；请先按文档备份并迁移，不会覆盖'
fi
[[ ! -d /opt/qqbotmanager/data ]] || die '发现程序目录中的旧 data；请先备份并迁移至服务数据目录，不会混合数据'
getent group qqbotmanager >/dev/null || groupadd --system qqbotmanager
if ! id qqbotmanager >/dev/null 2>&1; then
  nologin=$(command -v nologin || printf /bin/false)
  useradd --system --gid qqbotmanager --home-dir /var/lib/qqbotmanager --shell "$nologin" qqbotmanager
fi
[[ $(id -u qqbotmanager) != 0 && $(id -g qqbotmanager) != 0 && $(getent group qqbotmanager | cut -d: -f3) != 0 ]] || die '服务账号及用户组不能是 root'
IFS=: read -r account_name account_marker account_uid account_gid account_gecos account_dir account_shell < <(getent passwd qqbotmanager)
[[ "$account_dir" == /var/lib/qqbotmanager && ( "$account_shell" == */nologin || "$account_shell" == /bin/false ) ]] || die '已有同名账号不是专用服务账号；不会改动它的主目录或登录设置'
install -d -m 700 -o qqbotmanager -g qqbotmanager /var/lib/qqbotmanager
install -d -m 700 /var/backups/qqbotmanager
stamp=$(date +%Y%m%d-%H%M%S)-$$
backup=/var/backups/qqbotmanager/$stamp
mkdir -m 700 "$backup"
printf '%s\n' 'QQM installer managed; keep /var/lib/qqbotmanager when upgrading.' > "$stage_dir/.qqm-managed"

was_active=false
if systemctl is-active --quiet qqbotmanager; then was_active=true; fi
if ! systemctl stop qqbotmanager 2>/dev/null; then
  if $was_active; then die '无法停止已有服务，未替换程序'; fi
fi
swapped=false config_written=false
rollback() {
  trap - ERR
  set +e
  systemctl stop qqbotmanager 2>/dev/null
  if $swapped && [[ -d /opt/qqbotmanager ]]; then mv /opt/qqbotmanager "$backup/failed-program"; fi
  if [[ -d "$backup/program" && ! -e /opt/qqbotmanager ]]; then mv "$backup/program" /opt/qqbotmanager; fi
  if $config_written; then
    [[ ! -f /etc/qqbotmanager.env ]] || mv /etc/qqbotmanager.env "$backup/failed-service.env"
    [[ ! -f /etc/systemd/system/qqbotmanager.service ]] || mv /etc/systemd/system/qqbotmanager.service "$backup/failed-service.unit"
    [[ ! -f "$backup/service.env" ]] || cp -p "$backup/service.env" /etc/qqbotmanager.env
    [[ ! -f "$backup/service.unit" ]] || cp -p "$backup/service.unit" /etc/systemd/system/qqbotmanager.service
  fi
  systemctl daemon-reload
  if $was_active; then systemctl start qqbotmanager; fi
  die "新服务安装/检查失败，已保留或恢复旧程序，没有重置数据；备份：$backup。请查看 journalctl -u qqbotmanager（分享前去除敏感信息）"
}
trap rollback ERR
tar -czf "$backup/private-data.tar.gz" -C /var/lib qqbotmanager
[[ ! -f /etc/qqbotmanager.env ]] || cp -p /etc/qqbotmanager.env "$backup/service.env"
[[ ! -f /etc/systemd/system/qqbotmanager.service ]] || cp -p /etc/systemd/system/qqbotmanager.service "$backup/service.unit"
if [[ -d /opt/qqbotmanager ]]; then mv /opt/qqbotmanager "$backup/program"; fi
mv "$stage_dir" /opt/qqbotmanager
swapped=true
stage_dir=''
config_written=true
printf 'QQM_HOST=%s\nQQM_PORT=%s\nQQM_PUBLIC_URL=%s\n' "$bind_host" "$port" "$public_url" > /etc/qqbotmanager.env
chmod 600 /etc/qqbotmanager.env
install -m 644 /opt/qqbotmanager/qqbotmanager.service /etc/systemd/system/qqbotmanager.service
systemctl daemon-reload

healthy() {
  local i host_header="127.0.0.1:$port"
  [[ -z "$public_url" ]] || host_header=${public_url#https://}
  for ((i=0;i<30;i++)); do
    if systemctl is-active --quiet qqbotmanager && curl --noproxy '*' --silent --fail --max-time 2 -H "Host: $host_header" "http://127.0.0.1:$port/health" | grep -q '"ok":true'; then return 0; fi
    sleep 0.5
  done
  return 1
}
if ! systemctl start qqbotmanager || ! healthy; then
  rollback
fi
systemctl enable qqbotmanager
trap - ERR
printf '\n安装完成。程序以低权限账号运行，备份：%s\n' "$backup"
printf '首次打开以下链接，在网页设置管理员密码和安全入口；安装终端不要求输入密码。\n'
show_link
printf '\n以后请收藏带安全入口的完整地址。不要分享初始化链接。\n'
printf '不会自动放行防火墙：局域网/公网访问需要允许 TCP %s；家用网络还需端口映射或公网入口。\n' "$port"
printf '公网建议使用 HTTPS 域名反向代理；HTTP 和安全入口都不能加密密码或消息。\n'
