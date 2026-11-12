# BBR：只在系统内核已经支持时开启，不更换内核，不执行任何外部脚本。
# 做的事只有两条系统参数，写在脚本自己的一个文件里，关闭或卸载时删掉并恢复原值。

BBR_CONF="$R/etc/sysctl.d/99-pbox-bbr.conf"

bbr_ours() { [ -f "$BBR_CONF" ]; }

bbr_cur() {
  if testing; then
    if bbr_ours; then echo bbr; else echo cubic; fi
    return 0
  fi
  sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null
}

bbr_available() {
  testing && { [ "${PBOX_TEST_BBR:-1}" = 1 ]; return; }
  modprobe tcp_bbr 2>/dev/null
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

bbr_on() {
  local cc qd
  cc=$(bbr_cur)
  if [ "$cc" = bbr ]; then
    say "$(t bbr_already)"
    return 0
  fi
  bbr_available || die "$(t bbr_unsupported "$(uname -r)")"
  qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
  kv_set "$STATE/global.env" bbr_prev_cc "$cc"
  kv_set "$STATE/global.env" bbr_prev_qdisc "$qd"
  mkdir -p "$(dirname "$BBR_CONF")"
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >"$BBR_CONF"
  manifest_add file "$BBR_CONF"
  if ! testing; then
    # 队列规则设不上不影响 BBR 本身，所以不因它失败
    sysctl -qw net.core.default_qdisc=fq 2>/dev/null
    sysctl -qw net.ipv4.tcp_congestion_control=bbr 2>/dev/null
  fi
  if [ "$(bbr_cur)" != bbr ]; then
    # 共享内核的容器（OpenVZ、LXC）里常常不允许修改，这时由宿主机决定
    rm -f "$BBR_CONF"
    manifest_del file "$BBR_CONF"
    die "$(t bbr_denied)"
  fi
  say "${C_G}$(t bbr_on_done)${C_0}"
}

bbr_off() {
  local cc qd
  if ! bbr_ours; then
    say "$(t bbr_not_ours "$(bbr_cur)")"
    return 0
  fi
  cc=$(kv_get "$STATE/global.env" bbr_prev_cc cubic)
  qd=$(kv_get "$STATE/global.env" bbr_prev_qdisc)
  rm -f "$BBR_CONF"
  manifest_del file "$BBR_CONF"
  if ! testing; then
    sysctl -qw net.ipv4.tcp_congestion_control="$cc" 2>/dev/null
    [ -n "$qd" ] && sysctl -qw net.core.default_qdisc="$qd" 2>/dev/null
  fi
  say "$(t bbr_off_done "$cc")"
}

# pbox bbr [on|off|status]
cmd_bbr() {
  need_root
  need_installed
  case "${1:-status}" in
    on) bbr_on ;;
    off) bbr_off ;;
    status) say "$(t bbr_status "$(bbr_cur)")" ;;
    *) cmd_help ;;
  esac
}

# 默认网卡开机以来的收发流量。只读系统自带的计数，脚本不另外记录。
net_usage() {
  local dev
  dev=$(ip route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
  [ -n "$dev" ] || return 0
  awk -v d="$dev:" '
    function h(b) { if (b >= 1073741824) return sprintf("%.1fG", b / 1073741824); return sprintf("%dM", b / 1048576) }
    {sub(/:/, ": ")}
    $1 == d {printf "↑ %s  ↓ %s", h($10), h($2)}' /proc/net/dev 2>/dev/null
}
