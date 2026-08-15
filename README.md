# VLESS-REALITY 一键部署脚本

基于 Xray-core 的 VLESS-REALITY 节点一键部署脚本，适配 NAT VPS 自用场景。

## 特性

- 自动适配 **x86_64 / arm64** 架构与 **Alpine(OpenRC) / Debian·Ubuntu(systemd)** 系统
- 锁定 Xray-core `v26.6.27`，与主流客户端核心同代，避免 REALITY 握手不兼容
- 每次安装自动生成全新 UUID / REALITY 密钥对 / shortId，无硬编码密钥
- **自动检测服务器 IP 位置生成节点名**（如 JP-REALITY / SG-REALITY / US-REALITY），也可用 `TAG` 手动覆盖
- 安装完成后直接输出节点信息与 `vless://` 导入链接
- 支持 `install` / `info` / `update` / `uninstall` 子命令，无参数进入交互菜单

## 使用

交互菜单：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/muzixuan-123/vless-reality/main/reality.sh)
```

非交互安装（NAT 机请把 PORT 改成你已映射的外网端口）：

```bash
PORT=30810 DEST=www.apple.com bash <(curl -fsSL https://raw.githubusercontent.com/muzixuan-123/vless-reality/main/reality.sh) install
```

查看已部署节点信息：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/muzixuan-123/vless-reality/main/reality.sh) info
```

## 可覆盖的环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PORT` | `30810` | 监听端口（NAT 机填映射的外网端口） |
| `DEST` | `www.apple.com` | REALITY 偷跑目标域名（需支持 TLS1.3 + H2） |
| `XRAY_VER` | `v26.6.27` | Xray-core 版本，建议与客户端核心保持一致 |
| `TAG` | 自动检测 | 节点备注名；留空按 IP 归属地自动生成，如 `JP-REALITY` |

## 命令

| 命令 | 作用 |
|---|---|
| `install` | 安装 / 重装（生成新密钥） |
| `info` | 查看节点信息与导入链接 |
| `update` | 仅更新 Xray 内核，保留配置 |
| `uninstall` | 卸载 Xray 及配置 |

## 客户端提示

- 客户端核心需为 Xray `v26.x` 同代及以上（如 v2rayNG 新版），否则 REALITY 握手会失败
- Flow 固定为 `xtls-rprx-vision`，Fingerprint 用 `chrome`