# VLESS-Reality-XHTTP：同样借用一个真实网站的握手，传输方式换成 XHTTP，
# 流量形态更接近普通的网页请求。XHTTP 只有 Xray 实现，所以由 Xray 承载。
#
# Xray 的 Reality 服务端会拒绝 sing-box 和 Mihomo（Clash 系）客户端的握手，sing-box 也不支持 XHTTP，
# 所以这个节点只有通用链接，给 v2rayN、v2rayNG 这类用 Xray 的客户端；Clash 和 sing-box 的配置里没有它。
proto_reality_xhttp_meta() {
  case "$1" in
    title) echo "VLESS-Reality-XHTTP" ;;
    short) echo "XHTTP" ;;
    core) echo xray ;;
    l4) echo tcp ;;
    link_only) echo 1 ;;
    note) echo note_xhttp_clients ;;
  esac
}

proto_reality_xhttp_plan() {
  local p
  p=$(opt XHTTP_PORT)
  if [ -n "$p" ]; then
    valid_port "$p" || die "$(t bad_port "$p")"
  else
    p=$(pick_port tcp 8443 2053 2083 2087 2096) || return 1
  fi
  pset reality-xhttp port "$p"
  pset reality-xhttp path "/$(rand_str "$(rand_int 8 16)")"
}

proto_reality_xhttp_secrets() {
  local sni keys
  reality_sni_choose XHTTP_SNI
  sni=$REPLY
  keys=$(gen_reality_keypair) || die "$(t keygen_fail)"
  pset reality-xhttp sni "$sni"
  pset reality-xhttp private_key "$(printf '%s\n' "$keys" | sed -n 1p)"
  pset reality-xhttp public_key "$(printf '%s\n' "$keys" | sed -n 2p)"
  pset reality-xhttp short_id "$(rand_hex "$(rand_int 2 8)")"
}

proto_reality_xhttp_render_inbound() {
  local u users="" sep=""
  for u in $(proto_users reality-xhttp); do
    users="$users$sep{\"id\": \"$(uget "$u" uuid)\", \"email\": \"$u\"}"
    sep=", "
  done
  cat <<EOF
{
  "inbounds": [
    {
      "tag": "reality-xhttp",
      "listen": "$(listen_addr)",
      "port": $(pget reality-xhttp port),
      "protocol": "vless",
      "settings": {"clients": [$users], "decryption": "none"},
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {"path": "$(pget reality-xhttp path)"},
        "security": "reality",
        "realitySettings": {
          "target": "$(pget reality-xhttp sni):443",
          "serverNames": ["$(pget reality-xhttp sni)"],
          "privateKey": "$(pget reality-xhttp private_key)",
          "shortIds": ["$(pget reality-xhttp short_id)"]
        }
      }
    }
  ]
}
EOF
}

proto_reality_xhttp_share_link() {
  printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=xhttp&path=%s#%s\n' \
    "$(uget "$1" uuid)" "$(host_fmt "$2")" "$(pubport reality-xhttp)" "$(pget reality-xhttp sni)" \
    "$(fp_of reality-xhttp)" "$(pget reality-xhttp public_key)" "$(pget reality-xhttp short_id)" \
    "$(pget reality-xhttp path | sed 's#/#%2F#g')" "$3"
}

proto_reality_xhttp_client_singbox() { :; }
proto_reality_xhttp_client_mihomo() { :; }

# 自测只能用 Xray 自己当客户端
proto_reality_xhttp_selftest() {
  local d p u rc
  d=$(mktemp -d) p=$(random_port tcp) u=$(proto_users reality-xhttp | head -1)
  cat >"$d/c.json" <<EOF
{"log": {"loglevel": "none"},
 "inbounds": [{"listen": "127.0.0.1", "port": $p, "protocol": "socks", "settings": {"udp": false}}],
 "outbounds": [{"protocol": "vless",
  "settings": {"address": "127.0.0.1", "port": $(pget reality-xhttp port), "id": "$(uget "$u" uuid)", "encryption": "none"},
  "streamSettings": {"network": "xhttp", "xhttpSettings": {"path": "$(pget reality-xhttp path)"}, "security": "reality",
   "realitySettings": {"serverName": "$(pget reality-xhttp sni)", "fingerprint": "chrome",
    "password": "$(pget reality-xhttp public_key)", "shortId": "$(pget reality-xhttp short_id)"}}}]}
EOF
  selftest xray "$d/c.json" "$p"
  rc=$?
  rm -rf "$d"
  return $rc
}

proto_reality_xhttp_doctor() {
  if proto_reality_xhttp_selftest; then
    ok "$(t d_self_ok Reality-XHTTP)"
  else
    bad "$(t d_self_bad Reality-XHTTP)"
    hint "pbox log"
    return 1
  fi
  d_reality_target reality-xhttp d_reality_ok d_reality_bad
}
