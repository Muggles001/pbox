# 临时调试日志：平时内核几乎不记日志（不留客户端地址），排查连不上时临时打开详细日志。
# 状态里只记到期时间。渲染配置时按它决定日志级别，所以到期后任何一次重新渲染都会恢复；
# 定时检查负责在没人操作时按时关掉，关闭时清空日志，期间记下的地址和网站不留在机器上
DEBUG_MAX=240

now_s() { printf '%s' "${PBOX_TEST_NOW:-$(date +%s)}"; }

# 剩余分钟数，向上取整；没开或已到期时失败
debug_left() {
  local u n
  u=$(gget debug_until) n=$(now_s)
  [ -n "$u" ] && [ "$u" -gt "$n" ] || return 1
  echo $(((u - n + 59) / 60))
}

debug_on() { debug_left >/dev/null; }

# 开着时每隔几分钟检查一次是否到期。用周期检查而不是到点触发一次：
# 关机错过、或到点时正好有别的操作占着锁，下一次检查都会补上
debug_timer() { # <on|off>
  local f
  testing && return 0
  if [ "$INIT" = systemd ]; then
    if [ "$1" = off ]; then
      systemctl disable --now pbox-debug.timer >/dev/null 2>&1
      for f in /etc/systemd/system/pbox-debug.service /etc/systemd/system/pbox-debug.timer; do
        [ -f "$f" ] && rm -f "$f" && manifest_del file "$f"
      done
      systemctl daemon-reload
      return 0
    fi
    cat >/etc/systemd/system/pbox-debug.service <<EOF
[Unit]
Description=pbox debug log expiry check

[Service]
Type=oneshot
ExecStart=$(exec_prefix)$LIBDIR/pbox.sh debug check
EOF
    cat >/etc/systemd/system/pbox-debug.timer <<EOF
[Unit]
Description=pbox debug log expiry check

[Timer]
OnCalendar=*:0/5

[Install]
WantedBy=timers.target
EOF
    manifest_add file /etc/systemd/system/pbox-debug.service
    manifest_add file /etc/systemd/system/pbox-debug.timer
    systemctl daemon-reload
    systemctl enable --now pbox-debug.timer >/dev/null 2>&1
  else
    f=/etc/periodic/15min/pbox-debug
    if [ "$1" = off ]; then
      [ -f "$f" ] && rm -f "$f" && manifest_del file "$f"
      return 0
    fi
    mkdir -p /etc/periodic/15min
    printf '#!/bin/sh\nexec %s debug check\n' "$LIBDIR/pbox.sh" >"$f"
    chmod 755 "$f"
    manifest_add file "$f"
    rc-service crond status >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1
  fi
}

debug_stop() {
  local f
  edit_begin
  gset debug_until ""
  edit_end same
  [ "$DRY_RUN" = 1 ] && return 0
  debug_timer off
  # 只有两个内核会记连接；证书、隧道的日志与调试无关，留着
  for f in "$LOGDIR/$(core_svc singbox).log" "$LOGDIR/$(core_svc xray).log"; do [ -f "$f" ] && : >"$f"; done
  say "$(t debug_off)"
}

cmd_debug() {
  local m="${2:-30}"
  case "${1:-}" in
    "")
      need_root
      need_installed
      if m=$(debug_left); then say "$(t debug_state_on "$m")"; else say "$(t debug_state_off)"; fi
      ;;
    on)
      case "$m" in '' | *[!0-9]*) die "$(t debug_usage "$DEBUG_MAX")" ;; esac
      [ "$m" -ge 1 ] && [ "$m" -le "$DEBUG_MAX" ] || die "$(t debug_usage "$DEBUG_MAX")"
      edit_begin
      gset debug_until $(($(now_s) + m * 60))
      edit_end same
      [ "$DRY_RUN" = 1 ] && return 0
      debug_timer on
      note "$(t debug_started "$m")"
      ;;
    off) debug_stop ;;
    check)
      need_root
      need_installed
      [ -n "$(gget debug_until)" ] || { detect_sys; debug_timer off; return 0; }
      debug_on || debug_stop
      ;;
    *) die "$(t debug_usage "$DEBUG_MAX")" ;;
  esac
}
