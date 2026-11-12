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
  for u in $(proto_users hysteria2); do
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
      "users": [$users],$(hy2_obfs_json)
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$certs/$(tls_name hysteria2).crt",
        "key_path": "$certs/$(tls_name hysteria2).key"
      }
    }
  ]
}
EOF
}

# Salamander 混淆（进阶，默认关闭）：把流量打乱成看不出是 QUIC 的样子，用于 QUIC 本身被针对的网络。
# 代价是流量不再像 HTTP/3，所以它和"伪装成 HTTP/3"是二选一。
hy2_obfs_json() {
  local pw
  pw=$(pget hysteria2 obfs_password)
  [ -n "$pw" ] && printf '\n      "obfs": {"type": "salamander", "password": "%s"},' "$pw"
  return 0
}
hy2_obfs_query() {
  local pw
  pw=$(pget hysteria2 obfs_password)
  [ -n "$pw" ] && printf '&obfs=salamander&obfs-password=%s' "$pw"
  return 0
}
hy2_obfs_mihomo() {
  local pw
  pw=$(pget hysteria2 obfs_password)
  [ -n "$pw" ] && printf 'obfs: salamander\n    obfs-password: "%s"' "$pw"
  return 0
}

# 自签证书配指纹固定，只有用户明确要求（第 4 个参数为 insecure）才输出跳过验证的链接；
# 有正规证书时两者都不需要。
proto_hysteria2_share_link() {
  local tail="&pinSHA256=$(pget hysteria2 cert_sha256)"
  [ "${4:-}" = insecure ] && tail="&insecure=1"
  tls_real && tail=""
  tail="$tail$(hop_query)$(hy2_obfs_query)"
  printf 'hysteria2://%s@%s:%s/?sni=%s%s#%s\n' \
    "$(uget "$1" password)" "$(host_fmt "$2")" "$(pubport hysteria2)" "$(tls_sni hysteria2)" "$tail" "$3"
}

proto_hysteria2_client_singbox() {
  cat <<EOF
    {
      "type": "hysteria2",
      "tag": "$3",
      "server": "$2",
      "server_port": $(pubport hysteria2),
      $(hop_singbox)
      "password": "$(uget "$1" password)",$(hy2_obfs_json)
      "tls": {
        "enabled": true,
        "server_name": "$(tls_sni hysteria2)",
        "alpn": ["h3"]$(tls_sb_pin hysteria2)
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
    $(hop_mihomo)
    $(hy2_obfs_mihomo)
    password: "$(uget "$1" password)"
    sni: "$(tls_sni hysteria2)"
    alpn: [h3]
    $(tls_mh_pin hysteria2)
EOF
}

proto_hysteria2_selftest() {
  local d p u rc
  d=$(mktemp -d) p=$(random_port tcp) u=$(proto_users hysteria2 | head -1)
  cat >"$d/c.json" <<EOF
{"log": {"disabled": true},
 "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": $p}],
 "outbounds": [{"type": "hysteria2", "server": "127.0.0.1", "server_port": $(pget hysteria2 port),
  "password": "$(uget "$u" password)",$(hy2_obfs_json)
  "tls": {"enabled": true, "server_name": "$(tls_sni hysteria2)", "alpn": ["h3"],
   "certificate_public_key_sha256": ["$(tls_spki hysteria2)"]}}]}
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
  if [ -n "$(pget hysteria2 hop_range)" ]; then
    if hop_active; then
      ok "$(t d_hop_ok "$(pget hysteria2 hop_range)")"
    else
      bad "$(t d_hop_bad)"
      hint "pbox hop-apply"
      return 1
    fi
  fi
  tls_real && return 0
  if cert_valid_days "$CERTS/hysteria2.crt" 30; then
    ok "$(t d_cert_ok Hysteria2)"
  else
    bad "$(t d_cert_bad Hysteria2)"
    hint "pbox reset-keys"
    return 1
  fi
}
