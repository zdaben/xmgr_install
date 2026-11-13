#!/bin/bash

# ==========================================
# Xray (VLESS + Reality) 极简加固部署脚本
# ==========================================

# 终端配色定义
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
cyan='\033[0;36m'
plain='\033[0m'

# 核心路径与常量定义
CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CACHE_FILE="${CONFIG_DIR}/.xray_info"
SCRIPT_PATH="/usr/local/bin/xmgr"
SYSCTL_FILE="/etc/sysctl.d/99-xray-bbr.conf"
CADDY_FILE="/etc/caddy/Caddyfile"
SITE_ROOT="/var/www/site"
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

# 运行期状态变量
PKG_MGR=""
VALID_LOCAL_DOMAINS=()
LOCAL_WEB_PORT="443"
LOCAL_PROBE_IP="127.0.0.1"
ALREADY_MIGRATED=0
VPS_IPV4=""
VPS_IPV6=""
LAST_CHECK_MSG=""
SETUP_CADDY_DOMAIN=""
SETUP_CADDY_TARGET=""
SETUP_CADDY_PORT=""

# 检查是否为 Root 用户
[[ $EUID -ne 0 ]] && echo -e "${red}[错误] 必须使用 root 用户运行此脚本。${plain}" && exit 1

# 注册系统级全局命令（仅当以常规文件执行时复制自身）
if [ "$0" != "$SCRIPT_PATH" ]; then
    if [ -f "$0" ]; then
        cp -f "$0" "$SCRIPT_PATH"
        chmod 755 "$SCRIPT_PATH"
        if [ -z "${1:-}" ]; then
            echo -e "${green}[信息] 脚本已成功安装为全局系统命令: xmgr${plain}"
            echo -e "请运行 ${green}xmgr install${plain} 开始部署，或输入 ${green}xmgr help${plain} 查看可用命令。"
            exit 0
        fi
    else
        echo -e "${yellow}[提示] 检测到通过管道或进程替换方式运行，请先下载为本地文件后执行：${plain}"
        echo -e "  curl -fsSL <脚本Raw地址> -o ${SCRIPT_PATH} && chmod +x ${SCRIPT_PATH} && xmgr install"
        exit 1
    fi
fi

# ==========================================
# 基础环境与工具函数
# ==========================================

detect_pkg_mgr() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
    else
        echo -e "${red}[错误] 未检测到受支持的包管理器 (apt/dnf/yum)。${plain}"
        exit 1
    fi
}

install_deps() {
    detect_pkg_mgr
    local pkgs_apt="curl wget tar unzip openssl iproute2 jq gnupg ca-certificates"
    local pkgs_rpm="curl wget tar unzip openssl iproute jq ca-certificates"
    local log_tmp
    log_tmp=$(mktemp)

    echo -e "状态: ${yellow}正在检查并安装系统基础依赖...${plain}"
    if [ "$PKG_MGR" = "apt" ]; then
        if ! apt-get update -y >"$log_tmp" 2>&1 || ! DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs_apt >>"$log_tmp" 2>&1; then
            echo -e "${red}[错误] 基础依赖安装失败，日志如下：${plain}"
            tail -n 20 "$log_tmp"
            rm -f "$log_tmp"
            exit 1
        fi
    else
        if ! "$PKG_MGR" install -y $pkgs_rpm >"$log_tmp" 2>&1; then
            echo -e "${red}[错误] 基础依赖安装失败，日志如下：${plain}"
            tail -n 20 "$log_tmp"
            rm -f "$log_tmp"
            exit 1
        fi
    fi
    rm -f "$log_tmp"
}

# 启用 BBR 拥塞控制（兼容现代 sysctl.d 规范）
enable_bbr() {
    if [ ! -f "$SYSCTL_FILE" ]; then
        cat > "$SYSCTL_FILE" <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
        sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    fi
}

# 安装或升级 Xray-core 官方内核
install_or_update_xray_core() {
    local action="${1:-install}"
    local log_tmp
    log_tmp=$(mktemp)

    echo -e "状态: ${yellow}正在部署最新版 Xray-core 官方内核...${plain}"
    if ! bash -c "$(curl -fsSL "$XRAY_INSTALL_URL")" @ "$action" >"$log_tmp" 2>&1; then
        echo -e "${red}[错误] Xray-core 部署失败，日志如下：${plain}"
        tail -n 25 "$log_tmp"
        rm -f "$log_tmp"
        exit 1
    fi
    rm -f "$log_tmp"

    if ! command -v xray >/dev/null 2>&1; then
        echo -e "${red}[错误] 未找到 xray 可执行文件，部署中止。${plain}"
        exit 1
    fi

    local ver
    ver=$(xray version 2>/dev/null | head -n 1)
    echo -e "当前内核: ${green}${ver}${plain}"
}

# UTF-8 安全的 URL 百分号编码
urlencode() {
    (
        export LC_ALL=C
        local string="$1"
        local length="${#string}"
        local i c
        for (( i = 0; i < length; i++ )); do
            c="${string:i:1}"
            case "$c" in
                [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
                *) printf '%%%02X' "'$c" ;;
            esac
        done
    )
}

get_loopback_ip() {
    if ip -4 addr show dev lo 2>/dev/null | grep -q "127.0.0.1"; then
        echo "127.0.0.1"
    else
        echo "::1"
    fi
}

format_host_port() {
    local host="$1"
    local port="$2"
    if [[ "$host" == *:* ]]; then
        echo "[${host}]:${port}"
    else
        echo "${host}:${port}"
    fi
}

detect_public_ips() {
    local url ip
    VPS_IPV4=""
    VPS_IPV6=""

    for url in "https://api.ipify.org" "https://ifconfig.me" "https://ip.sb"; do
        ip=$(curl -s4m5 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            VPS_IPV4="$ip"
            break
        fi
    done

    if ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then
        for url in "https://api64.ipify.org" "https://ifconfig.me" "https://ip.sb"; do
            ip=$(curl -s6m5 "$url" 2>/dev/null | tr -d '[:space:]')
            if [[ "$ip" =~ ^[0-9a-fA-F:]+$ && "$ip" == *:* ]]; then
                VPS_IPV6="$ip"
                break
            fi
        done
    fi
}

is_port_in_use() {
    local p="$1"
    ss -tln 2>/dev/null | grep -qE "(:${p}|\[::\]:${p})\s"
}

random_high_port() {
    local p
    for _ in {1..20}; do
        p=$(shuf -i 10000-60000 -n 1)
        if ! is_port_in_use "$p"; then
            echo "$p"
            return 0
        fi
    done
    echo "24680"
}

# ==========================================
# Reality 目标站点合规性校验
# ==========================================

check_reality_sni() {
    local domain="$1"
    local target_ip="${2:-}"
    local target_port="${3:-443}"
    local ping_out=""
    local sni_block=""
    LAST_CHECK_MSG=""

    if [ -n "$target_ip" ]; then
        ping_out=$(timeout 8 xray tls ping -ip "$target_ip" "${domain}:${target_port}" 2>&1)
    else
        ping_out=$(timeout 8 xray tls ping "${domain}:${target_port}" 2>&1)
    fi

    sni_block=$(echo "$ping_out" | awk '/Pinging with SNI/{flag=1} flag')
    if [ -z "$sni_block" ] || ! echo "$sni_block" | grep -q "Handshake succeeded"; then
        LAST_CHECK_MSG="TLS 握手失败或连接超时"
        return 1
    fi

    if ! echo "$sni_block" | grep -qE "TLS Version:[[:space:]]*TLS 1\.3"; then
        LAST_CHECK_MSG="不支持 TLS 1.3"
        return 1
    fi

    if echo "$sni_block" | grep -qiE "CurveP256|CurveP384|CurveP521|RSA Exchange"; then
        LAST_CHECK_MSG="密钥交换非 X25519 (可能触发 HelloRetryRequest)"
        return 1
    fi

    local allowed_domains
    allowed_domains=$(echo "$sni_block" | awk -F':[[:space:]]+' '/Cert'\''s allowed domains:/ {print $2}' | tr -d '[]' | tail -n 1)
    if [ -n "$allowed_domains" ]; then
        local match_ok=0
        local ad suffix
        for ad in $allowed_domains; do
            if [ "$ad" = "$domain" ]; then
                match_ok=1
                break
            elif [[ "$ad" == \*.* ]]; then
                suffix="${ad#\*.}"
                if [[ "$domain" == *."$suffix" && "${domain%.$suffix}" != *.* ]]; then
                    match_ok=1
                    break
                fi
            fi
        done
        if [ $match_ok -eq 0 ]; then
            LAST_CHECK_MSG="证书域名与 SNI 不匹配 (${allowed_domains})"
            return 1
        fi
    fi

    local connect_addr
    connect_addr=$(format_host_port "${target_ip:-$domain}" "$target_port")
    local alpn_out
    alpn_out=$(echo | timeout 4 openssl s_client -connect "$connect_addr" -servername "$domain" -alpn h2 2>/dev/null || true)
    if ! echo "$alpn_out" | grep -q "ALPN protocol: h2"; then
        LAST_CHECK_MSG="TLS1.3+X25519 (建议开启 HTTP/2)"
        return 0
    fi

    local pq_tag="X25519"
    echo "$sni_block" | grep -qi "X25519MLKEM768" && pq_tag="X25519MLKEM768"
    LAST_CHECK_MSG="TLS1.3+H2+${pq_tag}"
    return 0
}

# ==========================================
# 系统防火墙管理（ufw / firewalld / iptables 互斥管理）
# ==========================================

remove_port_firewall() {
    local old_port="$1"
    [ -z "$old_port" ] && return 0

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow "${old_port}/tcp" >/dev/null 2>&1 || true
        return 0
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --remove-port="${old_port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        return 0
    fi

    if command -v iptables >/dev/null 2>&1; then
        while iptables -C INPUT -p tcp --dport "$old_port" -j ACCEPT >/dev/null 2>&1; do
            iptables -D INPUT -p tcp --dport "$old_port" -j ACCEPT >/dev/null 2>&1 || break
        done
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        while ip6tables -C INPUT -p tcp --dport "$old_port" -j ACCEPT >/dev/null 2>&1; do
            ip6tables -D INPUT -p tcp --dport "$old_port" -j ACCEPT >/dev/null 2>&1 || break
        done
    fi
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
}

apply_port_firewall() {
    local port="$1"
    local old_port="${2:-}"

    if [ -n "$old_port" ] && [ "$old_port" != "$port" ]; then
        remove_port_firewall "$old_port"
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
        return 0
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        return 0
    fi

    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || \
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
    fi
    if command -v ip6tables >/dev/null 2>&1 && [ -n "$VPS_IPV6" ]; then
        ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || \
            ip6tables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
    fi
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
}

# ==========================================
# 自动建站模块（Caddy + 静态站点 + 自动 HTTPS 证书）
# ==========================================

install_caddy_pkg() {
    command -v caddy >/dev/null 2>&1 && return 0

    local log_tmp key_tmp list_tmp
    log_tmp=$(mktemp)
    key_tmp=$(mktemp)
    list_tmp=$(mktemp)
    echo -e "状态: ${yellow}正在从 Caddy 官方源安装 Web 服务...${plain}"

    if [ "$PKG_MGR" = "apt" ]; then
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg >"$log_tmp" 2>&1; then
            tail -n 15 "$log_tmp" && rm -f "$log_tmp" "$key_tmp" "$list_tmp" && return 1
        fi
        if ! curl -1fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' -o "$key_tmp" 2>>"$log_tmp" \
            || ! curl -1fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o "$list_tmp" 2>>"$log_tmp"; then
            echo -e "${red}[错误] 下载 Caddy 官方软件源信息失败：${plain}"
            tail -n 15 "$log_tmp" && rm -f "$log_tmp" "$key_tmp" "$list_tmp" && return 1
        fi
        if ! gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg < "$key_tmp" 2>>"$log_tmp"; then
            echo -e "${red}[错误] 导入 Caddy GPG 密钥失败。${plain}"
            rm -f "$log_tmp" "$key_tmp" "$list_tmp" && return 1
        fi
        cp -f "$list_tmp" /etc/apt/sources.list.d/caddy-stable.list
        chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
        if ! apt-get update -y >>"$log_tmp" 2>&1 || ! DEBIAN_FRONTEND=noninteractive apt-get install -y caddy >>"$log_tmp" 2>&1; then
            echo -e "${red}[错误] Caddy 安装失败：${plain}"
            tail -n 20 "$log_tmp" && rm -f "$log_tmp" "$key_tmp" "$list_tmp" && return 1
        fi
    elif [ "$PKG_MGR" = "dnf" ]; then
        if ! dnf install -y dnf-plugins-core >"$log_tmp" 2>&1 \
            || ! dnf copr enable -y @caddy/caddy >>"$log_tmp" 2>&1 \
            || ! dnf install -y caddy >>"$log_tmp" 2>&1; then
            echo -e "${red}[错误] Caddy 安装失败：${plain}"
            tail -n 20 "$log_tmp" && rm -f "$log_tmp" "$key_tmp" "$list_tmp" && return 1
        fi
    else
        if ! yum install -y yum-plugin-copr >"$log_tmp" 2>&1 \
            || ! yum copr enable -y @caddy/caddy >>"$log_tmp" 2>&1 \
            || ! yum install -y caddy >>"$log_tmp" 2>&1; then
            echo -e "${red}[错误] Caddy 安装失败：${plain}"
            tail -n 20 "$log_tmp" && rm -f "$log_tmp" "$key_tmp" "$list_tmp" && return 1
        fi
    fi

    rm -f "$log_tmp" "$key_tmp" "$list_tmp"
    systemctl enable caddy >/dev/null 2>&1 || true
    return 0
}

ensure_static_site_files() {
    mkdir -p "$SITE_ROOT"
    chmod 755 /var/www "$SITE_ROOT" 2>/dev/null || true

    if [ ! -f "${SITE_ROOT}/index.html" ]; then
        cat > "${SITE_ROOT}/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Linux &amp; Systems Engineering Notes</title>
  <style>
    body { font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; max-width: 760px; margin: 60px auto; padding: 0 24px; color: #24292f; line-height: 1.75; background: #ffffff; }
    header { border-bottom: 1px solid #d0d7de; padding-bottom: 16px; margin-bottom: 28px; }
    h1 { font-size: 1.7rem; margin: 0 0 6px 0; }
    .subtitle { color: #57606a; font-size: 0.95rem; margin: 0; }
    h2 { font-size: 1.2rem; margin-top: 28px; }
    code { background: #f6f8fa; padding: 2px 6px; border-radius: 4px; font-size: 0.9em; }
    footer { margin-top: 48px; padding-top: 16px; border-top: 1px solid #eaeef2; color: #6e7781; font-size: 0.85rem; }
  </style>
</head>
<body>
  <header>
    <h1>Systems &amp; Network Documentation</h1>
    <p class="subtitle">Personal technical archive covering Linux administration, systemd, and TLS configuration.</p>
  </header>
  <main>
    <h2>Overview</h2>
    <p>This site hosts personal reference notes for server maintenance, service hardening, and automated certificate management.</p>
    <h2>Recent Topics</h2>
    <ul>
      <li>Kernel TCP BBR tuning via <code>/etc/sysctl.d/</code></li>
      <li>Automated ACME TLS certificate lifecycle management</li>
      <li>Systemd service isolation and least-privilege permissions</li>
    </ul>
  </main>
  <footer>
    <p>Service Status: Operational</p>
  </footer>
</body>
</html>
EOF
    fi

    if [ ! -f "${SITE_ROOT}/robots.txt" ]; then
        cat > "${SITE_ROOT}/robots.txt" <<'EOF'
User-agent: *
Allow: /
EOF
    fi

    chmod 644 "${SITE_ROOT}/index.html" "${SITE_ROOT}/robots.txt"
}

write_caddyfile() {
    local domain="$1"
    local mode="${2:-standard}"
    local bind_ip
    bind_ip=$(get_loopback_ip)

    mkdir -p /etc/caddy
    if [ -f "$CADDY_FILE" ] && ! grep -q "# Managed by xmgr" "$CADDY_FILE" 2>/dev/null; then
        mkdir -p /var/backups
        cp -f "$CADDY_FILE" "/var/backups/caddyfile_bak_$(date +%Y%m%d_%H%M%S)"
    fi

    if [ "$mode" = "takeover" ]; then
        cat > "$CADDY_FILE" <<EOF
# Managed by xmgr (Primary Port Takeover Mode)
{
    https_port 8443
    auto_https disable_redirects
}

${domain} {
    bind ${bind_ip}
    root * ${SITE_ROOT}
    file_server
}

http://${domain} {
    redir https://{host}{uri} permanent
}
EOF
    else
        cat > "$CADDY_FILE" <<EOF
# Managed by xmgr (Standard Mode)
${domain} {
    root * ${SITE_ROOT}
    file_server
}
EOF
    fi
}

setup_caddy_site() {
    local caller="${1:-standalone}"
    SETUP_CADDY_DOMAIN=""
    SETUP_CADDY_TARGET=""
    SETUP_CADDY_PORT=""

    if [ "$caller" = "standalone" ]; then
        install_deps
        detect_public_ips
    fi

    echo ""
    echo -e "${green}=================================================${plain}"
    echo -e "${green}       自动部署伪装静态站点与 HTTPS 证书         ${plain}"
    echo -e "${green}=================================================${plain}"
    echo -e "提示: 域名需已解析到本机公网 IP（若使用 Cloudflare 请关闭代理小黄云），并确保 80/443 端口已放行。"
    echo ""

    if is_port_in_use 80 && ! ss -tlnp 2>/dev/null | grep -E '(:80|\[::\]:80)\s' | grep -q '"caddy"'; then
        echo -e "${red}[错误] 80 端口已被其他程序占用，无法完成自动证书申请。${plain}"
        return 1
    fi

    local xray_holding_443=0
    if is_port_in_use 443; then
        if ss -tlnp 2>/dev/null | grep -E '(:443|\[::\]:443)\s' | grep -q '"xray"'; then
            xray_holding_443=1
        elif ! ss -tlnp 2>/dev/null | grep -E '(:443|\[::\]:443)\s' | grep -q '"caddy"'; then
            echo -e "${red}[错误] 443 端口已被其他程序占用，请先释放后再运行自动建站。${plain}"
            return 1
        fi
    fi

    local domain=""
    while true; do
        read -p "请输入已解析到本机的域名或子域名 (直接回车取消): " domain
        domain=$(echo "$domain" | xargs | tr '[:upper:]' '[:lower:]')
        [ -z "$domain" ] && return 1

        if ! [[ "$domain" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; then
            echo -e "${red}[错误] 域名格式无效，请重新输入（例如: site.example.com）。${plain}"
            continue
        fi

        local dom_ip4 dom_ip6 dns_ok=0
        dom_ip4=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1; exit}')
        dom_ip6=$(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1; exit}')

        if [ -n "$VPS_IPV4" ] && [ "$dom_ip4" = "$VPS_IPV4" ]; then
            dns_ok=1
        elif [ -n "$VPS_IPV6" ] && [ "$dom_ip6" = "$VPS_IPV6" ]; then
            dns_ok=1
        fi

        if [ $dns_ok -eq 1 ]; then
            echo -e "${green}[通过] DNS 解析校验成功 (${domain} -> ${dom_ip4:-$dom_ip6})。${plain}"
            break
        else
            echo -e "${yellow}[警告] 域名解析 IP (${dom_ip4:-无}/${dom_ip6:-无}) 与本机公网 IP (${VPS_IPV4:-无}/${VPS_IPV6:-无}) 不一致。${plain}"
            read -p "是否仍尝试继续申请证书？(y/N): " force_dns
            [[ "$force_dns" =~ ^[Yy]$ ]] && break
        fi
    done

    install_caddy_pkg || return 1
    ensure_static_site_files

    apply_port_firewall 80
    apply_port_firewall 443

    local lo_ip init_mode init_port
    lo_ip=$(get_loopback_ip)
    if [ $xray_holding_443 -eq 1 ]; then
        init_mode="takeover"
        init_port="8443"
    else
        init_mode="standard"
        init_port="443"
    fi

    write_caddyfile "$domain" "$init_mode"
    if ! caddy validate --config "$CADDY_FILE" >/dev/null 2>&1; then
        echo -e "${red}[错误] Caddy 配置校验失败。${plain}"
        return 1
    fi

    echo -e "状态: ${yellow}正在启动站点并自动申请正式 HTTPS 证书（最多等待 45 秒）...${plain}"
    systemctl restart caddy
    if ! systemctl is-active --quiet caddy; then
        echo -e "${red}[错误] Caddy 启动失败，最近日志如下：${plain}"
        journalctl -u caddy -n 15 --no-pager
        return 1
    fi

    local cert_ok=0
    local resolve_ip="$lo_ip"
    [[ "$resolve_ip" == *:* ]] && resolve_ip="[${resolve_ip}]"
    local i
    for (( i=1; i<=22; i++ )); do
        if curl --resolve "${domain}:${init_port}:${resolve_ip}" -fsSI --max-time 3 "https://${domain}:${init_port}" >/dev/null 2>&1; then
            cert_ok=1
            break
        fi
        sleep 2
        printf "."
    done
    echo ""

    if [ $cert_ok -eq 0 ]; then
        echo -e "${red}[失败] 证书签发超时，请检查 80/443 防火墙及域名 DNS 解析。${plain}"
        return 1
    fi

    echo -e "${green}[成功] 站点 https://${domain} 已上线，TLS 证书签发通过！${plain}"
    SETUP_CADDY_DOMAIN="$domain"

    if [ "$caller" = "install" ]; then
        if [ $xray_holding_443 -eq 0 ]; then
            write_caddyfile "$domain" "takeover"
            if caddy validate --config "$CADDY_FILE" >/dev/null 2>&1 && systemctl reload caddy >/dev/null 2>&1; then
                sleep 1
                if ! is_port_in_use 443 && is_port_in_use 8443; then
                    echo -e "自动配置: ${cyan}已将 Web 站点切换至本地 8443，443 主端口由 Xray 独占接管（80 端口保留用于证书自动续签）${plain}"
                    SETUP_CADDY_PORT=443
                    SETUP_CADDY_TARGET=$(format_host_port "$lo_ip" "8443")
                    return 0
                fi
            fi
            write_caddyfile "$domain" "standard"
            systemctl reload caddy >/dev/null 2>&1 || true
            SETUP_CADDY_PORT=""
            SETUP_CADDY_TARGET=$(format_host_port "$lo_ip" "443")
        else
            SETUP_CADDY_PORT=443
            SETUP_CADDY_TARGET=$(format_host_port "$lo_ip" "8443")
        fi
    else
        echo -e "${green}[完成] 站点部署成功，可随时运行 ${yellow}xmgr install${green} 对接该站点。${plain}"
    fi
    return 0
}

# ==========================================
# 本地 Web 站点探测与端口迁移
# ==========================================

detect_local_websites() {
    VALID_LOCAL_DOMAINS=()
    LOCAL_WEB_PORT="443"
    LOCAL_PROBE_IP=$(get_loopback_ip)
    ALREADY_MIGRATED=0

    local port443_proc
    port443_proc=$(ss -tlnp 2>/dev/null | awk '/(:443|\[::\]:443)\s/ {print $0}')

    if { [ -z "$port443_proc" ] || echo "$port443_proc" | grep -q '"xray"'; } && is_port_in_use 8443; then
        LOCAL_WEB_PORT="8443"
        ALREADY_MIGRATED=1
        if ss -tln 2>/dev/null | grep -qE '(127\.0\.0\.1:8443|0\.0\.0\.0:8443)\s'; then
            LOCAL_PROBE_IP="127.0.0.1"
        else
            LOCAL_PROBE_IP="::1"
        fi
    elif [ -n "$port443_proc" ] && ! echo "$port443_proc" | grep -q '"xray"'; then
        LOCAL_WEB_PORT="443"
        ALREADY_MIGRATED=0
        if ss -tln 2>/dev/null | grep -qE '(127\.0\.0\.1:443|0\.0\.0\.0:443|\*:443)\s'; then
            LOCAL_PROBE_IP="127.0.0.1"
        else
            LOCAL_PROBE_IP="::1"
        fi
    else
        return 1
    fi

    local candidates=()

    if command -v nginx >/dev/null 2>&1; then
        while IFS= read -r d; do
            candidates+=("$d")
        done < <(nginx -T 2>/dev/null | awk '
        {
            sub(/#.*/, "")
            if ($0 ~ /^[[:space:]]*server_name([[:space:]]|$)/) in_sn=1
            if (in_sn) {
                for (i=1; i<=NF; i++) {
                    if ($i == "server_name") continue
                    if ($i ~ /;/) {
                        gsub(/;/, "", $i)
                        if ($i != "") print $i
                        in_sn=0
                        break
                    }
                    if ($i != "") print $i
                }
            }
        }')
    fi

    if command -v apache2ctl >/dev/null 2>&1 || command -v httpd >/dev/null 2>&1; then
        local ap_cmd
        ap_cmd=$(command -v apache2ctl || command -v httpd)
        while IFS= read -r d; do
            candidates+=("$d")
        done < <("$ap_cmd" -S 2>/dev/null | awk '/namevhost|alias/ {for(i=1;i<=NF;i++) if($i ~ /\./) print $i}' | tr -d '()')
    fi

    if [ -f "$CADDY_FILE" ]; then
        local caddy_domains=""
        if command -v caddy >/dev/null 2>&1; then
            caddy_domains=$(caddy adapt --config "$CADDY_FILE" 2>/dev/null | jq -r '.. | objects | .host? | arrays | .[]' 2>/dev/null || true)
        fi
        if [ -n "$caddy_domains" ]; then
            while IFS= read -r d; do
                candidates+=("$d")
            done <<< "$caddy_domains"
        else
            while IFS= read -r d; do
                candidates+=("$d")
            done < <(grep -oE '^[[:space:]]*(https?://)?([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}' "$CADDY_FILE" | sed -E 's#^https?://##' | xargs -n1 2>/dev/null || true)
        fi
    fi

    local unique_domains=()
    mapfile -t unique_domains < <(printf "%s\n" "${candidates[@]}" \
        | grep -E '^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$' \
        | grep -viE '^(localhost|example\.com)$' \
        | sort -u)

    [ ${#unique_domains[@]} -eq 0 ] && return 1

    echo ""
    echo -e "${cyan}检测到本机已部署 Web 站点，正在筛选可用伪装域名...${plain}"
    echo ""

    local idx=1
    local dom dom_ip dns_tag
    for dom in "${unique_domains[@]}"; do
        if ! check_reality_sni "$dom" "$LOCAL_PROBE_IP" "$LOCAL_WEB_PORT"; then
            echo -e "  [-] ${dom} (${red}${LAST_CHECK_MSG}${plain})"
            continue
        fi

        dom_ip=$(getent ahostsv4 "$dom" 2>/dev/null | awk '{print $1; exit}')
        [ -z "$dom_ip" ] && dom_ip=$(getent ahostsv6 "$dom" 2>/dev/null | awk '{print $1; exit}')

        if [ -n "$dom_ip" ] && { [ "$dom_ip" = "$VPS_IPV4" ] || [ "$dom_ip" = "$VPS_IPV6" ]; }; then
            dns_tag="${green}DNS直连本机 ✓${plain}"
        elif [ -n "$dom_ip" ]; then
            dns_tag="${yellow}DNS指向 ${dom_ip} (可能套用CDN代理，不推荐) ⚠${plain}"
        else
            dns_tag="${yellow}DNS解析失败 ⚠${plain}"
        fi

        VALID_LOCAL_DOMAINS+=("$dom")
        echo -e "  [${green}${idx}${plain}] ${dom} | ${LAST_CHECK_MSG} | ${dns_tag}"
        ((idx++))
    done

    [ ${#VALID_LOCAL_DOMAINS[@]} -gt 0 ]
}

migrate_local_web_to_8443() {
    local selected_domain="$1"
    local port443_proc
    port443_proc=$(ss -tlnp 2>/dev/null | awk '/(:443|\[::\]:443)\s/ {print $0}')

    if echo "$port443_proc" | grep -q '"caddy"'; then
        if [ -f "$CADDY_FILE" ] && grep -q "# Managed by xmgr" "$CADDY_FILE" 2>/dev/null; then
            local caddy_bak="/var/backups/caddyfile_bak_$(date +%Y%m%d_%H%M%S)"
            mkdir -p /var/backups
            cp -f "$CADDY_FILE" "$caddy_bak"
            write_caddyfile "$selected_domain" "takeover"
            if caddy validate --config "$CADDY_FILE" >/dev/null 2>&1 && systemctl reload caddy >/dev/null 2>&1; then
                sleep 1
                if ! is_port_in_use 443; then
                    echo -e "${green}[成功] Caddy 已自动迁移至本地 8443，443 端口已释放。${plain}"
                    return 0
                fi
            fi
            cp -f "$caddy_bak" "$CADDY_FILE"
            systemctl reload caddy >/dev/null 2>&1 || true
        fi
        return 1
    fi

    if [ -d /opt/1panel ] || [ -d /www/server/panel ]; then
        echo -e "${yellow}[提示] 检测到 1Panel / 宝塔面板环境，暂不自动修改面板配置，将采用并行兼容模式（不影响原有网站）。${plain}"
        return 1
    fi

    if ! command -v nginx >/dev/null 2>&1; then
        return 1
    fi

    local bak_dir="/var/backups/xray_nginx_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$bak_dir"
    cp -a /etc/nginx/. "$bak_dir"/ 2>/dev/null || true

    local files_changed=()
    local f
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        files_changed+=("$f")
        sed -i -E \
            -e 's/(listen[[:space:]]+)(\[::\]:)443([[:space:];])/\1[::1]:8443\3/g' \
            -e 's/(listen[[:space:]]+)(\*:|0\.0\.0\.0:)?443([[:space:];])/\1127.0.0.1:8443\3/g' \
            "$f"
    done < <(grep -rlE 'listen[[:space:]]+(\[::\]:|\*:|0\.0\.0\.0:)?443([[:space:];])' /etc/nginx 2>/dev/null)

    if [ ${#files_changed[@]} -eq 0 ]; then
        return 1
    fi

    if nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1; then
        sleep 1
        if ! is_port_in_use 443; then
            echo -e "${green}[成功] Nginx 已自动迁移至本地 8443（备份: ${bak_dir}），443 端口已交由 Xray 接管。${plain}"
            return 0
        fi
    fi

    cp -a "$bak_dir"/. /etc/nginx/
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    return 1
}

# ==========================================
# 核心功能函数
# ==========================================

# 1. 极简最优自动部署流程
install_xray() {
    clear
    echo -e "${green}=================================================${plain}"
    echo -e "${green}        Xray (VLESS + Reality) 一键加固部署      ${plain}"
    echo -e "${green}=================================================${plain}"
    echo ""

    install_deps
    enable_bbr
    install_or_update_xray_core "install"
    detect_public_ips

    local OLD_PORT=""
    local DEF_SNI=""
    local DEF_NAME="xmgr-node"
    if [ -f "$CACHE_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CACHE_FILE"
        OLD_PORT="${XRAY_PORT:-}"
        DEF_SNI="${XRAY_SNI:-}"
        DEF_NAME="${XRAY_NAME:-$DEF_NAME}"
    fi

    # ---- 步骤 1: 全自动配置最优双栈监听与默认连接地址 ----
    local CONNECT_HOST=""
    local LISTEN_ADDR="0.0.0.0"

    echo ""
    if [ -n "$VPS_IPV4" ] && [ -n "$VPS_IPV6" ]; then
        CONNECT_HOST="$VPS_IPV4"
        if [ "$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || echo 1)" = "0" ]; then
            LISTEN_ADDR="::"
            echo -e "网络环境: ${green}双栈网络${plain} | 已自动启用服务端双栈自适应监听"
        else
            LISTEN_ADDR="0.0.0.0"
            echo -e "网络环境: ${green}双栈网络${plain} | 已自动选用 IPv4 接入"
        fi
    elif [ -n "$VPS_IPV4" ]; then
        CONNECT_HOST="$VPS_IPV4"
        LISTEN_ADDR="0.0.0.0"
        echo -e "网络环境: ${green}IPv4 网络${plain} (${VPS_IPV4})"
    elif [ -n "$VPS_IPV6" ]; then
        CONNECT_HOST="$VPS_IPV6"
        LISTEN_ADDR="::"
        echo -e "网络环境: ${green}纯 IPv6 网络${plain} (${VPS_IPV6})"
    else
        read -p "自动获取公网 IP 失败，请输入服务器 IP 或域名: " CONNECT_HOST
        CONNECT_HOST=$(echo "$CONNECT_HOST" | xargs)
        [ -z "$CONNECT_HOST" ] && echo -e "${red}[错误] 连接地址不能为空。${plain}" && exit 1
        [[ "$CONNECT_HOST" == *:* ]] && LISTEN_ADDR="::"
    fi

    # ---- 步骤 2: 自动探测本地站点 / 引导建站 / 外部 SNI ----
    local SNI=""
    local TARGET_ADDR=""
    local PORT=""
    local USE_LOCAL_SITE=0

    if detect_local_websites; then
        echo -e "  [${green}0${plain}] 不使用本地站点，改用外部伪装域名"
        echo ""
        local sel
        while true; do
            read -p "请选择要使用的本地伪装域名序号 [直接回车选 1]: " sel
            sel=${sel:-1}
            if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 0 ] && [ "$sel" -le ${#VALID_LOCAL_DOMAINS[@]} ]; then
                break
            fi
            echo -e "${red}[错误] 请输入 0-${#VALID_LOCAL_DOMAINS[@]} 之间的序号。${plain}"
        done

        if [ "$sel" -gt 0 ]; then
            USE_LOCAL_SITE=1
            SNI="${VALID_LOCAL_DOMAINS[$((sel - 1))]}"

            if [ "$ALREADY_MIGRATED" -eq 1 ]; then
                PORT=443
                TARGET_ADDR=$(format_host_port "$LOCAL_PROBE_IP" "8443")
            else
                local port443_proc
                port443_proc=$(ss -tlnp 2>/dev/null | awk '/(:443|\[::\]:443)\s/ {print $0}')
                if echo "$port443_proc" | grep -q '"caddy"' && grep -q "# Managed by xmgr" "$CADDY_FILE" 2>/dev/null; then
                    if migrate_local_web_to_8443 "$SNI"; then
                        PORT=443
                        TARGET_ADDR=$(format_host_port "$LOCAL_PROBE_IP" "8443")
                    else
                        TARGET_ADDR=$(format_host_port "$LOCAL_PROBE_IP" "443")
                    fi
                else
                    echo ""
                    echo -e "是否允许将现有 Web 服务自动调整至本地 8443，让 Xray 独占最优 443 端口？"
                    echo -e "（选 N 则完全不改动现有网站配置，Xray 自动使用其他可用端口）"
                    read -p "是否接管 443 端口？(y/N): " take_443
                    if [[ "$take_443" =~ ^[Yy]$ ]] && migrate_local_web_to_8443 "$SNI"; then
                        PORT=443
                        if ss -tln 2>/dev/null | grep -q "127.0.0.1:8443"; then
                            TARGET_ADDR="127.0.0.1:8443"
                        else
                            TARGET_ADDR="[::1]:8443"
                        fi
                    else
                        TARGET_ADDR=$(format_host_port "$LOCAL_PROBE_IP" "443")
                    fi
                fi
            fi
        fi
    else
        echo ""
        echo -e "${cyan}当前服务器未检测到网站，请选择伪装方式：${plain}"
        echo -e "  [${green}1${plain}] 我有域名，自动部署伪装网站与 HTTPS 证书（最稳抗封锁，推荐）"
        echo -e "  [${green}2${plain}] 暂时没有域名，使用外部合规网站作为伪装目标"
        local site_plan
        read -p "请选择 [默认: 1]: " site_plan
        site_plan=${site_plan:-1}

        if [ "$site_plan" = "1" ]; then
            if setup_caddy_site "install"; then
                USE_LOCAL_SITE=1
                SNI="$SETUP_CADDY_DOMAIN"
                TARGET_ADDR="$SETUP_CADDY_TARGET"
                PORT="$SETUP_CADDY_PORT"
            else
                echo -e "${yellow}[提示] 自动建站未完成，将转为使用外部伪装域名。${plain}"
            fi
        fi
    fi

    if [ -z "$SNI" ]; then
        echo ""
        echo -e "${yellow}[提示] 请输入一个支持 TLS 1.3 的常见合规网站域名（如同地区云厂商/门户/工具站，尽量避开大众默认域名）。${plain}"
        while true; do
            local prompt_sni="请输入外部伪装域名 (SNI)"
            [ -n "$DEF_SNI" ] && prompt_sni+=" [直接回车沿用: ${DEF_SNI}]"
            read -p "${prompt_sni}: " SNI
            SNI=${SNI:-$DEF_SNI}
            SNI=$(echo "$SNI" | xargs)
            if [ -z "$SNI" ]; then
                echo -e "${red}[错误] 伪装域名不能为空。${plain}"
                continue
            fi
            echo -e "正在检测 ${SNI} 是否符合要求..."
            if check_reality_sni "$SNI"; then
                echo -e "${green}[通过] ${SNI} -> ${LAST_CHECK_MSG}${plain}"
                TARGET_ADDR="${SNI}:443"
                break
            else
                echo -e "${red}[不推荐] ${SNI}: ${LAST_CHECK_MSG}${plain}"
                read -p "仍要强制使用该域名吗？(y/N): " force_sni
                if [[ "$force_sni" =~ ^[Yy]$ ]]; then
                    TARGET_ADDR="${SNI}:443"
                    break
                fi
            fi
        done
    fi

    # 若本地直连域名同时具备指向本机的双栈 A + AAAA 记录，单链接直接用域名实现客户端自动双栈匹配
    if [ "$USE_LOCAL_SITE" -eq 1 ] && [ -n "$VPS_IPV4" ] && [ -n "$VPS_IPV6" ]; then
        local d4 d6
        d4=$(getent ahostsv4 "$SNI" 2>/dev/null | awk '{print $1; exit}')
        d6=$(getent ahostsv6 "$SNI" 2>/dev/null | awk '{print $1; exit}')
        if [ "$d4" = "$VPS_IPV4" ] && [ "$d6" = "$VPS_IPV6" ]; then
            CONNECT_HOST="$SNI"
            echo -e "链接策略: ${cyan}检测到域名已直连双栈解析，节点链接将使用域名以实现客户端 IPv4/IPv6 自动匹配${plain}"
        fi
    fi

    # ---- 步骤 3: 自动选择最优可用端口（443 空闲 > 复用原高位端口 > 随机高位端口） ----
    if [ -z "$PORT" ]; then
        if ! is_port_in_use 443; then
            PORT=443
        elif [ -n "$OLD_PORT" ] && [ "$OLD_PORT" != "80" ] && { ! is_port_in_use "$OLD_PORT" || ss -tlnp 2>/dev/null | grep -E "(:${OLD_PORT}|\[::\]:${OLD_PORT})\s" | grep -q '"xray"'; }; then
            PORT="$OLD_PORT"
        else
            PORT=$(random_high_port)
        fi
        echo -e "监听端口: ${green}${PORT}${plain} (已自动选定最优可用端口)"
    fi

    # ---- 步骤 4: 节点备注名称 ----
    echo ""
    read -p "$(echo -e "请输入节点备注名称 [直接回车默认: ${green}${DEF_NAME}${plain}]: ")" LINK_NAME
    LINK_NAME=${LINK_NAME:-$DEF_NAME}
    LINK_NAME=$(echo "$LINK_NAME" | xargs)
    [ -z "$LINK_NAME" ] && LINK_NAME="xmgr-node"

    # ---- 步骤 5: 自动生成最优兼容配置并部署 ----
    echo ""
    echo -e "状态: ${yellow}正在生成高强度密钥与最优安全配置...${plain}"

    local UUID SHORT_ID KEYS PRIVATE_KEY PUBLIC_KEY
    UUID=$(xray uuid)
    SHORT_ID=$(openssl rand -hex 8)
    KEYS=$(xray x25519)
    PRIVATE_KEY=$(echo "$KEYS" | awk -F': *' '/^Private/ {print $2; exit}')
    PUBLIC_KEY=$(echo "$KEYS" | awk -F': *' '/^(Public|Password)/ {print $2; exit}')

    if [ -z "$UUID" ] || [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
        echo -e "${red}[错误] 核心密钥生成失败，部署中止。${plain}"
        exit 1
    fi

    local NETWORK_TYPE="raw"
    local FLOW_VAL="xtls-rprx-vision"
    local FP="chrome"

    mkdir -p "$CONFIG_DIR"

    jq -n \
        --arg listen "$LISTEN_ADDR" \
        --argjson port "$PORT" \
        --arg uuid "$UUID" \
        --arg flow "$FLOW_VAL" \
        --arg network "$NETWORK_TYPE" \
        --arg target "$TARGET_ADDR" \
        --arg sni "$SNI" \
        --arg priv "$PRIVATE_KEY" \
        --arg sid "$SHORT_ID" \
        '{
          log: { loglevel: "warning" },
          inbounds: [
            {
              listen: $listen,
              port: $port,
              protocol: "vless",
              settings: {
                clients: [
                  { id: $uuid, flow: $flow }
                ],
                decryption: "none"
              },
              streamSettings: {
                network: $network,
                security: "reality",
                realitySettings: {
                  show: false,
                  target: $target,
                  xver: 0,
                  serverNames: [$sni],
                  privateKey: $priv,
                  maxTimeDiff: 60000,
                  shortIds: [$sid]
                }
              },
              sniffing: {
                enabled: true,
                destOverride: ["http", "tls", "quic"],
                routeOnly: true
              }
            }
          ],
          outbounds: [
            { protocol: "freedom", tag: "direct" },
            { protocol: "blackhole", tag: "blocked" }
          ],
          routing: {
            domainStrategy: "AsIs",
            rules: [
              { type: "field", ip: ["geoip:private"], outboundTag: "blocked" },
              { type: "field", protocol: ["bittorrent"], outboundTag: "blocked" }
            ]
          }
        }' > "$CONFIG_FILE"

    local xray_user
    xray_user=$(systemctl show -p User --value xray 2>/dev/null || echo "root")
    [ -z "$xray_user" ] && xray_user="root"
    chown "$xray_user" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    if ! xray run -test -c "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${red}[错误] 配置文件校验未通过：${plain}"
        xray run -test -c "$CONFIG_FILE"
        exit 1
    fi

    apply_port_firewall "$PORT" "$OLD_PORT"

    systemctl enable xray >/dev/null 2>&1 || true
    if ! systemctl restart xray || ! systemctl is-active --quiet xray; then
        echo -e "${red}[错误] Xray 服务启动失败，最近日志如下：${plain}"
        journalctl -u xray -n 20 --no-pager
        exit 1
    fi

    {
        printf 'XRAY_PORT=%q\n' "$PORT"
        printf 'XRAY_SNI=%q\n' "$SNI"
        printf 'XRAY_NAME=%q\n' "$LINK_NAME"
        printf 'XRAY_UUID=%q\n' "$UUID"
        printf 'XRAY_PBK=%q\n' "$PUBLIC_KEY"
        printf 'XRAY_SID=%q\n' "$SHORT_ID"
        printf 'XRAY_IP=%q\n' "$CONNECT_HOST"
        printf 'XRAY_FLOW=%q\n' "$FLOW_VAL"
        printf 'XRAY_FP=%q\n' "$FP"
    } > "$CACHE_FILE"
    chown root:root "$CACHE_FILE"
    chmod 600 "$CACHE_FILE"

    echo "-------------------------------------------------"
    echo -e "${green}部署成功！可直接复制下方链接导入任意常用客户端：${plain}"
    echo ""
    show_link
}

# 2. 查看节点信息与唯一订阅链接
show_link() {
    if [ ! -f "$CACHE_FILE" ]; then
        echo -e "${red}[错误] 未找到配置信息，请先运行 xmgr install 进行部署。${plain}"
        exit 1
    fi

    # shellcheck disable=SC1090
    source "$CACHE_FILE"

    local uri_host="$XRAY_IP"
    [[ "$uri_host" == *:* ]] && uri_host="[${uri_host}]"

    local fp_param="${XRAY_FP:-chrome}"
    local flow_param="${XRAY_FLOW:-xtls-rprx-vision}"

    local link="vless://${XRAY_UUID}@${uri_host}:${XRAY_PORT}?encryption=none&flow=$(urlencode "$flow_param")&security=reality&sni=$(urlencode "$XRAY_SNI")&fp=$(urlencode "$fp_param")&pbk=$(urlencode "$XRAY_PBK")&sid=$(urlencode "$XRAY_SID")&type=tcp&headerType=none#$(urlencode "$XRAY_NAME")"

    echo -e "${green}=================================================${plain}"
    echo -e "${green}                 Xray 节点配置信息               ${plain}"
    echo -e "${green}=================================================${plain}"
    echo -e " 节点备注  : ${green}${XRAY_NAME}${plain}"
    echo -e " 连接地址  : ${green}${XRAY_IP}${plain}"
    echo -e " 连接端口  : ${green}${XRAY_PORT}${plain}"
    echo -e " 伪装域名  : ${green}${XRAY_SNI}${plain}"
    echo -e " 用户 UUID : ${green}${XRAY_UUID}${plain}"
    echo -e " 公钥 PBK  : ${green}${XRAY_PBK}${plain}"
    echo -e " 短身份码  : ${green}${XRAY_SID}${plain}"
    echo -e "${green}=================================================${plain}"
    echo -e " 节点链接 (完整复制后导入客户端):"
    echo -e "${yellow}${link}${plain}"
    echo -e "${green}=================================================${plain}"
    echo ""
}

# 3. 单独更新 Xray-core 内核（保留全部密钥与节点配置）
update_xray() {
    echo ""
    local old_ver new_ver
    old_ver=$(xray version 2>/dev/null | head -n 1 || echo "未安装")
    echo -e "当前版本: ${yellow}${old_ver}${plain}"
    install_or_update_xray_core "install"

    if [ -f "$CONFIG_FILE" ]; then
        if xray run -test -c "$CONFIG_FILE"; then
            if systemctl restart xray && systemctl is-active --quiet xray; then
                new_ver=$(xray version 2>/dev/null | head -n 1 || echo "未知")
                echo -e "${green}[信息] Xray 内核更新完毕，当前版本：${new_ver}${plain}"
            else
                echo -e "${red}[错误] 内核更新后服务重启失败，最近日志如下：${plain}"
                journalctl -u xray -n 20 --no-pager
                exit 1
            fi
        else
            echo -e "${red}[警告] 新版内核配置兼容性校验失败，请检查 ${CONFIG_FILE}。${plain}"
            exit 1
        fi
    fi
}

# 4. 查看内核版本、运行状态与日志
show_status() {
    echo ""
    echo -e "${green}================= Xray 内核版本 =================${plain}"
    xray version 2>/dev/null | head -n 2 || echo "未检测到 Xray 内核"
    echo -e "${green}================= Xray 服务运行状态 =================${plain}"
    systemctl status xray --no-pager | head -n 12
    echo -e "${green}================= 最近 15 条运行日志 ================${plain}"
    journalctl -u xray -n 15 --no-pager
    echo -e "${green}=====================================================${plain}"
    echo ""
}

# 5. 彻底卸载 Xray 及清理全部配置
uninstall_xray() {
    echo ""
    read -p "$(echo -e "${yellow}确定要彻底卸载 Xray、清理防火墙规则与全部配置吗？(y/N): ${plain}")" confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if [ -f "$CACHE_FILE" ]; then
            # shellcheck disable=SC1090
            source "$CACHE_FILE"
            [ -n "${XRAY_PORT:-}" ] && remove_port_firewall "$XRAY_PORT"
        fi
        systemctl stop xray >/dev/null 2>&1 || true
        systemctl disable xray >/dev/null 2>&1 || true
        bash -c "$(curl -fsSL "$XRAY_INSTALL_URL")" @ remove >/dev/null 2>&1 || true
        rm -rf "$CONFIG_DIR"
        rm -f "$SYSCTL_FILE" "$SCRIPT_PATH"
        sysctl --system >/dev/null 2>&1 || true

        if command -v caddy >/dev/null 2>&1 && grep -q "# Managed by xmgr" "$CADDY_FILE" 2>/dev/null; then
            read -p "检测到由 xmgr 托管的 Caddy 站点，是否同时停止并清理 Caddy 配置与站点目录？(y/N): " del_caddy
            if [[ "$del_caddy" =~ ^[Yy]$ ]]; then
                systemctl stop caddy >/dev/null 2>&1 || true
                systemctl disable caddy >/dev/null 2>&1 || true
                rm -f "$CADDY_FILE"
                rm -rf "$SITE_ROOT"
            fi
        fi

        echo -e "${green}[信息] Xray 及相关配置已完全卸载。${plain}"
        exit 0
    else
        echo -e "${green}[信息] 已取消卸载操作。${plain}"
    fi
}

# ==========================================
# 命令解析与帮助信息
# ==========================================

show_help() {
    echo ""
    echo -e " Xray (VLESS + Reality) 命令行管理脚本"
    echo -e " 使用方法: ${green}xmgr${plain} [命令]"
    echo ""
    echo -e "   ${green}install${plain}   - 一键部署或重配节点 (自动检测站点/自动建站/安全加固)"
    echo -e "   ${green}site${plain}      - 单独部署 Caddy 本地伪装静态站点并自动申请 HTTPS 证书"
    echo -e "   ${green}update${plain}    - 仅升级 Xray-core 内核 (保留现有密钥与链接)"
    echo -e "   ${green}link${plain}      - 查看当前节点参数与订阅链接"
    echo -e "   ${green}restart${plain}   - 重启 Xray 核心服务"
    echo -e "   ${green}status${plain}    - 查看内核版本、服务运行状态与系统日志"
    echo -e "   ${green}uninstall${plain} - 彻底卸载 Xray 并清理防火墙与残留配置"
    echo -e "   ${green}help${plain}      - 显示当前帮助信息"
    echo ""
}

case "${1:-}" in
    install)   install_xray ;;
    site)      setup_caddy_site "standalone" ;;
    update)    update_xray ;;
    link)      show_link ;;
    restart)
        systemctl restart xray && echo -e "${green}[信息] Xray 服务已重启完毕。${plain}"
        ;;
    status)    show_status ;;
    uninstall) uninstall_xray ;;
    *)         show_help ;;
esac
