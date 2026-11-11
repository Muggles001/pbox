is_private4() {
  case "$1" in
    10.* | 192.168.* | 127.* | 169.254.*) return 0 ;;
    172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) return 0 ;;
    100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].*) return 0 ;;
  esac
  return 1
}

fetch() { curl -fsSL --proto '=https' --tlsv1.2 "$@"; }

# 优先读本机网卡。只有读到的是内网地址（NAT 机器）时才向外查询，并先告知。
detect_ips() {
  IP4="" IP6="" NAT4=0
  if testing; then
    IP4="${PBOX_TEST_IP4:-}" IP6="${PBOX_TEST_IP6:-}" NAT4="${PBOX_TEST_NAT:-0}"
    return 0
  fi
  if has ip; then
    IP4=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)
    IP6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | sed -n 's/.* src \([0-9a-fA-F:]*\).*/\1/p' | head -1)
  fi
  case "$IP6" in fe80:* | fc* | fd* | ::1) IP6="" ;; esac
  if [ -n "$IP4" ] && is_private4 "$IP4"; then
    NAT4=1
    note "$(t ip_external_note)"
    IP4=$(fetch -4 --max-time 6 https://one.one.one.one/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p')
  fi
  return 0
}

have_ipv6_stack() {
  testing && { [ -n "${PBOX_TEST_IP6:-}" ]; return; }
  [ -s /proc/net/if_inet6 ]
}

# 监听地址：有 IPv6 协议栈时用 ::（Linux 下同时接受 IPv4），否则只听 IPv4。
listen_addr() { if have_ipv6_stack; then echo "::"; else echo "0.0.0.0"; fi; }

# port_in_use <tcp|udp> <端口>
port_in_use() {
  local l4="$1" n="$2" f
  if testing; then
    case " ${PBOX_TEST_PORTS:-} " in *" $l4/$n "*) return 0 ;; esac
    return 1
  fi
  if has ss; then
    [ "$l4" = tcp ] && f=-lnt || f=-lnu
    ss -H "$f" 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$n\$"
  elif has netstat; then
    [ "$l4" = tcp ] && f=-lnt || f=-lnu
    netstat "$f" 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$n\$"
  else
    return 1
  fi
}

port_owner() {
  local l4="$1" n="$2" f
  has ss || return 0
  [ "$l4" = tcp ] && f=-lntp || f=-lnup
  ss -H "$f" 2>/dev/null | awk -v p=":$n" '$4 ~ p"$"' | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1
}

rand_int() { # <下限> <上限>，含两端
  local n
  n=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')
  echo $(($1 + n % ($2 - $1 + 1)))
}

rand_hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

rand_str() { # <长度>
  local s
  s=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$1")
  printf '%s' "$s"
}

gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    local h
    h=$(rand_hex 16)
    printf '%s-%s-4%s-a%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
  fi
}

random_port() { # <tcp|udp>
  local p i=0
  while [ $i -lt 50 ]; do
    p=$(rand_int 20000 59999)
    port_in_use "$1" "$p" || { echo "$p"; return 0; }
    i=$((i + 1))
  done
  return 1
}

# pick_port <tcp|udp> <候选...>：取第一个空闲的候选，都被占用则随机。
pick_port() {
  local l4="$1" p
  shift
  for p in "$@"; do
    port_in_use "$l4" "$p" || { echo "$p"; return 0; }
  done
  random_port "$l4"
}

valid_port() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_domain() { printf '%s' "$1" | grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$'; }

# resolve <A|AAAA> <域名>，每行输出一个地址
resolve() {
  local type="$1" d="$2"
  if testing; then
    [ "$type" = A ] && printf '%s\n' ${PBOX_TEST_DNS_A:-} || printf '%s\n' ${PBOX_TEST_DNS_AAAA:-}
  elif has dig; then
    dig +short "$type" "$d" 2>/dev/null | grep -E '^[0-9a-fA-F:.]+$'
  elif has getent; then
    if [ "$type" = A ]; then getent ahostsv4 "$d" | awk '{print $1}' | sort -u
    else getent ahostsv6 "$d" | awk '{print $1}' | grep -v '^::ffff:' | sort -u; fi
  elif has nslookup; then
    nslookup -type="$type" "$d" 2>/dev/null | awk '/^Address/ && NR>2 {print $NF}'
  fi
}

host_fmt() { case "$1" in *:*) printf '[%s]' "$1" ;; *) printf '%s' "$1" ;; esac; }
