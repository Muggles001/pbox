# AnyTLS：较新的 TCP 协议，着重消除"加密里面套加密"的流量特征。需要较新的客户端。
proto_anytls_meta() {
  case "$1" in
    title) echo "AnyTLS" ;;
    short) echo "AnyTLS" ;;
    core) echo singbox ;;
    l4) echo tcp ;;
    # 它的分享链接没有携带证书指纹的写法，所以通用链接只能跳过证书验证
    link_insecure) echo 1 ;;
  esac
}

proto_anytls_plan() {
  local p
  p=$(opt ANYTLS_PORT)
  if [ -n "$p" ]; then
    valid_port "$p" || die "$(t bad_port "$p")"
  else
    # 443 通常已被 Reality 占用，所以从其他常见的加密网页端口里选
    p=$(pick_port tcp 8443 2053 2083 2087 2096) || return 1
  fi
  pset anytls port "$p"
}

proto_anytls_secrets() {
  local sni
  sni=$(random_sni)
  cert_selfsigned anytls "$sni" || die "$(t cert_fail)"
  pset anytls sni "$sni"
  pset anytls cert_sha256 "$(cert_sha256 "$CERTS/anytls.crt")"
  pset anytls cert_spki "$(cert_spki "$CERTS/anytls.crt")"
}

proto_anytls_render_inbound() {
  local u users="" sep="" certs="${CERTS#"$R"}"
  for u in $(proto_users anytls); do
    users="$users$sep{\"name\": \"$u\", \"password\": \"$(uget "$u" password)\"}"
    sep=", "
  done
  cat <<EOF
{
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls",
      "listen": "$(listen_addr)",
      "listen_port": $(pget anytls port),
      "users": [$users],
      "tls": {
        "enabled": true,
        "certificate_path": "$certs/$(tls_name anytls).crt",
        "key_path": "$certs/$(tls_name anytls).key"
      }
    }
  ]
}
EOF
}

proto_anytls_share_link() {
  local ins="&insecure=1"
  tls_real && ins=""
  printf 'anytls://%s@%s:%s?security=tls&sni=%s%s#%s\n' \
    "$(uget "$1" password)" "$(host_fmt "$2")" "$(pubport anytls)" "$(tls_sni anytls)" "$ins" "$3"
}

proto_anytls_client_singbox() {
  cat <<EOF
    {
      "type": "anytls",
      "tag": "$3",
      "server": "$2",
      "server_port": $(pubport anytls),
      "password": "$(uget "$1" password)",
      "tls": {
        "enabled": true,
        "server_name": "$(tls_sni anytls)"$(tls_sb_pin anytls)
      }
    }
EOF
}

proto_anytls_client_mihomo() {
  cat <<EOF
  - name: "$3"
    type: anytls
    server: "$2"
    port: $(pubport anytls)
    password: "$(uget "$1" password)"
    udp: true
    client-fingerprint: chrome
    sni: "$(tls_sni anytls)"
    $(tls_mh_pin anytls)
EOF
}

proto_anytls_selftest() {
  local d p u rc
  d=$(mktemp -d) p=$(random_port tcp) u=$(proto_users anytls | head -1)
  cat >"$d/c.json" <<EOF
{"log": {"disabled": true},
 "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": $p}],
 "outbounds": [{"type": "anytls", "server": "127.0.0.1", "server_port": $(pget anytls port),
  "password": "$(uget "$u" password)",
  "tls": {"enabled": true, "server_name": "$(tls_sni anytls)",
   "certificate_public_key_sha256": ["$(tls_spki anytls)"]}}]}
EOF
  selftest singbox "$d/c.json" "$p"
  rc=$?
  rm -rf "$d"
  return $rc
}

proto_anytls_doctor() { doctor_selftest anytls; }
