# 连不上向导：体检只能说明服务器这一侧好不好，"从用户那里能不能连上"要用户自己测。
# 这里把后半段接上：给出一条在自己电脑上运行的命令，按结果判断是端口被封、IP 被墙
# 还是客户端的问题，再做对应的处理。判断依据见 docs/07-体检与排障.md 的"四种故障"。

# 客户端直连本机要用到的 TCP 端口
fix_tcp_ports() {
  local id
  {
    for id in $(protos_enabled); do
      [ "$(pmeta "$id" local)" = 1 ] && continue
      [ "$(pmeta "$id" l4)" = tcp ] && NODE_VIA="" pubport "$id"
      echo
    done
    site_on_p && echo 443
    relay_fwd_ports | sed -n 's#/tcp$##p'
  } | awk 'NF && !seen[$0]++'
}

# 一条命令测完所有端口，两种系统各一条
fix_show_test() { # <端口...>
  local ip
  ip=$(gget ip4)
  [ -n "$ip" ] || ip=$(gget ip6)
  say "$(t fix_test_intro)"
  say ""
  say "  Windows (PowerShell):"
  say "    $(echo "$*" | tr ' ' ',') | % { \"\$_ \$((Test-NetConnection $ip -Port \$_ -WarningAction SilentlyContinue).TcpTestSucceeded)\" }"
  say ""
  say "  macOS / Linux:"
  say "    for p in $*; do nc -vz -w 5 $ip \$p; done"
  say ""
  say "  ${C_D}$(t d_ext_udp)${C_0}"
  say ""
}

# 端口 <p> 不通：先排除安全组，再把用它的协议换到新端口
fix_port() { # <端口>
  local p="$1" id found=0
  valid_port "$p" || { warn "$(t bad_port "$p")"; return 0; }
  if site_on_p && [ "$p" = 443 ]; then
    note "$(t fix_port_site)"
    return 0
  fi
  for id in $(protos_enabled); do
    [ "$(pmeta "$id" local)" = 1 ] && continue
    [ "$(pmeta "$id" l4)" = tcp ] && [ "$(NODE_VIA="" pubport "$id")" = "$p" ] || continue
    found=1
    if [ "$(gget nat 0)" = 1 ]; then
      note "$(t fix_port_nat "$(pmeta "$id" title)" "$id")"
      continue
    fi
    confirm "$(t fix_port_q "$(pmeta "$id" title)" "$p")" n || continue
    (cmd_change "$id" port auto) && say "$(t fix_port_done "$(pmeta "$id" title)" "$(pget "$id" port)")"
  done
  [ $found = 1 ] || note "$(t fix_port_none "$p")"
}

# 所有端口都不通：多半是 IP 被墙。改用不经过本机 IP 的节点
fix_ip() {
  note "$(t fix_ip_ssh)"
  say ""
  if [ -n "$(gget cdn_host)" ] && { proto_enabled vless-wstls || proto_enabled vmess; }; then
    say "$(t fix_ip_cdn)"
  elif proto_enabled vless-ws; then
    say "$(t fix_ip_argo)"
  elif confirm "$(t fix_ip_argo_q)"; then
    (cmd_add vless-ws auto) && say "$(t fix_ip_argo)"
  fi
  say ""
  say "$(t fix_ip_more)"
}

# pbox fix
cmd_fix() {
  local ports p
  need_root
  need_installed
  detect_sys
  # 测试环境里没有真实的内核，体检结果没有意义
  if ! testing && ! cmd_doctor; then
    say "$(t fix_doctor_bad)"
    return 1
  fi
  ports=$(fix_tcp_ports | tr '\n' ' ')
  # shellcheck disable=SC2086
  fix_show_test $ports
  [ "$ASSUME_YES" = 1 ] && return 0
  say "$(t fix_ask)"
  printf ' %s: ' "$(t m_choose)"
  IFS= read -r REPLY || REPLY=0
  case "$REPLY" in
    1) say ""; say "$(t fix_client)" ;;
    2)
      say ""
      note "$(t fix_secgroup)"
      ask "$(t fix_ask_ports)" ""
      for p in $(printf '%s' "$REPLY" | tr ',' ' '); do fix_port "$p"; done
      ;;
    3) say ""; fix_ip ;;
  esac
  return 0
}
