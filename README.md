# xmgr 一键安装脚本

> 专为 Debian 12 / Ubuntu 设计的极简主义安装脚本。


## 💻 一键安装命令

请将下面的命令复制到服务器终端中执行：

```bash
# Xmgr一键部署脚本
apt update -y && curl -sSLo /usr/local/bin/xmgr https://raw.githubusercontent.com/zdaben/xmgr_install/main/xmgr.sh && chmod +x /usr/local/bin/xmgr  && xmgr install
```
⏳ 安装完成后，脚本会输出红色的配置信息和黄色的分享链接，直接复制链接即可导入客户端使用。


## ⚠️ 免责声明
本脚本仅供学习交流和服务器运维测试使用，请勿用于非法用途。使用本脚本所产生的任何后果由使用者自行承担。
