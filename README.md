# Xray VLESS-Vision-Reality 一键安装脚本

> 专为 Debian 12 / Ubuntu 设计的极简主义安装脚本，部署目前最强抗封锁协议 VLESS + Vision + Reality。

## 🚀 项目特点

- **极简纯净**：无任何面板、无广告、无后台监控，只安装 Xray 官方内核。
- **最新协议**：默认配置 VLESS + XTLS-Vision + Reality 流控模式。
- **智能兼容**：自动识别 Xray 新旧版本密钥输出格式（自动解析 `PrivateKey`/`Password` 字段）。
- **完全自定义**：支持自定义端口、伪装域名 (SNI) 和分享链接备注名称。
- **自动优化**：安装过程中自动开启内核 BBR 加速。
- **一键输出**：安装完毕自动生成 standard `vless://` 分享链接，可直接导入 Hiddify、v2rayN 等客户端。

## 🛠️ 环境要求

- **操作系统**：Debian 12+ (推荐) / Ubuntu 22.04+
- **架构**：x86_64 / amd64
- **权限**：Root 用户

## 💻 一键安装命令

请将下面的命令复制到服务器终端中执行：

```bash
apt update && apt install -y curl && bash <(curl -Ls https://raw.githubusercontent.com/zdaben/xray_install/main/xray-mgr.sh)
```


## ⚙️ 安装流程说明
- 运行脚本后，你需要根据提示输入以下信息（直接回车可使用默认值）：

- 端口号：默认 34567
-注意：请确保 VPS 防火墙/安全组已放行该端口。

-伪装域名 (SNI)：默认 www.bing.com
-说明：Reality 协议不需要你自己拥有域名，这是用来伪装的目标网站。

-链接备注名：默认 zdaben
-说明：这是显示在客户端节点列表中的名字。

⏳ 安装完成后，脚本会输出红色的配置信息和黄色的分享链接，直接复制链接即可导入客户端使用。


## 📱 客户端推荐
本脚本生成的配置适配以下支持 Reality 协议的客户端：

Windows: Hiddify, v2rayN (6.23+), Clash Verge Rev

Android: v2rayNG, Hiddify

iOS: Shadowrocket (小火箭), Stash

macOS: V2Box, Clash Verge Rev


## 🔧 常用维护命令
Xray 安装为系统服务，你可以使用标准的 systemctl 命令进行管理：

### 启动/停止/重启
```Bash
systemctl start xray    # 启动
systemctl stop xray     # 停止
systemctl restart xray  # 重启 (修改配置后必须执行)
```

### 查看状态
```Bash
systemctl status xray
```
如果显示绿色的 active (running) 表示运行正常。

### 查看实时日志 (排查连接问题)
```Bash
journalctl -u xray -f
```

### 修改配置文件
配置文件路径位于：/usr/local/etc/xray/config.json
```Bash
nano /usr/local/etc/xray/config.json
# 或者
vim /usr/local/etc/xray/config.json
```

## ⚠️ 免责声明
本脚本仅供学习交流和服务器运维测试使用，请勿用于非法用途。使用本脚本所产生的任何后果由使用者自行承担。
