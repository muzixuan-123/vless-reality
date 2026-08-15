#!/bin/bash
#=================================================================
#  reality.sh — VLESS-REALITY (Xray-core) 一键部署脚本
#  适配: Alpine(OpenRC) / Debian·Ubuntu(systemd) , x86_64 / arm64
#  作者用途: NAT VPS 自用节点, 经实测客户端 v2rayNG(Xray v26.x) 通过
#=================================================================
set -euo pipefail

# ---------- 可调默认值 (也可用环境变量覆盖) ----------
XRAY_VER="${XRAY_VER:-v26.6.27}"        # 与客户端核心保持一致, 避免 REALITY 握手不兼容
PORT="${PORT:-30810}"                    # 监听端口 (NAT 机请填已映射的外网端口)
DEST="${DEST:-www.apple.com}"            # REALITY 偷跑目标 (需支持 TLS1.3+H2, 就近大站)
TAG="${TAG:-}"                           # 节点备注名 (留空则按 IP 位置自动检测, 如 JP-REALITY)
# ----------------------------------------------------

XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
CONF="$XRAY_DIR/config.json"
INFO_FILE="$XRAY_DIR/node-info.txt"

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }
die(){ red "错误: $*"; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 运行"

# ---------- IP 位置检测: 自动生成节点名 ----------
detect_tag(){
  local cc loc
  # 依次尝试多个 GeoIP 接口, 任一成功即可
  cc="$(curl -fsS --max-time 5 https://ipinfo.io/country 2>/dev/null || true)"
  [ -n "$cc" ] || cc="$(curl -fsS --max-time 5 http://ip-api.com/line/?fields=countryCode 2>/dev/null || true)"
  [ -n "$cc" ] || cc="$(curl -fsS --max-time 5 https://ipapi.co/country/ 2>/dev/null || true)"
  cc="$(printf '%s' "$cc" | tr '[:lower:]' '[:upper:]' | tr -dc 'A-Z')"
  if [ -n "$cc" ]; then
    echo "${cc}-REALITY"
  else
    echo "UNKNOWN-REALITY"
  fi
}
ensure_tag(){
  [ -n "$TAG" ] || TAG="$(detect_tag)"
}

# ---------- 环境探测 ----------
detect_env(){
  case "$(uname -m)" in
    x86_64|amd64) ARCH="64" ;;
    aarch64|arm64) ARCH="arm64-v8a" ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
  if command -v apk >/dev/null 2>&1; then PKG="apk"; INIT="openrc"
  elif command -v apt-get >/dev/null 2>&1; then PKG="apt"; INIT="systemd"
  else PKG="unknown"; INIT=$([ -d /run/systemd/system ] && echo systemd || echo openrc); fi
}

install_deps(){
  case "$PKG" in
    apk)  apk add --no-cache curl wget unzip openssl >/dev/null 2>&1 || true ;;
    apt)  apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq curl wget unzip openssl >/dev/null 2>&1 || true ;;
  esac
}

# ---------- 下载 Xray ----------
install_xray(){
  local url tmp
  url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-${ARCH}.zip"
  tmp="$(mktemp -d)"
  ylw "下载 Xray ${XRAY_VER} (${ARCH}) ..."
  wget -qO "$tmp/x.zip" "$url" || curl -fsSL -o "$tmp/x.zip" "$url" || die "下载失败: $url"
  unzip -o "$tmp/x.zip" xray -d "$tmp" >/dev/null || die "解压失败"
  install -m755 "$tmp/xray" "$XRAY_BIN"
  rm -rf "$tmp"
  grn "已安装: $($XRAY_BIN version | head -1)"
}

# ---------- 生成配置 ----------
gen_config(){
  mkdir -p "$XRAY_DIR"
  local uuid kp priv pub sid

  # 幂等: 已有配置则复用原 UUID/密钥/shortId (导入链接保持不变), 除非显式 REGEN=1
  if [ -f "$CONF" ] && [ "${REGEN:-0}" != "1" ]; then
    uuid="$(grep -oE '"id"[^,]*' "$CONF" | head -1 | grep -oE '[0-9a-fA-F-]{36}')"
    priv="$(grep -oE '"privateKey"[^,]*' "$CONF" | head -1 | sed -E 's/.*"privateKey" *: *"([^"]*)".*/\1/')"
    sid="$(grep -oE '"shortIds"[^]]*' "$CONF" | grep -oE '"[0-9a-fA-F]+"' | head -1 | tr -d '"')"
  fi

  # 缺任一字段(首装 或 REGEN=1 或 旧配置不完整)则重新生成
  if [ -z "${uuid:-}" ] || [ -z "${priv:-}" ] || [ -z "${sid:-}" ]; then
    uuid="$($XRAY_BIN uuid)"
    kp="$($XRAY_BIN x25519)"
    priv="$(echo "$kp" | awk -F': *' '/[Pp]rivate/{print $2}')"
    sid="$(openssl rand -hex 8)"
    ylw "已生成新的 UUID / REALITY 密钥 / shortId"
  else
    ylw "复用现有 UUID / 密钥 / shortId (导入链接不变; 如需重置请加 REGEN=1)"
  fi
  # 由私钥推导公钥, 保证 pbk 与 privateKey 始终配对
  pub="$($XRAY_BIN x25519 -i "$priv" 2>/dev/null | awk -F': *' '/[Pp]ublic/{print $2}')"

  cat > "$CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${uuid}", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}:443",
          "xver": 0,
          "serverNames": [ "${DEST}" ],
          "privateKey": "${priv}",
          "shortIds": [ "${sid}" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls" ] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct", "settings": { "domainStrategy": "UseIPv4" } }
  ]
}
EOF
  "$XRAY_BIN" -test -c "$CONF" >/dev/null 2>&1 || die "配置校验失败"

  # 保存分享信息
  local ip
  ip="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo YOUR_SERVER_IP)"
  local link="vless://${uuid}@${ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp#${TAG}"
  cat > "$INFO_FILE" <<EOF
地址(Address)   : ${ip}
端口(Port)      : ${PORT}
UUID           : ${uuid}
Flow           : xtls-rprx-vision
传输(Network)   : tcp
安全(Security)  : reality
SNI/ServerName : ${DEST}
Fingerprint    : chrome
PublicKey(pbk) : ${pub}
ShortId(sid)   : ${sid}

导入链接:
${link}
EOF
}

# ---------- 服务 (OpenRC / systemd) ----------
setup_service(){
  if [ "$INIT" = "openrc" ]; then
    cat > /etc/init.d/xray <<'RC'
#!/sbin/openrc-run
description="Xray VLESS-REALITY service"
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_user="root"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
pidfile="/run/xray.pid"
output_log="/var/log/xray.log"
error_log="/var/log/xray.log"
depend() { need net; }
RC
    chmod +x /etc/init.d/xray
    rc-update add xray default >/dev/null 2>&1 || true
    # 无论首装还是重装, 都强制重启以加载最新配置
    rc-service xray restart
  else
    cat > /etc/systemd/system/xray.service <<'SD'
[Unit]
Description=Xray VLESS-REALITY service
After=network.target nss-lookup.target
[Service]
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
SD
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1 || true
    # 无论首装还是重装, 都强制重启以加载最新配置 (enable --now 不会重启已运行的服务)
    systemctl restart xray
  fi
}

svc(){  # svc <start|stop|restart|status>
  if [ "$INIT" = "openrc" ]; then rc-service xray "$1"; else systemctl "$1" xray; fi
}

show_info(){
  [ -f "$INFO_FILE" ] || die "未找到节点信息, 请先安装"
  echo; grn "================= 节点信息 ================="
  cat "$INFO_FILE"
  grn "==========================================="
}

do_install(){
  detect_env; ensure_tag; install_deps; install_xray; gen_config; setup_service
  sleep 1
  # 校验服务确实在运行且端口在监听 (确认新配置已加载)
  local active listening
  if [ "$INIT" = "openrc" ]; then
    active="$(rc-service xray status 2>/dev/null | grep -q started && echo yes || echo no)"
  else
    active="$(systemctl is-active xray 2>/dev/null)"
  fi
  listening="$( (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q ":${PORT} " && echo yes || echo no)"
  echo; grn ">>> 部署完成 <<<"
  show_info
  echo
  if { [ "$active" = "yes" ] || [ "$active" = "active" ]; } && [ "$listening" = "yes" ]; then
    grn "服务状态: 运行中 ✔   端口 ${PORT}: 监听中 ✔ (已加载最新配置)"
  else
    red "警告: 服务未正常运行 (active=$active, 端口${PORT}监听=$listening), 请检查: xray -test -c ${CONF}"
  fi
  echo; ylw "提示: NAT 机请确认外网已映射到端口 ${PORT}; 客户端核心需 Xray ${XRAY_VER} 同代及以上"
}

do_uninstall(){
  detect_env
  svc stop 2>/dev/null || true
  if [ "$INIT" = "openrc" ]; then rc-update del xray default 2>/dev/null || true; rm -f /etc/init.d/xray
  else systemctl disable xray 2>/dev/null || true; rm -f /etc/systemd/system/xray.service; systemctl daemon-reload 2>/dev/null || true; fi
  rm -f "$XRAY_BIN"; rm -rf "$XRAY_DIR"; rm -f /var/log/xray.log
  grn "已卸载 Xray 及配置"
}

do_update(){
  detect_env; install_xray; svc restart; grn "内核已更新并重启 (配置保留)"
}

menu(){
  detect_env
  echo "======================================"
  echo "  VLESS-REALITY 一键脚本 (Xray ${XRAY_VER})"
  echo "  系统: ${PKG}/${INIT}  架构: ${ARCH}"
  echo "======================================"
  echo "  1) 安装 / 重装"
  echo "  2) 查看节点信息"
  echo "  3) 更新 Xray 内核"
  echo "  4) 卸载"
  echo "  5) 重启服务"
  echo "  0) 退出"
  echo "--------------------------------------"
  read -rp "选择: " c
  case "$c" in
    1) do_install ;;
    2) show_info ;;
    3) do_update ;;
    4) do_uninstall ;;
    5) svc restart && grn "已重启" ;;
    0) exit 0 ;;
    *) red "无效选择" ;;
  esac
}

# ---------- 入口: 支持命令行参数 (非交互) 与 菜单 ----------
case "${1:-}" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  update)    do_update ;;
  info)      detect_env; show_info ;;
  "")        menu ;;
  *) echo "用法: $0 [install|uninstall|update|info]  (无参数进入菜单)"; exit 1 ;;
esac
