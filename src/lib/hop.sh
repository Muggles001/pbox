# Hysteria2 端口跳跃：把一段 UDP 端口的流量转给 Hysteria2 实际监听的端口。
# 规则放在自己的表里或带上自己的标记，清理时只动自己的，不碰系统原有规则。
# 开机后由 pbox-hop 服务重新加上，不安装任何规则持久化组件。

hop_range() { kv_get "$STATE/protocols/hysteria2.env" hop_range; }

hop_clear() {
  local tool r
  testing && return 0
  has nft && nft delete table inet pbox_hop 2>/dev/null
  for tool in iptables ip6tables; do
    has "$tool" || continue
    "$tool" -t nat -S PREROUTING 2>/dev/null | grep -- '--comment pbox-hop' | while read -r r; do
      # shellcheck disable=SC2086
      "$tool" -t nat ${r/-A/-D} 2>/dev/null
    done
  done
  return 0
}

hop_active() {
  if has nft && nft list table inet pbox_hop >/dev/null 2>&1; then return 0; fi
  has iptables && iptables -t nat -S PREROUTING 2>/dev/null | grep -q -- '--comment pbox-hop'
}

hop_unit() { # <on|off>
  local f=/etc/systemd/system/pbox-hop.service
  [ "$INIT" = systemd ] || return 0
  if [ "$1" = off ]; then
    [ -f "$f" ] && svc_remove pbox-hop
    return 0
  fi
  cat >"$f" <<EOF
[Unit]
Description=pbox port hopping rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$LIBDIR/pbox.sh hop-apply

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable pbox-hop >/dev/null 2>&1
  manifest_add svc pbox-hop
  manifest_add file "$f"
}

# 按当前状态重建规则。每次改动生效后、以及每次开机时调用。
hop_apply() {
  local range port a b
  testing && return 0
  hop_clear
  range=$(hop_range)
  if [ -z "$range" ]; then
    hop_unit off
    return 0
  fi
  port=$(kv_get "$STATE/protocols/hysteria2.env" port)
  a=${range%-*} b=${range#*-}
  if has nft; then
    nft -f - <<EOF || return 1
table inet pbox_hop {
  chain prerouting {
    type nat hook prerouting priority -100; policy accept;
    udp dport $a-$b redirect to :$port
  }
}
EOF
  elif has iptables; then
    iptables -t nat -A PREROUTING -p udp --dport "$a:$b" -m comment --comment pbox-hop -j REDIRECT --to-ports "$port" || return 1
    if has ip6tables && [ -s /proc/net/if_inet6 ]; then
      ip6tables -t nat -A PREROUTING -p udp --dport "$a:$b" -m comment --comment pbox-hop -j REDIRECT --to-ports "$port" 2>/dev/null
    fi
  else
    return 1
  fi
  manifest_add hop rules
  hop_unit on
}

# 写进分享链接和客户端配置的片段
# 链接里用 mport 参数表示跳跃范围：v2rayNG 等常见客户端认这种写法。
# Hysteria 官方的"端口,范围"写法它们会判为无效配置；不认 mport 的客户端会忽略它，仍可用主端口连接。
hop_query() { local r; r=$(pget hysteria2 hop_range); [ -n "$r" ] && printf '&mport=%s' "$r"; return 0; }
hop_singbox() { local r; r=$(pget hysteria2 hop_range); [ -n "$r" ] && printf '"server_ports": ["%s:%s"],' "${r%-*}" "${r#*-}"; return 0; }
hop_mihomo() { local r; r=$(pget hysteria2 hop_range); [ -n "$r" ] && printf 'ports: %s' "$r"; return 0; }

# hop_overlaps <起> <止>：范围里若有某个 UDP 协议的端口，输出那个协议并返回 0
hop_overlaps() {
  local id p
  for id in $(protos_enabled); do
    [ "$(pmeta "$id" l4)" = udp ] || continue
    p=$(pget "$id" port)
    if [ "$p" -ge "$1" ] && [ "$p" -le "$2" ]; then
      echo "$id"
      return 0
    fi
  done
  return 1
}

# pbox change hysteria2 hop <on|off|起-止>
hop_set() {
  local val="$1" a b w id n
  case "$val" in
    off)
      pset hysteria2 hop_range ""
      return 0
      ;;
    on | auto)
      # 起点和宽度都随机，避免所有用户用同一段端口。撞上已有的 UDP 端口就重选。
      n=0
      while :; do
        a=$(rand_int 20000 50000)
        w=$(rand_int 500 1500)
        b=$((a + w))
        hop_overlaps "$a" "$b" >/dev/null || break
        n=$((n + 1))
        [ "$n" -ge 30 ] && break
      done
      ;;
    *-*)
      a=${val%-*} b=${val#*-}
      valid_port "$a" && valid_port "$b" && [ "$a" -lt "$b" ] || { txn_abort; die "$(t hop_bad)"; }
      ;;
    *)
      txn_abort
      die "$(t hop_bad)"
      ;;
  esac
  [ "$(gget nat 0)" = 1 ] && { txn_abort; die "$(t hop_nat)"; }
  testing || has nft || has iptables || { txn_abort; die "$(t hop_no_tool)"; }
  # H3：跳跃范围不能盖住其他 UDP 协议或它自己的监听端口
  if id=$(hop_overlaps "$a" "$b"); then
    txn_abort
    die "$(t hop_overlap "$a-$b" "$(pmeta "$id" title)" "$(pget "$id" port)")"
  fi
  pset hysteria2 hop_range "$a-$b"
}
