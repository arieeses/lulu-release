#!/usr/bin/env bash
# lulu management script — install / service control / tuning, v2node-style.
#
#   lulu.sh                 interactive menu
#   lulu.sh install [SRC]   install (SRC = binary, .tar.gz, or URL; else auto)
#   lulu.sh update  [SRC]   replace the binary and restart
#   lulu.sh uninstall       remove the service and binary (keeps /etc/lulu)
#   lulu.sh start|stop|restart|status|log
#   lulu.sh enable|disable  boot autostart on/off
#   lulu.sh version         installed (and running) build
#   lulu.sh bbr             enable BBR + fq
#   lulu.sh swap [SIZE]     enable zswap + a swapfile (default 1G)
#   lulu.sh haproxy install|start|stop|restart|uninstall [URL]
set -uo pipefail

red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; plain='\033[0m'
ok()   { echo -e "${green}$*${plain}"; }
warn() { echo -e "${yellow}$*${plain}"; }
err()  { echo -e "${red}$*${plain}" >&2; }

BIN=/usr/local/bin/lulu
CFG_DIR=/etc/lulu
SERVICE=/etc/systemd/system/lulu.service
# Prebuilt binary (public release repo; source stays in the private repo).
REL_URL="${LULU_RELEASE_URL:-https://github.com/arieeses/lulu-release/releases/latest/download/lulu-x86_64-linux.tar.gz}"
# lulu accepts TOML or YAML (auto-detected by extension); prefer the user's yml.
cfg_path() {
  if [[ -f "$CFG_DIR/config.yml" ]]; then echo "$CFG_DIR/config.yml"
  elif [[ -f "$CFG_DIR/config.yaml" ]]; then echo "$CFG_DIR/config.yaml"
  else echo "$CFG_DIR/config.toml"; fi
}

need_root() { [[ $EUID -eq 0 ]] || { err "请用 root 运行 (sudo)"; exit 1; }; }

pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  elif command -v apk >/dev/null 2>&1; then echo apk
  elif command -v pacman >/dev/null 2>&1; then echo pacman
  else echo ""; fi
}
pkg_install() {
  case "$(pkg_mgr)" in
    apt) apt-get update -y >/dev/null 2>&1; apt-get install -y "$@" ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    apk) apk add "$@" ;;
    pacman) pacman -Sy --noconfirm "$@" ;;
    *) err "无法识别的包管理器,请手动安装: $*"; return 1 ;;
  esac
}

# ---- resolve a binary from a path / .tar.gz / URL into $1 (dest tmp file) ----
fetch_binary() {
  local src="$1" dest="$2" tmp
  tmp="$(mktemp -d)"
  # No explicit source -> always pull the latest published release, so the
  # result is deterministic (not whatever stale binary happens to be lying
  # around). To install a specific local build, pass it: install ./lulu or
  # install ./lulu-x86_64-linux.tar.gz.
  if [[ -z "$src" ]]; then
    src="$REL_URL"
    warn "从发布页下载最新版: $src"
  fi
  [[ -z "$src" ]] && { err "找不到二进制;用法: install /路径/lulu 或 install xxx.tar.gz 或 install <URL>"; rm -rf "$tmp"; return 1; }
  # URL -> download into tmp, keep the name.
  if [[ "$src" =~ ^https?:// ]]; then
    local f="$tmp/$(basename "$src")"
    curl -fsSL "$src" -o "$f" || { err "下载失败: $src"; rm -rf "$tmp"; return 1; }
    src="$f"
  fi
  if [[ "$src" == *.tar.gz || "$src" == *.tgz ]]; then
    tar xzf "$src" -C "$tmp" lulu 2>/dev/null || tar xzf "$src" -C "$tmp" ./lulu 2>/dev/null || tar xzf "$src" -C "$tmp" 2>/dev/null
    src="$tmp/lulu"; [[ -f "$src" ]] || src="$(find "$tmp" -maxdepth 2 -type f -name lulu | head -1)"
  fi
  [[ -f "$src" ]] || { err "二进制无效: $src"; rm -rf "$tmp"; return 1; }
  # sanity: a Linux x86-64 ELF
  if ! head -c4 "$src" | grep -q $'\x7fELF'; then err "不是 ELF 可执行文件: $src"; rm -rf "$tmp"; return 1; fi
  install -m0755 "$src" "$dest"
  rm -rf "$tmp"
}

write_service() {
  cat >"$SERVICE" <<EOF
[Unit]
Description=lulu proxy node backend
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN -c $(cfg_path)
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
# return freed memory to the OS sooner
Environment=MIMALLOC_PURGE_DELAY=0

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

installed_version() { [[ -x "$BIN" ]] && grep -ao 'lulu [0-9.]* ([^)]*)' "$BIN" | head -1; }

# -------------------------------- commands ----------------------------------
do_install() {
  need_root
  fetch_binary "${1:-}" "$BIN" || return 1
  mkdir -p "$CFG_DIR"
  local cfg; cfg="$(cfg_path)"
  if [[ ! -f "$cfg" ]]; then
    cat >"$cfg" <<'YML'
Log:
  Level: info
Nodes:
  - ApiHost: "https://your-panel.com"
    ApiKey: "your-node-secret"
    NodeID: 1
    NodeType: ""        # 空=XiaoV2Board v2node;或 shadowsocks/vmess/vless/trojan/hysteria2/tuic...
    Timeout: 60
YML
    warn "已创建示例配置 $cfg — 请编辑 ApiHost / ApiKey / NodeID 后再启动"
  fi
  write_service
  ok "已安装: $(installed_version)"
  if "$BIN" check -c "$cfg" >/dev/null 2>&1; then
    systemctl enable --now lulu
    ok "lulu 已启动并设为开机自启"
    systemctl --no-pager status lulu | head -4
  else
    systemctl enable lulu >/dev/null 2>&1
    warn "配置尚未通过校验,已设开机自启但未启动。编辑 $cfg 后执行: lulu.sh start"
  fi
}

do_update() {
  need_root
  [[ -x "$BIN" ]] || { err "未安装,先执行: lulu.sh install"; return 1; }
  local old; old="$(installed_version)"
  local was_active=0; systemctl is-active --quiet lulu && was_active=1
  systemctl stop lulu 2>/dev/null
  fetch_binary "${1:-}" "$BIN" || { [[ $was_active -eq 1 ]] && systemctl start lulu; return 1; }
  write_service
  ok "更新: ${old:-?}  ->  $(installed_version)"
  [[ $was_active -eq 1 ]] && { systemctl start lulu; systemctl --no-pager status lulu | head -3; }
}

do_uninstall() {
  need_root
  systemctl disable --now lulu 2>/dev/null
  rm -f "$SERVICE"; systemctl daemon-reload; systemctl reset-failed 2>/dev/null
  rm -f "$BIN"
  ok "已卸载 lulu(配置保留在 $CFG_DIR;如需一并删除: rm -rf $CFG_DIR)"
}

svc() { need_root; systemctl "$1" lulu && ok "lulu $1 完成"; }
do_status() { systemctl --no-pager status lulu; }
do_log() { journalctl -u lulu -n "${1:-100}" -f; }
do_version() {
  echo "二进制: $(installed_version || echo 未安装)"
  systemctl is-active --quiet lulu && echo "运行中: $("$BIN" version 2>/dev/null)"
}

do_bbr() {
  need_root
  cat >/etc/sysctl.d/99-lulu-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
EOF
  modprobe tcp_bbr 2>/dev/null || true
  sysctl --system >/dev/null 2>&1
  local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  if [[ "$cc" == bbr ]]; then ok "BBR 已开启 (拥塞控制: $cc, qdisc: $(sysctl -n net.core.default_qdisc))"
  else err "BBR 开启失败,当前: $cc(内核可能不支持 bbr)"; fi
}

do_swap() {
  need_root
  local size="${1:-1G}" sf=/swapfile
  # zswap: 运行时开启 + 开机持久化(写 /sys 的 oneshot 服务)。
  if [[ -d /sys/module/zswap ]]; then
    cat >/etc/systemd/system/lulu-zswap.service <<'EOF'
[Unit]
Description=enable zswap
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 1 > /sys/module/zswap/parameters/enabled; \
  (echo zstd > /sys/module/zswap/parameters/compressor 2>/dev/null || echo lz4 > /sys/module/zswap/parameters/compressor); \
  (echo zsmalloc > /sys/module/zswap/parameters/zpool 2>/dev/null || true); \
  echo 25 > /sys/module/zswap/parameters/max_pool_percent'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable --now lulu-zswap >/dev/null 2>&1
    ok "zswap 已开启 (enabled=$(cat /sys/module/zswap/parameters/enabled 2>/dev/null), compressor=$(cat /sys/module/zswap/parameters/compressor 2>/dev/null))"
  else
    warn "内核无 zswap 模块,跳过 zswap(仅建立 swap)"
  fi
  # swapfile
  if swapon --show 2>/dev/null | grep -q "$sf"; then
    ok "swap 已存在: $(swapon --show | grep "$sf")"
  else
    if fallocate -l "$size" "$sf" 2>/dev/null || dd if=/dev/zero of="$sf" bs=1M count="$(numfmt --from=iec "$size" 2>/dev/null | awk '{print int($1/1048576)}')" status=none; then
      chmod 600 "$sf"; mkswap "$sf" >/dev/null; swapon "$sf"
      grep -q "^$sf " /etc/fstab || echo "$sf none swap sw 0 0" >>/etc/fstab
      ok "swapfile $size 已建立并启用"
    else
      err "创建 swapfile 失败"; return 1
    fi
  fi
  sysctl -w vm.swappiness=60 >/dev/null
  grep -q '^vm.swappiness' /etc/sysctl.d/99-lulu-bbr.conf 2>/dev/null || echo 'vm.swappiness = 60' >>/etc/sysctl.d/99-lulu-swap.conf
  ok "当前内存/交换:"; free -h
}

do_haproxy() {
  need_root
  local action="${1:-install}" url="${2:-}"
  case "$action" in
    install)
      command -v haproxy >/dev/null 2>&1 || pkg_install haproxy socat || return 1
      mkdir -p /etc/haproxy
      if [[ -n "$url" ]]; then
        [[ -f /etc/haproxy/haproxy.cfg ]] && cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak
        curl -fsSL "$url/haproxy.cfg" -o /etc/haproxy/haproxy.cfg && ok "已从 $url 拉取 haproxy.cfg"
        curl -fsSL "$url/sni.map" -o /etc/haproxy/sni.map 2>/dev/null && ok "已拉取 sni.map"
      elif [[ ! -f /etc/haproxy/haproxy.cfg ]]; then
        cat >/etc/haproxy/haproxy.cfg <<'EOF'
global
    log /dev/log local0
    maxconn 20000
defaults
    mode tcp
    timeout connect 5s
    timeout client  300s
    timeout server  300s
# 示例:443 按 SNI 分流,请按需编辑
frontend ft_443
    bind :::443 v4v6
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    default_backend bk_lulu
backend bk_lulu
    mode tcp
    server lulu 127.0.0.1:8443
EOF
        warn "已写入示例 /etc/haproxy/haproxy.cfg — 请按你的 SNI 分流需求编辑"
      fi
      haproxy -c -f /etc/haproxy/haproxy.cfg || { err "haproxy 配置校验失败"; return 1; }
      systemctl enable --now haproxy && ok "haproxy 已启动并开机自启"
      ;;
    start|stop|restart) systemctl "$action" haproxy && ok "haproxy $action 完成" ;;
    uninstall)
      systemctl disable --now haproxy 2>/dev/null
      case "$(pkg_mgr)" in
        apt) apt-get remove -y haproxy >/dev/null 2>&1 ;;
        dnf) dnf remove -y haproxy >/dev/null 2>&1 ;;
        yum) yum remove -y haproxy >/dev/null 2>&1 ;;
        apk) apk del haproxy >/dev/null 2>&1 ;;
        pacman) pacman -R --noconfirm haproxy >/dev/null 2>&1 ;;
      esac
      ok "haproxy 已卸载(配置保留在 /etc/haproxy)"
      ;;
    *) err "haproxy: 未知操作 $action (install|start|stop|restart|uninstall)" ;;
  esac
}

menu() {
  local v; v="$(installed_version || echo 未安装)"
  echo "────────────── lulu 管理 [$v] ──────────────"
  cat <<EOF
  1) 安装            2) 更新            3) 卸载
  4) 启动            5) 停止            6) 重启
  7) 状态            8) 日志            9) 查看版本
 10) 开机自启: 开    11) 开机自启: 关
 12) 开启 BBR        13) 开启 zswap+SWAP
 14) HAProxy 安装    15) HAProxy 启动   16) HAProxy 重启
 17) HAProxy 停止    18) HAProxy 卸载
  0) 退出
EOF
  read -rp "选择: " c
  case "$c" in
    1) do_install ;; 2) do_update ;; 3) do_uninstall ;;
    4) svc start ;; 5) svc stop ;; 6) svc restart ;;
    7) do_status ;; 8) do_log ;; 9) do_version ;;
    10) svc enable ;; 11) svc disable ;;
    12) do_bbr ;; 13) do_swap ;;
    14) do_haproxy install ;; 15) do_haproxy start ;; 16) do_haproxy restart ;;
    17) do_haproxy stop ;; 18) do_haproxy uninstall ;;
    0) exit 0 ;; *) err "无效选择" ;;
  esac
}

case "${1:-menu}" in
  install)   do_install "${2:-}" ;;
  update)    do_update "${2:-}" ;;
  uninstall) do_uninstall ;;
  start)     svc start ;;
  stop)      svc stop ;;
  restart)   svc restart ;;
  status)    do_status ;;
  log|logs)  do_log "${2:-100}" ;;
  enable)    svc enable ;;
  disable)   svc disable ;;
  version|-v|--version) do_version ;;
  bbr)       do_bbr ;;
  swap)      do_swap "${2:-1G}" ;;
  haproxy)   do_haproxy "${2:-install}" "${3:-}" ;;
  menu|"")   menu ;;
  *) err "未知命令: $1"; echo "用法见脚本头部注释"; exit 1 ;;
esac
