proto_hysteria2_meta() {
  case "$1" in
    title) echo "Hysteria2" ;;
    short) echo "Hysteria2" ;;
    core) echo singbox ;;
    l4) echo udp ;;
  esac
}

# 伪装成 HTTP/3 的流量出现在 UDP 443 最自然；被占用才随机。
proto_hysteria2_plan() {
  local p
  p=$(opt HY2_PORT)
  if [ -n "$p" ]; then
    valid_port "$p" || die "$(t bad_port "$p")"
  else
    p=$(pick_port udp 443) || return 1
  fi
  pset hysteria2 port "$p"
}

proto_hysteria2_secrets() {
  local sni
  sni=$(random_sni)
  cert_selfsigned hysteria2 "$sni" || die "$(t cert_fail)"
  pset hysteria2 sni "$sni"
  pset hysteria2 cert_sha256 "$(cert_sha256 "$CERTS/hysteria2.crt")"
  pset hysteria2 cert_spki "$(cert_spki "$CERTS/hysteria2.crt")"
}

proto_hysteria2_render_inbound() {
  local u users="" sep="" certs="${CERTS#"$R"}"
  for u in $(users_list); do
    users="$users$sep{\"name\": \"$u\", \"password\": \"$(uget "$u" password)\"}"
    sep=", "
  done
  cat <<EOF
{
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "$(listen_addr)",
      "listen_port": $(pget hysteria2 port),
      "users": [$users],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$certs/hysteria2.crt",
        "key_path": "$certs/hysteria2.key"
      }
    }
  ]
}
EOF
}

# 自签证书配指纹固定。只有用户明确要求（第 4 个参数为 insecure）才输出跳过验证的链接。
proto_hysteria2_share_link() {
  local tail="pinSHA256=$(pget hysteria2 cert_sha256)"
  [ "${4:-}" = insecure ] && tail="insecure=1"
  printf 'hysteria2://%s@%s:%s/?sni=%s&%s#%s\n' \
    "$(uget "$1" password)" "$(host_fmt "$2")" "$(pubport hysteria2)" "$(pget hysteria2 sni)" "$tail" "$3"
}

proto_hysteria2_client_singbox() {
  cat <<EOF
    {
      "type": "hysteria2",
      "tag": "$3",
      "server": "$2",
      "server_port": $(pubport hysteria2),
      "password": "$(uget "$1" password)",
      "tls": {
        "enabled": true,
        "server_name": "$(pget hysteria2 sni)",
        "alpn": ["h3"],
        "certificate_public_key_sha256": ["$(pget hysteria2 cert_spki)"]
      }
    }
EOF
}

proto_hysteria2_client_mihomo() {
  cat <<EOF
  - name: "$3"
    type: hysteria2
    server: "$2"
    port: $(pubport hysteria2)
    password: "$(uget "$1" password)"
    sni: "$(pget hysteria2 sni)"
    alpn: [h3]
    fingerprint: "$(pget hysteria2 cert_sha256)"
EOF
}

proto_hysteria2_selftest() {
  local d p u rc
  d=$(mktemp -d) p=$(random_port tcp) u=$(users_list | head -1)
  cat >"$d/c.json" <<EOF
{"log": {"disabled": true},
 "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": $p}],
 "outbounds": [{"type": "hysteria2", "server": "127.0.0.1", "server_port": $(pget hysteria2 port),
  "password": "$(uget "$u" password)",
  "tls": {"enabled": true, "server_name": "$(pget hysteria2 sni)", "alpn": ["h3"],
   "certificate_public_key_sha256": ["$(pget hysteria2 cert_spki)"]}}]}
EOF
  selftest singbox "$d/c.json" "$p"
  rc=$?
  rm -rf "$d"
  return $rc
}

proto_hysteria2_doctor() {
  if proto_hysteria2_selftest; then
    ok "$(t d_self_ok Hysteria2)"
  else
    bad "$(t d_self_bad Hysteria2)"
    hint "pbox log"
    return 1
  fi
  if cert_valid_days "$CERTS/hysteria2.crt" 30; then
    ok "$(t d_cert_ok Hysteria2)"
  else
    bad "$(t d_cert_bad Hysteria2)"
    hint "pbox reset-keys"
    return 1
  fi
}
