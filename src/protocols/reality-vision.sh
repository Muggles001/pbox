proto_reality_vision_meta() {
  case "$1" in
    title) echo "VLESS-Reality-Vision" ;;
    short) echo "Reality" ;;
    # 由 sing-box 承载。Xray 自 v26.7.11 起收紧了 Reality 握手，会拒绝 sing-box 与 Mihomo（Clash 系）客户端；
    # 实测 sing-box 的 Reality 服务端同时接受 Xray、sing-box 两种客户端。
    core) echo singbox ;;
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
  local u users="" sep=""
  for u in $(proto_users reality-vision); do
    users="$users$sep{\"name\": \"$u\", \"uuid\": \"$(uget "$u" uuid)\", \"flow\": \"xtls-rprx-vision\"}"
    sep=", "
  done
  cat <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "reality-vision",
      "listen": "$(listen_addr)",
      "listen_port": $(pget reality-vision port),
      "users": [$users],
      "tls": {
        "enabled": true,
        "server_name": "$(pget reality-vision sni)",
        "reality": {
          "enabled": true,
          "handshake": {"server": "$(pget reality-vision sni)", "server_port": 443},
          "private_key": "$(pget reality-vision private_key)",
          "short_id": ["$(pget reality-vision short_id)"]
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
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=tcp#%s\n' \
    "$(uget "$1" uuid)" "$(host_fmt "$2")" "$(pubport reality-vision)" "$(pget reality-vision sni)" \
    "$(fp_of reality-vision)" "$(pget reality-vision public_key)" "$(pget reality-vision short_id)" "$3"
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
        "utls": {"enabled": true, "fingerprint": "$(fp_of reality-vision)"},
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
    client-fingerprint: $(fp_of reality-vision)
    reality-opts:
      public-key: "$(pget reality-vision public_key)"
      short-id: "$(pget reality-vision short_id)"
EOF
}

proto_reality_vision_selftest() {
  local d p u rc
  d=$(mktemp -d) p=$(random_port tcp) u=$(proto_users reality-vision | head -1)
  cat >"$d/c.json" <<EOF
{"log": {"disabled": true},
 "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": $p}],
 "outbounds": [{"type": "vless", "server": "127.0.0.1", "server_port": $(pget reality-vision port),
  "uuid": "$(uget "$u" uuid)", "flow": "xtls-rprx-vision",
  "tls": {"enabled": true, "server_name": "$(pget reality-vision sni)",
   "utls": {"enabled": true, "fingerprint": "$(fp_of reality-vision)"},
   "reality": {"enabled": true, "public_key": "$(pget reality-vision public_key)", "short_id": "$(pget reality-vision short_id)"}}}]}
EOF
  selftest singbox "$d/c.json" "$p"
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
  # 对外的探测偶尔会因为网络抖动失败一次，所以再试一次才下结论
  if reality_check "$sni" >/dev/null || { sleep 2; reality_check "$sni" >/dev/null; }; then
    ok "$(t d_reality_ok "$sni")"
  else
    bad "$(t d_reality_bad "$sni")"
    hint "pbox change reality-vision sni auto"
    return 1
  fi
}
