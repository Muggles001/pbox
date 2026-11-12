has() { command -v "$1" >/dev/null 2>&1; }

# 测试模式：不碰系统服务、账号、防火墙，只跑状态与渲染逻辑。
testing() { [ -n "${PBOX_TEST:-}" ]; }

need_root() {
  testing && return 0
  [ "$(id -u)" = 0 ] || die "$(t need_root)"
}

is_musl() { [ -f /etc/alpine-release ]; }

need_installed() { [ -d "$STATE" ] || die "$(t not_installed)"; }

# 目录锁：防止两个 pbox 进程同时改配置。持有者已退出的旧锁会被接管。
lock() {
  local pid
  [ "$LOCKED" = 1 ] && return 0
  mkdir -p "$(dirname "$LOCKDIR")" 2>/dev/null
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    pid=$(cat "$LOCKDIR/pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then die "$(t locked)"; fi
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" 2>/dev/null || die "$(t locked)"
  fi
  echo $$ >"$LOCKDIR/pid"
  LOCKED=1
  trap 'unlock' EXIT
  trap 'unlock; exit 130' INT TERM
}

lock_try() {
  [ "$LOCKED" = 1 ] && return 0
  mkdir -p "$(dirname "$LOCKDIR")" 2>/dev/null
  mkdir "$LOCKDIR" 2>/dev/null || return 1
  echo $$ >"$LOCKDIR/pid"
  LOCKED=1
  trap 'unlock' EXIT
}

unlock() {
  [ "$LOCKED" = 1 ] && rm -rf "$LOCKDIR"
  LOCKED=0
}

detect_sys() {
  if testing; then
    OS_ID=test INIT=none ARCH=amd64 PKG=none
    return 0
  fi
  OS_ID=$(. /etc/os-release 2>/dev/null && echo "$ID")
  case "$OS_ID" in
    debian | ubuntu) PKG=apt ;;
    alpine) PKG=apk ;;
    *) die "$(t os_unsupported "${OS_ID:-?}")" ;;
  esac
  if has systemctl && [ -d /run/systemd/system ]; then
    INIT=systemd
  elif has rc-service; then
    INIT=openrc
  else
    die "$(t init_unsupported)"
  fi
  case "$(uname -m)" in
    x86_64 | amd64) ARCH=amd64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *) die "$(t arch_unsupported "$(uname -m)")" ;;
  esac
}

pkg_install() {
  case "$PKG" in
    apt) apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
    apk) apk add --no-cache "$@" ;;
    *) return 1 ;;
  esac
}

ensure_deps() {
  local c miss=""
  for c in curl tar unzip openssl; do has "$c" || miss="$miss $c"; done
  if ! has ss && ! has netstat; then miss="$miss iproute2"; fi
  [ -z "$miss" ] && return 0
  say "$(t deps_missing "$miss")"
  confirm "$(t deps_install_q)" || die "$(t deps_declined)"
  # shellcheck disable=SC2086
  pkg_install $miss >/dev/null || die "$(t deps_fail "$miss")"
}

sha256_of() {
  if has sha256sum; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# 安装清单：记下创建过的每样东西，卸载时逐项撤销。
manifest_add() {
  mkdir -p "$ETC"
  grep -qxF "$1	$2" "$MANIFEST" 2>/dev/null || printf '%s\t%s\n' "$1" "$2" >>"$MANIFEST"
}

manifest_del() {
  [ -f "$MANIFEST" ] || return 0
  grep -vxF "$1	$2" "$MANIFEST" >"$MANIFEST.tmp"
  mv "$MANIFEST.tmp" "$MANIFEST"
}

run_user_create() {
  testing && return 0
  id "$RUN_USER" >/dev/null 2>&1 && return 0
  if [ "$PKG" = apk ]; then
    addgroup -S "$RUN_USER" 2>/dev/null
    adduser -S -D -H -s /sbin/nologin -G "$RUN_USER" "$RUN_USER" || return 1
  else
    useradd -r -M -s /usr/sbin/nologin "$RUN_USER" || return 1
  fi
  manifest_add user "$RUN_USER"
}

# 有些服务商的系统模板把 /etc/resolv.conf 设成只有 root 可读。内核以专用账号运行，
# 读不到它就解析不了任何域名，表现为端口在监听但所有连接超时。
runuser_reads_dns() {
  testing && return 0
  # 看文件是否对所有人可读。不用 su 去试读：那会给专用账号开一个登录会话，
  # 残留的会话进程会让卸载时删不掉这个账号。
  [ -n "$(find -L /etc/resolv.conf -maxdepth 0 -perm -004 2>/dev/null)" ]
}

# 不改动系统文件：复制一份给内核，由服务文件把它映射成内核自己看到的 /etc/resolv.conf。
dns_sync() {
  testing && return 0
  if runuser_reads_dns; then
    rm -f "$ETC/resolv.conf"
  else
    cp /etc/resolv.conf "$ETC/resolv.conf" 2>/dev/null
  fi
}

# svc <动作> <服务名>
svc() {
  local a="$1" n="$2"
  testing && return 0
  if [ "$INIT" = systemd ]; then
    case "$a" in
      enable | disable) systemctl "$a" "$n" >/dev/null 2>&1 ;;
      active) systemctl is-active --quiet "$n" ;;
      *) systemctl "$a" "$n" ;;
    esac
  else
    case "$a" in
      enable) rc-update add "$n" default >/dev/null 2>&1 ;;
      disable) rc-update del "$n" default >/dev/null 2>&1 ;;
      active) rc-service "$n" status >/dev/null 2>&1 ;;
      reload) return 1 ;;
      *) rc-service "$n" "$a" >/dev/null ;;
    esac
  fi
}

# svc_write <服务名> <启动命令> [支持热重载 0|1] [额外的一行服务设置]
# 内核以专用账号运行，只保留绑定低位端口的能力；日志写文件，便于单独清空。
svc_write() {
  local n="$1" cmd="$2" rel="${3:-0}" extra="${4:-}" f before
  UNIT_CHANGED=0
  testing && return 0
  [ "$INIT" = systemd ] && f="/etc/systemd/system/$n.service" || f="/etc/init.d/$n"
  before=$(cat "$f" 2>/dev/null)
  mkdir -p "$LOGDIR" "$VARDIR"
  chown "$RUN_USER:$RUN_USER" "$LOGDIR" "$VARDIR"
  chmod 750 "$LOGDIR" "$VARDIR"
  manifest_add dir "$LOGDIR"
  manifest_add dir "$VARDIR"
  if [ "$INIT" = systemd ]; then
    f="/etc/systemd/system/$n.service"
    {
      cat <<EOF
[Unit]
Description=$n
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=$RUN_USER
Group=$RUN_USER
WorkingDirectory=$VARDIR
ExecStart=$cmd
EOF
      [ "$rel" = 1 ] && echo 'ExecReload=/bin/kill -HUP $MAINPID'
      [ -n "$extra" ] && echo "$extra"
      [ -f "$ETC/resolv.conf" ] && echo "BindReadOnlyPaths=$ETC/resolv.conf:/etc/resolv.conf"
      cat <<EOF
Restart=on-failure
RestartSec=5
RestartPreventExitStatus=23
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
StandardOutput=append:$LOGDIR/$n.log
StandardError=append:$LOGDIR/$n.log

[Install]
WantedBy=multi-user.target
EOF
    } >"$f"
    systemctl daemon-reload
  else
    f="/etc/init.d/$n"
    cat >"$f" <<EOF
#!/sbin/openrc-run
name="$n"
command="${cmd%% *}"
command_args="${cmd#* }"
command_user="$RUN_USER:$RUN_USER"
command_background=true
directory="$VARDIR"
pidfile="/run/\${RC_SVCNAME}.pid"
capabilities="^cap_net_bind_service"
output_log="$LOGDIR/$n.log"
error_log="$LOGDIR/$n.log"
depend() { need net; }
EOF
    chmod 755 "$f"
  fi
  # 服务文件有变化时，热重载不够，调用方必须重启才能让新的运行环境生效
  [ "$before" = "$(cat "$f")" ] || UNIT_CHANGED=1
  manifest_add svc "$n"
  manifest_add file "$f"
}

svc_remove() {
  local n="$1" f
  testing && return 0
  svc stop "$n" 2>/dev/null
  svc disable "$n"
  for f in "/etc/systemd/system/$n.service" "/etc/init.d/$n"; do
    [ -f "$f" ] && rm -f "$f" && manifest_del file "$f"
  done
  [ "$INIT" = systemd ] && systemctl daemon-reload
  manifest_del svc "$n"
}

# 内核只需要读生成的配置和证书；状态、节点链接、备份只有 root 能读。
fix_perms() {
  testing && return 0
  # 创建目录时的默认权限不允许其他账号进入；内核以专用账号运行，必须能走到自己的程序文件
  chmod 755 "$LIBDIR" "$BINDIR" 2>/dev/null
  dns_sync
  chown -R root:root "$ETC"
  chmod 750 "$ETC"
  chgrp "$RUN_USER" "$ETC"
  [ -f "$ETC/resolv.conf" ] && chgrp "$RUN_USER" "$ETC/resolv.conf" && chmod 640 "$ETC/resolv.conf"
  local d
  for d in "$GEN" "$CERTS" "$CUSTOM"; do
    [ -d "$d" ] || continue
    chgrp -R "$RUN_USER" "$d"
    find "$d" -type d -exec chmod 750 {} +
    find "$d" -type f -exec chmod 640 {} +
  done
  for d in "$STATE" "$NODES" "$PREV"; do
    [ -d "$d" ] || continue
    find "$d" -type d -exec chmod 700 {} +
    find "$d" -type f -exec chmod 600 {} +
  done
  [ -f "$MANIFEST" ] && chmod 600 "$MANIFEST"
  return 0
}
