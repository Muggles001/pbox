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
  while read -r l4 port; do
    if port_in_use "$l4" "$port"; then
      ok "$(t d_port_ok "$l4" "$port")"
    else
      bad "$(t d_port_bad "$l4" "$port")"
      rc=1
    fi
  done < <(
    for id in $(protos_enabled); do
      echo "$(pmeta "$id" l4) $(pget "$id" port)"
      [ "$(pmeta "$id" udp_too)" = 1 ] && echo "udp $(pget "$id" port)"
    done
    relay_fwd_ports | awk -F/ '{print $2, $1}'
  )
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

# 用给客户端的那份 sing-box 出站做自测，测的就是用户实际拿到的配置，协议模块不必再手写一份。
# 地址换成 <地址>（默认本机）；NAT 机器上给客户端的是外网端口，本机要连的是监听端口，
# 借经中转时的端口换算把它换回来
selftest_client() { # <协议> [地址] [握手里的名字]
  local d p u rc lp
  d=$(mktemp -d) p=$(random_port tcp) u=$(proto_users "$1" | head -1)
  if [ "$(pmeta "$1" behind)" = site ]; then lp=443; else lp=$(pget "$1" port); fi
  cat >"$d/c.json" <<EOF
{"log": {"disabled": true},
 "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": $p}],
 "outbounds": [
$(NODE_EXTRA="${3:-}" NODE_VIA="$(NODE_VIA="" pubport "$1")=$lp" pcall "$1" client_singbox "$u" "${2:-127.0.0.1}" selftest)
 ]}
EOF
  selftest singbox "$d/c.json" "$p"
  rc=$?
  rm -rf "$d"
  return $rc
}

# 多数协议的体检就是自测一次
doctor_selftest() { # <协议>
  if pcall "$1" selftest; then
    ok "$(t d_self_ok "$(pmeta "$1" title)")"
  else
    bad "$(t d_self_bad "$(pmeta "$1" title)")"
    return 1
  fi
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
  local report="${1:-}" pass=0 total=0 out fn id all
  need_installed
  out=$(mktemp)
  all="d_services d_config d_ports d_firewall d_dns d_time d_egress d_domain d_site d_cdn d_relay"
  for id in $(protos_enabled); do all="$all proto:$id"; done
  [ "$(kv_get "$STATE/outbound.env" warp off)" = on ] && all="$all d_warp"
  # 结果要等全部做完才一起显示，中间一分钟左右没有输出，所以报一下进度
  # shellcheck disable=SC2086
  set -- $all
  for fn in "$@"; do
    total=$((total + 1))
    spin_start "$(t spin_doctor "$total" "$#")"
    case "$fn" in
      proto:*) if pcall "${fn#proto:}" doctor >>"$out" 2>&1; then pass=$((pass + 1)); fi ;;
      *) if "$fn" >>"$out" 2>&1; then pass=$((pass + 1)); fi ;;
    esac
  done
  spin_stop
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

# 报告里要隐去的原文，每行"代号<TAB>原文"：本机地址、自己的域名、隧道、订阅仓库、中转的对端
_redact_relay() { printf '<relay>\t%s\n' "$2"; }
redact_words() {
  printf '<IPv4>\t%s\n' "$(gget ip4)"
  printf '<IPv6>\t%s\n' "$(gget ip6)"
  printf '<domain>\t%s\n' "$(gget domain)"
  printf '<domain>\t%s\n' "$(gget tls_domain)"
  printf '<cdn-domain>\t%s\n' "$(gget cdn_host)"
  printf '<argo-domain>\t%s\n' "$(pget vless-ws fixed_host)"
  printf '<argo-temp>\t%s\n' "$(pget vless-ws argo_host)"
  printf '<repo>\t%s\n' "$(sub_get project)"
  relay_each fwd _redact_relay
  relay_each via _redact_relay
}

# 求助用的报告。体检输出本身不含密钥，但有地址和域名。
# 长的先换：套 CDN 的子域名包含证书域名，先换短的会留下子域名的前缀。
# 列表之外的 IPv4（例如对端解析出的地址）也一律隐去，只留本机回环
doctor_redact() {
  local tag v exprs=()
  while IFS=$'\t' read -r tag v; do
    exprs+=(-e "s/$(printf '%s' "$v" | sed 's/[][\\.^$*+?(){}|/]/\\&/g')/$tag/g")
  done < <(redact_words | awk -F'\t' '$2 != "" && !seen[$2]++ {print length($2) "\t" $0}' | sort -rn | cut -f2-)
  sed -E "${exprs[@]}" -e 's/127\.0\.0\.1/@lo@/g' -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<IP>/g' -e 's/@lo@/127.0.0.1/g' \
    -e 's/\x1b\[[0-9;]*m//g'
  say "pbox $PBOX_VERSION · $(. /etc/os-release 2>/dev/null && echo "$ID $VERSION_ID") · $(uname -m)"
}
