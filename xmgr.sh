#!/bin/bash

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 核心缓存路径 (硬编码，防变量丢失)
CACHE_FILE="/usr/local/etc/xray/.xray_info"
SCRIPT_PATH="/usr/local/bin/xmgr"

# 检查是否为 Root 用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# 安装系统级命令 (变更为极简的 xr 命令)
if [ "$0" != "$SCRIPT_PATH" ] && [ "$1" != "menu" ]; then
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}✅ 控制台已升级并注册为系统级命令！${PLAIN}"
    echo -e "以后在任意目录输入 ${CYAN}xmgr${PLAIN} 即可瞬间唤出本看板。"
    sleep 2
    exec "$SCRIPT_PATH" "menu"
fi

# ================= 核心功能函数 =================

# 1. 安装与重新配置
install_or_reconfig() {
    clear
    echo -e "${GREEN}============================================${PLAIN}"
    echo -e "${GREEN}       Xray (VLESS+Reality) 部署与配置      ${PLAIN}"
    echo -e "${GREEN}============================================${PLAIN}"

    echo -e "${YELLOW}[1/8] 检查并安装基础依赖...${PLAIN}"
    apt-get update -y > /dev/null 2>&1
    apt-get install -y curl wget tar unzip openssl iproute2 iptables ufw > /dev/null 2>&1

    echo -e "${YELLOW}[2/8] 检查并开启 BBR...${PLAIN}"
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi

    echo -e "${YELLOW}[3/8] 配置节点参数...${PLAIN}"
    
    # 读取旧配置作为默认项
    DEF_PORT=34567
    DEF_SNI="www.bing.com"
    DEF_NAME="zdaben"
    if [ -f "$CACHE_FILE" ]; then
        source "$CACHE_FILE"
        DEF_PORT=${XRAY_PORT:-$DEF_PORT}
        DEF_SNI=${XRAY_SNI:-$DEF_SNI}
        DEF_NAME=${XRAY_NAME:-$DEF_NAME}
        echo -e "${CYAN}💡 检测到已有配置，已自动填入默认项，直接回车即可保持不变。${PLAIN}"
    fi

    # 端口配置
    while true; do
        read -p "请输入端口号 [默认: $DEF_PORT]: " PORT
        PORT=${PORT:-$DEF_PORT}
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            echo -e "${RED}警告：请输入 1-65535 之间的有效数字！${PLAIN}"
            continue
        fi
        if [[ "$PORT" == "80" || "$PORT" == "443" ]]; then
            echo -e "${RED}警告：端口 80 和 443 需留给 Web 服务，请更换！${PLAIN}"
            continue
        fi
        # 如果端口改变了，才去检查占用
        if [ "$PORT" != "$DEF_PORT" ] && ss -lntp | grep -q ":$PORT "; then
            echo -e "${RED}错误：端口 $PORT 已被占用，请更换！${PLAIN}"
            continue
        fi
        break
    done

    # SNI 域名配置
    while true; do
        read -p "请输入伪装域名 (SNI) [默认: $DEF_SNI]: " SNI
        SNI=${SNI:-$DEF_SNI}
        SNI=$(echo "${SNI}" | xargs)
        if [ "$SNI" != "$DEF_SNI" ]; then
            echo -e "正在测试目标域名的 443 端口联通性..."
            if ! timeout 5 bash -c "</dev/tcp/${SNI}/443" 2>/dev/null; then
                echo -e "${RED}警告：域名 ${SNI} 无法连接 443 端口，请更换！${PLAIN}"
                continue
            fi
        fi
        break
    done

    # 备注名称配置
    read -p "请输入链接备注名称 [默认: $DEF_NAME]: " LINK_NAME
    LINK_NAME=${LINK_NAME:-$DEF_NAME}
    LINK_NAME=$(echo "${LINK_NAME}" | xargs)

    echo -e "${YELLOW}[4/8] 部署 Xray 核心引擎...${PLAIN}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install > /dev/null 2>&1

    echo -e "${YELLOW}[5/8] 生成安全凭证与配置文件...${PLAIN}"
    
    UUID=$(xray uuid)
    SHORT_ID=$(openssl rand -hex 4)
    KEYS=$(xray x25519)
    PRIVATE_KEY=$(echo "$KEYS" | grep -i "Private" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$KEYS" | grep -i -E "Public|Password" | awk '{print $NF}')

    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        echo -e "${RED}严重错误：密钥生成失败！${PLAIN}" && exit 1
    fi

    # 写入配置文件
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "serverNames": [ "$SNI" ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [ "$SHORT_ID" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ]
}
EOF
    chmod 644 /usr/local/etc/xray/config.json

    echo -e "${YELLOW}[6/8] 自动配置防火墙放行...${PLAIN}"
    command -v ufw >/dev/null 2>&1 && ufw allow $PORT/tcp >/dev/null 2>&1
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport $PORT -j ACCEPT >/dev/null 2>&1
        command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
    fi

    echo -e "${YELLOW}[7/8] 重启并应用服务配置...${PLAIN}"
    systemctl enable xray > /dev/null 2>&1
    if ! systemctl restart xray; then
        echo -e "${RED}致命错误：Xray 启动失败！日志如下：${PLAIN}"
        journalctl -u xray -n 15 --no-pager
        exit 1
    fi

    echo -e "${YELLOW}[8/8] 写入缓存并提取节点信息...${PLAIN}"
    IP=$(curl -s4m8 ifconfig.me || curl -s4m8 ip.sb || curl -s4m8 api.ipify.org)

    # 硬编码直接写入缓存文件，防止任何变量逃逸
    cat > /usr/local/etc/xray/.xray_info <<EOF
XRAY_PORT=$PORT
XRAY_SNI=$SNI
XRAY_NAME=$LINK_NAME
XRAY_UUID=$UUID
XRAY_PBK=$PUBLIC_KEY
XRAY_SID=$SHORT_ID
XRAY_IP=$IP
EOF

    echo -e "${GREEN}✅ 配置全部写入成功！${PLAIN}"
    sleep 1
    view_link
}

# 2. 查看节点连接
view_link() {
    clear
    if [ ! -f "/usr/local/etc/xray/.xray_info" ]; then
        echo -e "${RED}未找到节点信息缓存，请先执行安装(选项1)！${PLAIN}"
        read -p "按回车键返回菜单..."
        return
    fi
    
    # 读取硬盘缓存
    source "/usr/local/etc/xray/.xray_info"
    LINK="vless://${XRAY_UUID}@${XRAY_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${XRAY_SNI}&fp=chrome&pbk=${XRAY_PBK}&sid=${XRAY_SID}&type=tcp&headerType=none#${XRAY_NAME}"

    echo -e "${GREEN}============================================${PLAIN}"
    echo -e "${CYAN}             Xray 节点详情看板              ${PLAIN}"
    echo -e "${GREEN}============================================${PLAIN}"
    echo -e "IP 地址   : ${YELLOW}${XRAY_IP}${PLAIN}"
    echo -e "连接端口  : ${YELLOW}${XRAY_PORT}${PLAIN}"
    echo -e "伪装域名  : ${YELLOW}${XRAY_SNI}${PLAIN}"
    echo -e "用户 UUID : ${YELLOW}${XRAY_UUID}${PLAIN}"
    echo -e "短身份码  : ${YELLOW}${XRAY_SID}${PLAIN}"
    echo -e "${GREEN}============================================${PLAIN}"
    echo -e "🚀 ${CYAN}分享链接 (完整复制此链接导入客户端):${PLAIN}"
    echo -e "${YELLOW}${LINK}${PLAIN}"
    echo -e "${GREEN}============================================${PLAIN}"
    read -p "按回车键返回主菜单..."
}

# 3. 查看运行状态
view_status() {
    clear
    echo -e "${GREEN}========== Xray 实时运行状态 ==========${PLAIN}"
    systemctl status xray --no-pager | head -n 10
    echo -e "\n${GREEN}========== 最近 10 条运行日志 ==========${PLAIN}"
    journalctl -u xray -n 10 --no-pager
    echo -e "============================================"
    read -p "按回车键返回主菜单..."
}

# 4. 卸载 Xray
uninstall_xray() {
    clear
    read -p "⚠️ 确定要彻底卸载 Xray 及所有配置吗？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl stop xray
        systemctl disable xray
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove > /dev/null 2>&1
        rm -rf /usr/local/etc/xray
        rm -f "/usr/local/bin/xr"
        echo -e "${GREEN}✅ Xray 已彻底卸载清理完毕。${PLAIN}"
        exit 0
    fi
}

# ================= 主菜单逻辑 =================
show_menu() {
    while true; do
        clear
        echo -e "${GREEN}=======================================${PLAIN}"
        echo -e "${CYAN}        Xray 全局中控面板 (XMGR)         ${PLAIN}"
        echo -e "${GREEN}=======================================${PLAIN}"
        
        # 检查运行状态以显示标签
        if systemctl is-active --quiet xray; then
            echo -e "当前引擎状态: ${GREEN}▶ 运行中 (Active)${PLAIN}"
        else
            echo -e "当前引擎状态: ${RED}■ 已停止/未配置 (Inactive)${PLAIN}"
        fi
        echo -e "${GREEN}=======================================${PLAIN}"
        echo -e "${YELLOW} 1.${PLAIN} 🚀 部署 / 重新配置参数 (更换端口/域名)"
        echo -e "${YELLOW} 2.${PLAIN} 🔗 查看节点订阅链接 (随时提取)"
        echo -e "${YELLOW} 3.${PLAIN} 🔄 重启 Xray 服务引擎"
        echo -e "${YELLOW} 4.${PLAIN} 📊 查看引擎运行状态与日志"
        echo -e "${YELLOW} 5.${PLAIN} 🗑️  彻底抹除 Xray 环境"
        echo -e "${YELLOW} 0.${PLAIN} 退出看板"
        echo -e "${GREEN}=======================================${PLAIN}"
        read -p "请输入序号选择操作: " choice

        case $choice in
            1) install_or_reconfig ;;
            2) view_link ;;
            3) systemctl restart xray && echo -e "${GREEN}✅ 引擎已重启！${PLAIN}" && sleep 1 ;;
            4) view_status ;;
            5) uninstall_xray ;;
            0) exit 0 ;;
            *) echo -e "${RED}请输入正确的数字！${PLAIN}" && sleep 1 ;;
        esac
    done
}

# 执行主菜单
show_menu
