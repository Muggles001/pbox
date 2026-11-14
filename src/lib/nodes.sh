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

# 精简节点列表：只列推荐的协议，每个协议只列推荐的那一个节点。体检不经过这里，仍逐个测试。
compact_on() { [ "$(gget compact_nodes 0)" = 1 ]; }

# 精简时列哪些协议。用户自选过（compact_list）就用他选的；否则每种用途挑一个，
# 取这个用户能用的第一个：TCP 主力、UDP 提速、套 CDN 的 WS、Argo 隧道。
# Shadowsocks、ShadowTLS、SOCKS5 偏中转落地或较冷门，自动时不列。
# 一个都挑不到时（比如用户只能用 Shadowsocks）照常列出，免得他的列表是空的
compact_pick() { # <用户>
  local role id rec="" pick
  pick=$(gget compact_list)
  if [ -n "$pick" ]; then
    for id in $(protos_enabled); do
      case " $pick " in *" $id "*) user_has "$1" "$id" && rec="$rec $id" ;; esac
    done
  else
    for role in "reality-vision trojan anytls reality-xhttp" "hysteria2 tuic" "vless-wstls vmess" "vless-ws"; do
      for id in $role; do
        proto_enabled "$id" && user_has "$1" "$id" || continue
        # 没有套 CDN 时，伪装站上的 WS 是直连的，不算兜底
        case "$id" in vless-wstls | vmess) [ -n "$(gget cdn_host)" ] || continue ;; esac
        rec="$rec $id"
        break
      done
    done
  fi
  printf '%s' "${rec# }"
}

compact_listed() { # <协议> <用户>
  local rec
  compact_on || return 0
  rec=$(compact_pick "$2")
  [ -n "$rec" ] || return 0
  case " $rec " in *" $1 "*) return 0 ;; esac
  return 1
}

# 同一个协议的几个节点里挑一个：经 CDN 的优选 > 不经优选；
# 直连的经中转 > 域名 > IPv4 > IPv6，建了中转说明直连线路不好，所以中转优先。
# Argo 的固定隧道和临时隧道是两条独立的路，各留一个，都优先用优选
hosts_compact() {
  compact_on || { cat; return 0; }
  awk -F'|' -v dual="$(t label_dual)" '
    { l = $1; g = "all"
      if (l ~ /^Fixed/) g = "Fixed"; else if (l ~ /^Temp/) g = "Temp"
      if (l ~ /-Pref$/) s = 1
      else if (l == "CDN" || l == "Fixed" || l == "Temp") s = 2
      else if (l ~ /^Via-/) s = 5
      else if (l == dual) s = 6
      else if (l == "IPv4") s = 7
      else if (l == "IPv6") s = 8
      else s = 9
      if (!(g in best)) order[++n] = g
      if (!(g in best) || s < bs[g]) { best[g] = $0; bs[g] = s } }
    END { for (i = 1; i <= n; i++) print best[order[i]] }'
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
      compact_listed "$id" "$u" || continue
      {
        if declare -F "proto_${id//-/_}_hosts" >/dev/null; then pcall "$id" hosts; else node_hosts; fi
        relay_via_hosts "$id"
      } | hosts_compact | while IFS= read -r line; do
        label="${line%%|*}" host="${line#*|}"
        # 第三段是可选的附加信息，协议模块通过 NODE_EXTRA 读取；第四段是经中转时的端口对应关系
        NODE_EXTRA="" NODE_VIA=""
        case "$host" in *"|"*) NODE_EXTRA="${host#*|}" host="${host%%|*}" ;; esac
        case "$NODE_EXTRA" in *"|"*) NODE_VIA="${NODE_EXTRA#*|}" NODE_EXTRA="${NODE_EXTRA%%|*}" ;; esac
        name="$(pmeta "$id" short)-$label"
        [ -n "$region" ] && name="$region-$name"
        [ "$multi" = 1 ] && name="$name-$u"
        "$fn" "$id" "$u" "$host" "$name"
      done
    done
  done
}

# 有的协议只有通用链接（no_link 相反：只在 Clash 和 sing-box 配置里），节点名单跟着配置走
_node_link() { [ "$(pmeta "$1" no_link)" = 1 ] || pcall "$1" share_link "$2" "$3" "$4"; }
_node_link_insecure() { [ "$(pmeta "$1" no_link)" = 1 ] || pcall "$1" share_link "$2" "$3" "$4" insecure; }
_node_sb() { [ "$(pmeta "$1" link_only)" = 1 ] && return 0; pcall "$1" client_singbox "$2" "$3" "$4"; echo "@@"; }
_node_mh() { [ "$(pmeta "$1" link_only)" = 1 ] || pcall "$1" client_mihomo "$2" "$3" "$4"; }
_node_name() { [ "$(pmeta "$1" link_only)" = 1 ] || echo "$4"; }

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
  proto_enabled shadowtls && say "  ${C_D}$(t note_stls_nolink)${C_0}"
  proto_enabled reality-xhttp && say "  ${C_D}$(t note_xhttp_clients)${C_0}"
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
