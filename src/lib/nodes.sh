# 按节点地址模式列出要输出的地址，每行"标签|地址"。
# split：IPv4、IPv6 各一个节点；merged：一个域名节点；all：三者都输出。
node_hosts() {
  local mode ip4 ip6 dom
  mode=$(gget addr_mode split)
  ip4=$(gget ip4) ip6=$(gget ip6) dom=$(gget domain)
  if [ "$mode" != merged ]; then
    [ -n "$ip4" ] && echo "IPv4|$ip4"
    [ -n "$ip6" ] && echo "IPv6|$ip6"
  fi
  if [ "$mode" != split ] && [ -n "$dom" ]; then echo "$(t label_dual)|$dom"; fi
}

# 逐个节点回调：node_each <函数>，回调参数为 <协议> <用户> <地址> <节点名>
node_each() {
  local fn="$1" id u line label host name multi=0 region
  region=$(gget region)
  [ "$(users_list | wc -l)" -gt 1 ] && multi=1
  for id in $(protos_enabled); do
    for u in $(users_list); do
      node_hosts | while IFS= read -r line; do
        label="${line%%|*}" host="${line#*|}"
        name="$(pmeta "$id" short)-$label"
        [ -n "$region" ] && name="$region-$name"
        [ "$multi" = 1 ] && name="$name-$u"
        "$fn" "$id" "$u" "$host" "$name"
      done
    done
  done
}

_node_link() { pcall "$1" share_link "$2" "$3" "$4"; }
_node_link_insecure() { pcall "$1" share_link "$2" "$3" "$4" insecure; }
_node_sb() { pcall "$1" client_singbox "$2" "$3" "$4"; echo "@@"; }
_node_mh() { pcall "$1" client_mihomo "$2" "$3" "$4"; }
_node_name() { echo "$4"; }

# 所有客户端格式都在本机生成，不调用任何在线转换服务。
nodes_write() {
  local names sb tags="" n
  mkdir -p "$NODES"
  node_each _node_link >"$NODES/links.txt"
  names=$(node_each _node_name)
  for n in $names; do tags="$tags\"$n\", "; done
  tags="${tags%, }"
  # 各节点片段以 @@ 行分隔，这里换成 JSON 数组元素之间的逗号
  sb=$(node_each _node_sb | awk '/^@@$/{sep=1; next} {if(sep){print "    ,"; sep=0} print}')
  cat >"$NODES/sing-box.json" <<EOF
{
  "log": {"level": "warn"},
  "inbounds": [
    {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 2080}
  ],
  "outbounds": [
    {"type": "selector", "tag": "proxy", "outbounds": [$tags]},
$sb
    ,
    {"type": "direct", "tag": "direct"}
  ],
  "route": {"final": "proxy", "auto_detect_interface": true}
}
EOF
  {
    echo "mixed-port: 7890"
    echo "mode: rule"
    echo "ipv6: true"
    echo "proxies:"
    node_each _node_mh
    echo "proxy-groups:"
    echo "  - name: proxy"
    echo "    type: select"
    echo "    proxies:"
    for n in $names; do echo "      - \"$n\""; done
    echo "rules:"
    echo "  - MATCH,proxy"
  } >"$NODES/mihomo.yaml"
  testing || chmod 600 "$NODES"/*
}

nat_rules() {
  local id
  for id in $(protos_enabled); do
    hint "$(t nat_rule_line "$(pget "$id" port)" "$(pubport "$id")" "$(pmeta "$id" l4 | tr a-z A-Z)")"
  done
}

nodes_show() {
  local i=0 line insecure="${1:-}"
  head1 "$(t nodes_title)"
  while IFS= read -r line; do
    i=$((i + 1))
    printf '  %s%s%s\n  %s\n\n' "$C_B" "${line##*#}" "$C_0" "$line"
  done <"$NODES/links.txt"
  if [ "$insecure" = insecure ]; then
    note "$(t nodes_insecure_warn)"
    node_each _node_link_insecure | grep 'insecure=1' | sed 's/^/  /'
    say ""
  fi
  say "  $(t nodes_qr)        pbox qr"
  say "  $(t nodes_files)   ${NODES#"$R"}/"
  proto_enabled hysteria2 && say "  ${C_D}$(t nodes_pin_hint)${C_0}"
  say ""
  if [ "$(gget nat 0)" = 1 ]; then
    note "$(t nodes_nat)"
    nat_rules
  else
    note "$(t nodes_secgroup "$(ports_wanted | tr '\n' ' ')")"
  fi
}

# 二维码只在本机生成，节点链接不会发给任何在线服务。
nodes_qr() {
  local line
  has qrencode || die "$(t qr_missing)"
  while IFS= read -r line; do
    printf '\n  %s\n' "${line##*#}"
    printf '%s' "$line" | qrencode -t ANSIUTF8
  done <"$NODES/links.txt"
}
