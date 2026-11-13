# ShadowTLS v3：外面和一个真实网站完成 TLS 握手，外人看到的是访问那个网站；
# 握手里藏着用户的认证，认证通过后，同一条连接里跑的是 Shadowsocks 2022。
# 认证不通过的连接被原样转给那个网站。只有 TCP。
#
# 没有通用的分享链接写法，所以只出现在 Clash 和 sing-box 的配置里。
proto_shadowtls_meta() {
  case "$1" in
    title) echo "ShadowTLS" ;;
    short) echo "ShadowTLS" ;;
    core) echo singbox ;;
    l4) echo tcp ;;
    no_link) echo 1 ;;
    note) echo note_stls_nolink ;;
  esac
}

proto_shadowtls_plan() {
  local p
  p=$(opt STLS_PORT)
  if [ -n "$p" ]; then
    valid_port "$p" || die "$(t bad_port "$p")"
  else
    p=$(pick_port tcp 8443 2053 2083 2087 2096) || return 1
  fi
  pset shadowtls port "$p"
  # 里面那层 Shadowsocks 只监听本机
  pset shadowtls inner_port "$(random_port tcp)" || return 1
}

# 握手对象和 Reality 的伪装目标是同一类网站：要支持 TLS 1.3。直接用同一份实测过的名单。
proto_shadowtls_secrets() {
  local sni
  sni=$(opt STLS_SNI)
  if [ -n "$sni" ]; then
    valid_domain "$sni" || die "$(t bad_domain "$sni")"
    reality_check "$sni" >/dev/null || die "$(t reality_bad_target "$sni")"
  else
    say "$(t reality_picking)"
    sni=$(reality_pick) || die "$(t reality_none)"
  fi
  pset shadowtls sni "$sni"
  pset shadowtls psk "$(ss_new_key)"
}

proto_shadowtls_render_inbound() {
  local u users="" sep=""
  for u in $(proto_users shadowtls); do
    users="$users$sep{\"name\": \"$u\", \"password\": \"$(uget "$u" password)\"}"
    sep=", "
  done
  cat <<EOF
{
  "inbounds": [
    {
      "type": "shadowtls",
      "tag": "shadowtls",
      "listen": "$(listen_addr)",
      "listen_port": $(pget shadowtls port),
      "version": 3,
      "users": [$users],
      "handshake": {"server": "$(pget shadowtls sni)", "server_port": 443},
      "strict_mode": true,
      "detour": "shadowtls-ss"
    },
    {
      "type": "shadowsocks",
      "tag": "shadowtls-ss",
      "listen": "127.0.0.1",
      "listen_port": $(pget shadowtls inner_port),
      "network": "tcp",
      "method": "$SS_METHOD",
      "password": "$(pget shadowtls psk)",
      "users": [$(ss_users_json shadowtls)]
    }
  ]
}
EOF
}

proto_shadowtls_share_link() { :; }

# 两个出站：节点本身是 Shadowsocks，经由另一个 ShadowTLS 出站连到服务器
proto_shadowtls_client_singbox() {
  cat <<EOF
    {
      "type": "shadowsocks",
      "tag": "$3",
      "method": "$SS_METHOD",
      "password": "$(pget shadowtls psk):$(ss_user_key "$1")",
      "detour": "$3-tls"
    },
    {
      "type": "shadowtls",
      "tag": "$3-tls",
      "server": "$2",
      "server_port": $(pubport shadowtls),
      "version": 3,
      "password": "$(uget "$1" password)",
      "tls": {"enabled": true, "server_name": "$(pget shadowtls sni)", "utls": {"enabled": true, "fingerprint": "$(fp_of shadowtls)"}}
    }
EOF
}

proto_shadowtls_client_mihomo() {
  cat <<EOF
  - name: "$3"
    type: ss
    server: "$2"
    port: $(pubport shadowtls)
    cipher: $SS_METHOD
    password: "$(pget shadowtls psk):$(ss_user_key "$1")"
    plugin: shadow-tls
    client-fingerprint: $(fp_of shadowtls)
    plugin-opts:
      host: "$(pget shadowtls sni)"
      password: "$(uget "$1" password)"
      version: 3
EOF
}

proto_shadowtls_selftest() {
  local d p u rc
  d=$(mktemp -d) p=$(random_port tcp) u=$(proto_users shadowtls | head -1)
  cat >"$d/c.json" <<EOF
{"log": {"disabled": true},
 "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": $p}],
 "outbounds": [
  {"type": "shadowsocks", "method": "$SS_METHOD", "password": "$(pget shadowtls psk):$(ss_user_key "$u")", "detour": "stls"},
  {"type": "shadowtls", "tag": "stls", "server": "127.0.0.1", "server_port": $(pget shadowtls port), "version": 3,
   "password": "$(uget "$u" password)",
   "tls": {"enabled": true, "server_name": "$(pget shadowtls sni)", "utls": {"enabled": true, "fingerprint": "chrome"}}}]}
EOF
  selftest singbox "$d/c.json" "$p"
  rc=$?
  rm -rf "$d"
  return $rc
}

proto_shadowtls_doctor() {
  local sni
  if proto_shadowtls_selftest; then
    ok "$(t d_self_ok ShadowTLS)"
  else
    bad "$(t d_self_bad ShadowTLS)"
    return 1
  fi
  sni=$(pget shadowtls sni)
  if reality_check "$sni" >/dev/null || { sleep 2; reality_check "$sni" >/dev/null; }; then
    ok "$(t d_stls_target_ok "$sni")"
  else
    bad "$(t d_stls_target_bad "$sni")"
    hint "pbox change shadowtls sni auto"
    return 1
  fi
}
