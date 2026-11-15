# VLESS-Reality-gRPC：同样借用一个真实网站的握手，里面走 gRPC。
# 一条连接上可以并行多个请求，部分线路上比 Vision 稳；代价是多一层封装，速度略低，
# 也没有 Vision 那样消除"加密套加密"特征的处理。由 sing-box 承载，三类客户端都能用。
proto_reality_grpc_meta() {
  case "$1" in
    title) echo "VLESS-Reality-gRPC" ;;
    short) echo "gRPC" ;;
    core) echo singbox ;;
    l4) echo tcp ;;
  esac
}

proto_reality_grpc_plan() {
  local p
  p=$(opt GRPC_PORT)
  if [ -n "$p" ]; then
    valid_port "$p" || die "$(t bad_port "$p")"
  else
    p=$(pick_port tcp 8443 2053 2083 2087 2096) || return 1
  fi
  pset reality-grpc port "$p"
  # 服务名相当于路径，随机生成，免得所有机器都是同一个值
  pset reality-grpc service "$(rand_str "$(rand_int 8 16)")"
}

proto_reality_grpc_secrets() { reality_secrets reality-grpc GRPC_SNI; }

proto_reality_grpc_render_inbound() {
  local u users="" sep=""
  for u in $(proto_users reality-grpc); do
    users="$users$sep{\"name\": \"$u\", \"uuid\": \"$(uget "$u" uuid)\"}"
    sep=", "
  done
  cat <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "reality-grpc",
      "listen": "$(listen_addr)",
      "listen_port": $(pget reality-grpc port),
      "users": [$users],
      "tls": {
        "enabled": true,
        "server_name": "$(pget reality-grpc sni)",
        "reality": {
          "enabled": true,
          "handshake": {"server": "$(pget reality-grpc sni)", "server_port": 443},
          "private_key": "$(pget reality-grpc private_key)",
          "short_id": ["$(pget reality-grpc short_id)"]
        }
      },
      "transport": {"type": "grpc", "service_name": "$(pget reality-grpc service)"}
    }
  ]
}
EOF
}

proto_reality_grpc_share_link() {
  printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=grpc&serviceName=%s&mode=gun#%s\n' \
    "$(uget "$1" uuid)" "$(host_fmt "$2")" "$(pubport reality-grpc)" "$(pget reality-grpc sni)" \
    "$(fp_of reality-grpc)" "$(pget reality-grpc public_key)" "$(pget reality-grpc short_id)" "$(pget reality-grpc service)" "$3"
}

proto_reality_grpc_client_singbox() {
  cat <<EOF
    {
      "type": "vless",
      "tag": "$3",
      "server": "$2",
      "server_port": $(pubport reality-grpc),
      "uuid": "$(uget "$1" uuid)",
      "tls": {
        "enabled": true,
        "server_name": "$(pget reality-grpc sni)",
        "utls": {"enabled": true, "fingerprint": "$(fp_of reality-grpc)"},
        "reality": {"enabled": true, "public_key": "$(pget reality-grpc public_key)", "short_id": "$(pget reality-grpc short_id)"}
      },
      "transport": {"type": "grpc", "service_name": "$(pget reality-grpc service)"}
    }
EOF
}

proto_reality_grpc_client_mihomo() {
  cat <<EOF
  - name: "$3"
    type: vless
    server: "$2"
    port: $(pubport reality-grpc)
    uuid: "$(uget "$1" uuid)"
    network: grpc
    udp: true
    tls: true
    servername: "$(pget reality-grpc sni)"
    client-fingerprint: $(fp_of reality-grpc)
    reality-opts:
      public-key: "$(pget reality-grpc public_key)"
      short-id: "$(pget reality-grpc short_id)"
    grpc-opts:
      grpc-service-name: "$(pget reality-grpc service)"
EOF
}

proto_reality_grpc_selftest() { selftest_client reality-grpc; }

proto_reality_grpc_doctor() {
  doctor_selftest reality-grpc || return 1
  d_reality_target reality-grpc d_reality_ok d_reality_bad
}
