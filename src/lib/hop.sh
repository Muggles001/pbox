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
hop_suffix() { local r; r=$(pget hysteria2 hop_range); [ -n "$r" ] && printf ',%s' "$r"; return 0; }
hop_singbox() { local r; r=$(pget hysteria2 hop_range); [ -n "$r" ] && printf '"server_ports": ["%s:%s"],' "${r%-*}" "${r#*-}"; return 0; }
hop_mihomo() { local r; r=$(pget hysteria2 hop_range); [ -n "$r" ] && printf 'ports: %s' "$r"; return 0; }

# pbox change hysteria2 hop <on|off|起-止>
hop_set() {
  local val="$1" a b w id p
  case "$val" in
    off)
      pset hysteria2 hop_range ""
      return 0
      ;;
    on | auto)
      # 起点和宽度都随机，避免所有用户用同一段端口
      a=$(rand_int 20000 50000)
      w=$(rand_int 500 1500)
      b=$((a + w))
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
  for id in $(protos_enabled); do
    [ "$(pmeta "$id" l4)" = udp ] || continue
    p=$(pget "$id" port)
    if [ "$p" -ge "$a" ] && [ "$p" -le "$b" ]; then
      txn_abort
      die "$(t hop_overlap "$a-$b" "$(pmeta "$id" title)" "$p")"
    fi
  done
  pset hysteria2 hop_range "$a-$b"
}
