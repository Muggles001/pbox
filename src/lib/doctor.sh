d_services() {
  local core rc=0
  for core in $(cores_needed); do
    if svc active "$(core_svc "$core")"; then
      ok "$(t d_svc_ok "$(core_title "$core")")"
    else
      bad "$(t d_svc_bad "$(core_title "$core")")"
      hint "pbox log    pbox rollback"
      rc=1
    fi
  done
  return $rc
}

d_config() {
  if validate_all "$GEN" 2>/dev/null; then
    ok "$(t d_config_ok)"
  else
    bad "$(t d_config_bad)"
    hint "pbox rollback"
    return 1
  fi
}

d_ports() {
  local id rc=0 l4 port
  for id in $(protos_enabled); do
    l4=$(pmeta "$id" l4) port=$(pget "$id" port)
    if port_in_use "$l4" "$port"; then
      ok "$(t d_port_ok "$l4" "$port")"
    else
      bad "$(t d_port_bad "$l4" "$port")"
      rc=1
    fi
  done
  return $rc
}

d_firewall() {
  local be p rc=0
  be=$(fw_backend)
  if [ "$be" = none ]; then
    note "$(t d_fw_none)"
    return 0
  fi
  for p in $(ports_wanted); do
    if fw_is_open "$be" "$p"; then
      ok "$(t d_fw_ok "$be" "$p")"
    else
      bad "$(t d_fw_bad "$be" "$p")"
      hint "pbox firewall"
      rc=1
    fi
  done
  return $rc
}

# 需要联网：取一个公共网站响应头里的时间来比对。解析不了就跳过，不算失败。
d_time() {
  local remote rs now diff
  remote=$(curl -sI --max-time 5 https://www.cloudflare.com 2>/dev/null | tr -d '\r' | sed -n 's/^[Dd]ate: //p')
  rs=$(date -u -d "$remote" +%s 2>/dev/null) || rs=""
  if [ -z "$remote" ] || [ -z "$rs" ]; then
    note "$(t d_time_skip)"
    return 0
  fi
  now=$(date -u +%s)
  diff=$((now - rs))
  [ "$diff" -lt 0 ] && diff=$((-diff))
  if [ "$diff" -le 60 ]; then
    ok "$(t d_time_ok)"
  else
    bad "$(t d_time_bad "$diff")"
    hint "$(t d_time_hint)"
    return 1
  fi
}

d_egress() {
  local rc=0 v
  for v in 4 6; do
    [ -n "$(gget "ip$v")" ] || continue
    if curl -"$v" -s -o /dev/null --max-time 6 https://www.cloudflare.com/cdn-cgi/trace; then
      ok "$(t d_egress_ok "$v")"
    else
      bad "$(t d_egress_bad "$v")"
      rc=1
    fi
  done
  return $rc
}

d_dns() {
  if runuser_reads_dns; then
    ok "$(t d_dns_ok)"
  elif [ "$INIT" = systemd ] && [ -f "$ETC/resolv.conf" ]; then
    ok "$(t d_dns_bound)"
  else
    bad "$(t d_dns_bad)"
    hint "chmod 644 /etc/resolv.conf"
    return 1
  fi
}

# 节点自测：在本机临时起一个客户端，经由节点访问一次外网。
# 端口在监听、配置合法，都不等于节点能用；只有真的走通一次才算数。
# selftest <内核> <客户端配置文件> <本地端口>
selftest() {
  local b pid rc=1
  b=$(core_bin "$1")
  case "$1" in
    xray) "$b" run -c "$2" >/dev/null 2>&1 & ;;
    singbox) "$b" run -c "$2" -D "$(dirname "$2")" >/dev/null 2>&1 & ;;
  esac
  pid=$!
  # 内核刚重启时可能还没准备好，所以最多试三次，而不是一次失败就判定节点坏了
  for _ in 1 2 3; do
    sleep 2
    if curl -s -o "${SELFTEST_OUT:-/dev/null}" -m 10 -x "socks5h://127.0.0.1:$3" "${SELFTEST_URL:-https://www.cloudflare.com/cdn-cgi/trace}"; then
      rc=0
      break
    fi
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return $rc
}

d_resources() {
  local mem disk
  mem=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
  disk=$(df -Pm "$ETC" 2>/dev/null | awk 'NR==2 {print $4}')
  if [ -n "$mem" ] && [ "$mem" -lt 40 ]; then note "$(t d_mem_low "$mem")"; fi
  if [ -n "$disk" ] && [ "$disk" -lt 200 ]; then note "$(t d_disk_low "$disk")"; fi
  return 0
}

# 只提醒，不改动 SSH 设置。
d_ssh() {
  has sshd || return 0
  if sshd -T 2>/dev/null | grep -qi '^passwordauthentication yes'; then note "$(t d_ssh_pw)"; fi
  return 0
}

# 服务器无法判断"从用户家里能否连上"，所以生成一条可在用户自己电脑上运行的检测命令。
d_external() {
  local ip tcp="" id
  ip=$(gget ip4)
  [ -z "$ip" ] && ip=$(gget ip6)
  for id in $(protos_enabled); do
    [ "$(pmeta "$id" local)" = 1 ] && continue
    [ "$(pmeta "$id" l4)" = tcp ] && tcp="$tcp $(pubport "$id")"
  done
  note "$(t d_ext_title)"
  for id in $tcp; do
    hint "Windows:  Test-NetConnection $ip -Port $id"
    hint "macOS / Linux:  nc -vz $ip $id"
  done
  hint "$(t d_ext_udp)"
}

cmd_doctor() {
  local report="${1:-}" pass=0 total=0 out fn id
  need_installed
  out=$(mktemp)
  for fn in d_services d_config d_ports d_firewall d_dns d_time d_egress d_domain; do
    total=$((total + 1))
    if "$fn" >>"$out" 2>&1; then pass=$((pass + 1)); fi
  done
  for id in $(protos_enabled); do
    total=$((total + 1))
    if pcall "$id" doctor >>"$out" 2>&1; then pass=$((pass + 1)); fi
  done
  if [ "$(kv_get "$STATE/outbound.env" warp off)" = on ]; then
    total=$((total + 1))
    if d_warp >>"$out" 2>&1; then pass=$((pass + 1)); fi
  fi
  d_resources >>"$out"
  d_ssh >>"$out"
  d_external >>"$out"
  {
    head1 "$(t d_title "$pass" "$total")"
    cat "$out"
    say ""
  } | if [ "$report" = --report ]; then doctor_redact; else cat; fi
  rm -f "$out"
  [ "$pass" = "$total" ]
}

# 求助用的报告：隐去 IP 和域名。体检输出本身不含密钥。
doctor_redact() {
  local ip4 ip6 dom
  ip4=$(gget ip4) ip6=$(gget ip6) dom=$(gget domain)
  sed -e "s/${ip4:-@@none@@}/<IPv4>/g" -e "s/${ip6:-@@none@@}/<IPv6>/g" -e "s/${dom:-@@none@@}/<domain>/g" \
    -e 's/\x1b\[[0-9;]*m//g'
  say "pbox $PBOX_VERSION · $(. /etc/os-release 2>/dev/null && echo "$ID $VERSION_ID") · $(uname -m)"
}
