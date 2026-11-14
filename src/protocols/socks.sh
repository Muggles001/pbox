# SOCKS5：不加密，用户名和密码都是明文。只适合给别的程序当落地，或者在服务器之间用，
# 不要直接从国内连。
#
# 用户名就是用户名；密码由用户密码推出、与之不同：它在线路上明文传输，
# 被看到了也不能拿去登录别的协议。重置用户时跟着变。
socks_pass() { printf 'socks:%s' "$(uget "$1" password)" | openssl dgst -sha256 | sed 's/.*= *//' | cut -c1-24; }

# 允许的来源：逗号分隔的 IP 或网段，空表示不限制
socks_allow_ok() {
  local a
  for a in $(printf '%s' "$1" | tr ',' ' '); do
    printf '%s' "$a" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$|^[0-9a-fA-F:]*:[0-9a-fA-F:]*(/[0-9]{1,3})?$' || return 1
  done
  [ -n "${1//,/}" ]
}

# 来源不在名单里的连接直接拒绝。本机自测从 127.0.0.1 发起，始终放行；
# 规则排在路由最前，免得先被别的规则放行
socks_allow_rule() {
  local a list=""
  proto_enabled socks || return 0
  [ -n "$(pget socks allow)" ] || return 0
  for a in $(pget socks allow | tr ',' ' ') 127.0.0.1/32 ::1/128; do
    case "$a" in */*) ;; *:*) a="$a/128" ;; *) a="$a/32" ;; esac
    list="$list${list:+, }\"$a\""
  done
  # invert 作用于整条规则，所以用 and 组合，只对来源取反
  printf '{"type": "logical", "mode": "and", "rules": [{"inbound": ["socks"]}, {"source_ip_cidr": [%s], "invert": true}], "action": "reject"}' "$list"
}

proto_socks_meta() {
  case "$1" in
    title) echo "SOCKS5" ;;
    short) echo "SOCKS5" ;;
    core) echo singbox ;;
    # UDP 转发时 sing-box 另开一个临时端口，没法固定，所以只放行 TCP。
    # 开着系统防火墙或在 NAT 机器上，UDP 转发不通
    l4) echo tcp ;;
    note) echo note_socks_plain ;;
  esac
}

proto_socks_plan() {
  local p
  p=$(opt SOCKS_PORT)
  if [ -n "$p" ]; then
    valid_port "$p" || die "$(t bad_port "$p")"
  else
    p=$(random_port tcp) || return 1
  fi
  pset socks port "$p"
}

proto_socks_secrets() { :; }

proto_socks_render_inbound() {
  local u users="" sep=""
  for u in $(proto_users socks); do
    users="$users$sep{\"username\": \"$u\", \"password\": \"$(socks_pass "$u")\"}"
    sep=", "
  done
  cat <<EOF
{
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks",
      "listen": "$(listen_addr)",
      "listen_port": $(pget socks port),
      "users": [$users]
    }
  ]
}
EOF
}

# v2rayN 的写法：用户名:密码 整体 base64
proto_socks_share_link() {
  printf 'socks://%s@%s:%s#%s\n' \
    "$(printf '%s:%s' "$1" "$(socks_pass "$1")" | openssl base64 -A)" \
    "$(host_fmt "$2")" "$(pubport socks)" "$3"
}

proto_socks_client_singbox() {
  cat <<EOF
    {
      "type": "socks",
      "tag": "$3",
      "server": "$2",
      "server_port": $(pubport socks),
      "version": "5",
      "username": "$1",
      "password": "$(socks_pass "$1")"
    }
EOF
}

proto_socks_client_mihomo() {
  cat <<EOF
  - name: "$3"
    type: socks5
    server: "$2"
    port: $(pubport socks)
    username: "$1"
    password: "$(socks_pass "$1")"
    udp: true
EOF
}

proto_socks_selftest() { selftest_client socks; }

proto_socks_doctor() { doctor_selftest socks; }
