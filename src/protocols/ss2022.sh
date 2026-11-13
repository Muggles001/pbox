# Shadowsocks 2022：轻、快，同时走 TCP 和 UDP。流量是全随机字节，直接过墙容易被识别，
# 所以主要用于两台服务器之间的中转落地，或者放在 ShadowTLS 里面用。
#
# 每个用户有自己的密钥（2022 版的多用户写法）：客户端的密码是"服务器密钥:用户密钥"。
# 用户密钥不单独保存，由用户密码推出，重置用户时跟着变。
SS_METHOD="2022-blake3-aes-128-gcm"

ss_new_key() { head -c 16 /dev/urandom | openssl base64 -A; }
ss_user_key() { printf '%s' "$(uget "$1" password)" | openssl dgst -sha256 -binary | head -c 16 | openssl base64 -A; }

# 服务端的多用户列表；ShadowTLS 里面的那一层也用它
ss_users_json() { # <协议>
  local u users="" sep=""
  for u in $(proto_users "$1"); do
    users="$users$sep{\"name\": \"$u\", \"password\": \"$(ss_user_key "$u")\"}"
    sep=", "
  done
  printf '%s' "$users"
}

proto_ss2022_meta() {
  case "$1" in
    title) echo "Shadowsocks-2022" ;;
    short) echo "SS" ;;
    core) echo singbox ;;
    l4) echo tcp ;;
    # 同一个端口上 TCP 和 UDP 都用
    udp_too) echo 1 ;;
    note) echo note_ss_relay ;;
  esac
}

proto_ss2022_plan() {
  local p
  p=$(opt SS_PORT)
  if [ -n "$p" ]; then
    valid_port "$p" || die "$(t bad_port "$p")"
  else
    p=$(random_port tcp) || return 1
  fi
  pset ss2022 port "$p"
}

proto_ss2022_secrets() { pset ss2022 psk "$(ss_new_key)"; }

proto_ss2022_render_inbound() {
  cat <<EOF
{
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss2022",
      "listen": "$(listen_addr)",
      "listen_port": $(pget ss2022 port),
      "method": "$SS_METHOD",
      "password": "$(pget ss2022 psk)",
      "users": [$(ss_users_json ss2022)]
    }
  ]
}
EOF
}

proto_ss2022_share_link() {
  printf 'ss://%s@%s:%s#%s\n' \
    "$(printf '%s:%s:%s' "$SS_METHOD" "$(pget ss2022 psk)" "$(ss_user_key "$1")" | openssl base64 -A)" \
    "$(host_fmt "$2")" "$(pubport ss2022)" "$3"
}

proto_ss2022_client_singbox() {
  cat <<EOF
    {
      "type": "shadowsocks",
      "tag": "$3",
      "server": "$2",
      "server_port": $(pubport ss2022),
      "method": "$SS_METHOD",
      "password": "$(pget ss2022 psk):$(ss_user_key "$1")"
    }
EOF
}

proto_ss2022_client_mihomo() {
  cat <<EOF
  - name: "$3"
    type: ss
    server: "$2"
    port: $(pubport ss2022)
    cipher: $SS_METHOD
    password: "$(pget ss2022 psk):$(ss_user_key "$1")"
    udp: true
EOF
}

proto_ss2022_selftest() {
  local d p u rc
  d=$(mktemp -d) p=$(random_port tcp) u=$(proto_users ss2022 | head -1)
  cat >"$d/c.json" <<EOF
{"log": {"disabled": true},
 "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": $p}],
 "outbounds": [{"type": "shadowsocks", "server": "127.0.0.1", "server_port": $(pget ss2022 port),
  "method": "$SS_METHOD", "password": "$(pget ss2022 psk):$(ss_user_key "$u")"}]}
EOF
  selftest singbox "$d/c.json" "$p"
  rc=$?
  rm -rf "$d"
  return $rc
}

proto_ss2022_doctor() {
  if proto_ss2022_selftest; then
    ok "$(t d_self_ok Shadowsocks-2022)"
  else
    bad "$(t d_self_bad Shadowsocks-2022)"
    return 1
  fi
}
