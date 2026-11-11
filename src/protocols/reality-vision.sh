proto_reality_vision_meta() {
  case "$1" in
    title) echo "VLESS-Reality-Vision" ;;
    short) echo "Reality" ;;
    core) echo xray ;;
    l4) echo tcp ;;
  esac
}

# 端口：443 最像正常网站；被占时先试其他常见的加密网页端口，都不行才随机。
proto_reality_vision_plan() {
  local p
  p=$(opt REALITY_PORT)
  if [ -n "$p" ]; then
    valid_port "$p" || die "$(t bad_port "$p")"
  else
    p=$(pick_port tcp 443 8443 2053 2083 2087 2096) || return 1
    [ "$p" = 443 ] || PLAN_NOTES="${PLAN_NOTES:-}$(t reality_port_note "$p")
"
  fi
  pset reality-vision port "$p"
}

proto_reality_vision_secrets() {
  local sni keys
  sni=$(opt REALITY_SNI)
  if [ -n "$sni" ]; then
    valid_domain "$sni" || die "$(t bad_domain "$sni")"
    reality_check "$sni" >/dev/null || die "$(t reality_bad_target "$sni")"
  else
    say "$(t reality_picking)"
    sni=$(reality_pick) || die "$(t reality_none)"
  fi
  keys=$(gen_reality_keypair) || die "$(t keygen_fail)"
  pset reality-vision sni "$sni"
  pset reality-vision private_key "$(printf '%s\n' "$keys" | sed -n 1p)"
  pset reality-vision public_key "$(printf '%s\n' "$keys" | sed -n 2p)"
  # 短标识的长度也随机：2 到 8 字节
  pset reality-vision short_id "$(rand_hex "$(rand_int 2 8)")"
}

proto_reality_vision_render_inbound() {
  local u clients="" sep=""
  for u in $(users_list); do
    clients="$clients$sep{\"id\": \"$(uget "$u" uuid)\", \"flow\": \"xtls-rprx-vision\", \"email\": \"$u\"}"
    sep=", "
  done
  cat <<EOF
{
  "inbounds": [
    {
      "tag": "reality-vision",
      "listen": "$(listen_addr)",
      "port": $(pget reality-vision port),
      "protocol": "vless",
      "settings": {"clients": [$clients], "decryption": "none"},
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$(pget reality-vision sni):443",
          "xver": 0,
          "serverNames": ["$(pget reality-vision sni)"],
          "privateKey": "$(pget reality-vision private_key)",
          "shortIds": ["$(pget reality-vision short_id)"]
        }
      }
    }
  ]
}
EOF
}

# share_link <用户> <主机> <节点名>
# 浏览器指纹固定用 chrome：它的作用是混进最大的人群，不该随机。
proto_reality_vision_share_link() {
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
    "$(uget "$1" uuid)" "$(host_fmt "$2")" "$(pubport reality-vision)" "$(pget reality-vision sni)" \
    "$(pget reality-vision public_key)" "$(pget reality-vision short_id)" "$3"
}

proto_reality_vision_client_singbox() {
  cat <<EOF
    {
      "type": "vless",
      "tag": "$3",
      "server": "$2",
      "server_port": $(pubport reality-vision),
      "uuid": "$(uget "$1" uuid)",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "$(pget reality-vision sni)",
        "utls": {"enabled": true, "fingerprint": "chrome"},
        "reality": {"enabled": true, "public_key": "$(pget reality-vision public_key)", "short_id": "$(pget reality-vision short_id)"}
      }
    }
EOF
}

proto_reality_vision_client_mihomo() {
  cat <<EOF
  - name: "$3"
    type: vless
    server: "$2"
    port: $(pubport reality-vision)
    uuid: "$(uget "$1" uuid)"
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: "$(pget reality-vision sni)"
    client-fingerprint: chrome
    reality-opts:
      public-key: "$(pget reality-vision public_key)"
      short-id: "$(pget reality-vision short_id)"
EOF
}

proto_reality_vision_selftest() {
  local d p u rc
  d=$(mktemp -d) p=$(random_port tcp) u=$(users_list | head -1)
  cat >"$d/c.json" <<EOF
{"log": {"loglevel": "none"},
 "inbounds": [{"listen": "127.0.0.1", "port": $p, "protocol": "socks"}],
 "outbounds": [{"protocol": "vless",
  "settings": {"vnext": [{"address": "127.0.0.1", "port": $(pget reality-vision port),
    "users": [{"id": "$(uget "$u" uuid)", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
  "streamSettings": {"network": "raw", "security": "reality", "realitySettings": {
    "serverName": "$(pget reality-vision sni)", "fingerprint": "chrome",
    "publicKey": "$(pget reality-vision public_key)", "shortId": "$(pget reality-vision short_id)"}}}]}
EOF
  selftest xray "$d/c.json" "$p"
  rc=$?
  rm -rf "$d"
  return $rc
}

proto_reality_vision_doctor() {
  local sni
  if proto_reality_vision_selftest; then
    ok "$(t d_self_ok Reality)"
  else
    bad "$(t d_self_bad Reality)"
    hint "pbox log"
    return 1
  fi
  sni=$(pget reality-vision sni)
  if reality_check "$sni" >/dev/null; then
    ok "$(t d_reality_ok "$sni")"
  else
    bad "$(t d_reality_bad "$sni")"
    hint "pbox change reality-vision sni auto"
    return 1
  fi
}

# Surge 不支持 VLESS
proto_reality_vision_client_surge() { :; }

# Quantumult X 的节点写法。未在真机上验证过。
proto_reality_vision_client_qx() {
  printf 'vless=%s:%s, method=none, password=%s, obfs=over-tls, obfs-host=%s, reality-base64-pubkey=%s, reality-hex-shortid=%s, vless-flow=xtls-rprx-vision, udp-relay=true, tag=%s\n' \
    "$(host_fmt "$2")" "$(pubport reality-vision)" "$(uget "$1" uuid)" "$(pget reality-vision sni)" \
    "$(pget reality-vision public_key)" "$(pget reality-vision short_id)" "$3"
}
