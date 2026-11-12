# TUIC v5：基于 QUIC（UDP），特性与 Hysteria2 相近，作为另一个选择。
proto_tuic_meta() {
  case "$1" in
    title) echo "TUIC" ;;
    short) echo "TUIC" ;;
    core) echo singbox ;;
    l4) echo udp ;;
    # 它的分享链接没有携带证书指纹的写法，所以通用链接只能跳过证书验证
    link_insecure) echo 1 ;;
  esac
}

proto_tuic_plan() {
  local p
  p=$(opt TUIC_PORT)
  if [ -n "$p" ]; then
    valid_port "$p" || die "$(t bad_port "$p")"
  else
    p=$(pick_port udp 8443) || return 1
  fi
  pset tuic port "$p"
  pset tuic cc bbr
}

proto_tuic_secrets() {
  local sni
  sni=$(random_sni)
  cert_selfsigned tuic "$sni" || die "$(t cert_fail)"
  pset tuic sni "$sni"
  pset tuic cert_sha256 "$(cert_sha256 "$CERTS/tuic.crt")"
  pset tuic cert_spki "$(cert_spki "$CERTS/tuic.crt")"
}

proto_tuic_render_inbound() {
  local u users="" sep="" certs="${CERTS#"$R"}"
  for u in $(users_list); do
    users="$users$sep{\"name\": \"$u\", \"uuid\": \"$(uget "$u" uuid)\", \"password\": \"$(uget "$u" password)\"}"
    sep=", "
  done
  cat <<EOF
{
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "$(listen_addr)",
      "listen_port": $(pget tuic port),
      "users": [$users],
      "congestion_control": "$(pget tuic cc bbr)",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$certs/tuic.crt",
        "key_path": "$certs/tuic.key"
      }
    }
  ]
}
EOF
}

proto_tuic_share_link() {
  printf 'tuic://%s:%s@%s:%s?congestion_control=%s&udp_relay_mode=native&alpn=h3&sni=%s&allow_insecure=1#%s\n' \
    "$(uget "$1" uuid)" "$(uget "$1" password)" "$(host_fmt "$2")" "$(pubport tuic)" "$(pget tuic cc bbr)" "$(pget tuic sni)" "$3"
}

proto_tuic_client_singbox() {
  cat <<EOF
    {
      "type": "tuic",
      "tag": "$3",
      "server": "$2",
      "server_port": $(pubport tuic),
      "uuid": "$(uget "$1" uuid)",
      "password": "$(uget "$1" password)",
      "congestion_control": "$(pget tuic cc bbr)",
      "tls": {
        "enabled": true,
        "server_name": "$(pget tuic sni)",
        "alpn": ["h3"],
        "certificate_public_key_sha256": ["$(pget tuic cert_spki)"]
      }
    }
EOF
}

proto_tuic_client_mihomo() {
  cat <<EOF
  - name: "$3"
    type: tuic
    server: "$2"
    port: $(pubport tuic)
    uuid: "$(uget "$1" uuid)"
    password: "$(uget "$1" password)"
    alpn: [h3]
    udp-relay-mode: native
    congestion-controller: $(pget tuic cc bbr)
    sni: "$(pget tuic sni)"
    fingerprint: "$(pget tuic cert_sha256)"
EOF
}

proto_tuic_selftest() {
  local d p u rc
  d=$(mktemp -d) p=$(random_port tcp) u=$(users_list | head -1)
  cat >"$d/c.json" <<EOF
{"log": {"disabled": true},
 "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": $p}],
 "outbounds": [{"type": "tuic", "server": "127.0.0.1", "server_port": $(pget tuic port),
  "uuid": "$(uget "$u" uuid)", "password": "$(uget "$u" password)", "congestion_control": "$(pget tuic cc bbr)",
  "tls": {"enabled": true, "server_name": "$(pget tuic sni)", "alpn": ["h3"],
   "certificate_public_key_sha256": ["$(pget tuic cert_spki)"]}}]}
EOF
  selftest singbox "$d/c.json" "$p"
  rc=$?
  rm -rf "$d"
  return $rc
}

proto_tuic_doctor() {
  if proto_tuic_selftest; then
    ok "$(t d_self_ok TUIC)"
  else
    bad "$(t d_self_bad TUIC)"
    return 1
  fi
}
