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

# 精简节点列表：同一条路有优选节点时，不再列它的普通版本（"X-Pref" 取代 "X"）；
# 有 Argo 固定隧道时，不再列临时隧道（Fixed 取代 Temp）。体检不经过这里，仍逐个测试。
hosts_compact() {
  [ "$(gget compact_nodes 0)" = 1 ] || { cat; return 0; }
  awk -F'|' '{ line[NR] = $0; lab[NR] = $1; has[$1] = 1; if ($1 ~ /^Fixed/) fixed = 1 }
    END { for (i = 1; i <= NR; i++) {
      if (has[lab[i] "-Pref"]) continue
      if (fixed && lab[i] ~ /^Temp/) continue
      print line[i] } }'
}

# 逐个节点回调：node_each <函数>，回调参数为 <协议> <用户> <地址> <节点名>
node_each() {
  local fn="$1" id u line label host name multi=0 region
  region=$(gget region)
  # NODE_USER 非空时只输出那个用户的节点，节点名里也不必再带用户名
  [ -z "${NODE_USER:-}" ] && [ "$(users_list | wc -l)" -gt 1 ] && multi=1
  for id in $(protos_enabled); do
    for u in ${NODE_USER:-$(users_list)}; do
      user_has "$u" "$id" || continue
      if declare -F "proto_${id//-/_}_hosts" >/dev/null; then pcall "$id" hosts; else node_hosts; fi | hosts_compact | while IFS= read -r line; do
        label="${line%%|*}" host="${line#*|}"
        # 第三段是可选的附加信息，协议模块通过 NODE_EXTRA 读取
        NODE_EXTRA=""
        case "$host" in *"|"*) NODE_EXTRA="${host#*|}" host="${host%%|*}" ;; esac
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

# 把节点片段包成完整的客户端配置。片段与外壳分开，是因为订阅要把几台机器的片段合到一起。
# 出站片段里每个节点后面跟一行 @@，这里换成 JSON 数组元素之间的逗号。
wrap_singbox() { # <节点名文件> <出站片段文件>
  local tags="" n
  while IFS= read -r n; do [ -n "$n" ] && tags="$tags\"$n\", "; done <"$1"
  tags="${tags%, }"
  cat <<EOF
{
  "log": {"level": "warn"},
  "inbounds": [
    {"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 2080}
  ],
  "outbounds": [
    {"type": "selector", "tag": "proxy", "outbounds": [$tags]},
$(awk '/^@@$/{print "    ,"; next} {print}' "$2")
    {"type": "direct", "tag": "direct"}
  ],
  "route": {"final": "proxy", "auto_detect_interface": true}
}
EOF
}

wrap_mihomo() { # <节点名文件> <代理片段文件>
  local n
  echo "mixed-port: 7890"
  echo "mode: rule"
  echo "ipv6: true"
  echo "proxies:"
  cat "$2"
  echo "proxy-groups:"
  echo "  - name: proxy"
  echo "    type: select"
  echo "    proxies:"
  while IFS= read -r n; do [ -n "$n" ] && echo "      - \"$n\""; done <"$1"
  echo "rules:"
  echo "  - MATCH,proxy"
}

# 所有客户端格式都在本机生成，不调用任何在线转换服务。
# nodes_build <目录>：按当前的 NODE_USER 生成链接、片段和两种客户端配置
nodes_build() {
  local dir="$1"
  mkdir -p "$dir/parts"
  node_each _node_link >"$dir/links.txt"
  node_each _node_name >"$dir/parts/names"
  node_each _node_sb >"$dir/parts/singbox"
  node_each _node_mh >"$dir/parts/clash"
  wrap_singbox "$dir/parts/names" "$dir/parts/singbox" >"$dir/sing-box.json"
  wrap_mihomo "$dir/parts/names" "$dir/parts/clash" >"$dir/mihomo.yaml"
}

# 顶层是全部用户的节点；users/<名字>/ 下是每个人各自的一份，订阅按人生成
nodes_write() {
  local u
  NODE_USER=""
  nodes_build "$NODES"
  rm -rf "$NODES/users"
  for u in $(users_list); do
    NODE_USER="$u"
    nodes_build "$NODES/users/$u"
  done
  NODE_USER=""
  sub_build
  testing || find "$NODES" -type f -exec chmod 600 {} +
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
  [ "$(gget compact_nodes 0)" = 1 ] && say "  ${C_D}$(t nodes_compact_on)${C_0}"
  say "  $(t nodes_qr)        pbox qr"
  say "  $(t nodes_files)   ${NODES#"$R"}/"
  proto_enabled hysteria2 && ! tls_real && say "  ${C_D}$(t nodes_pin_hint)${C_0}"
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
