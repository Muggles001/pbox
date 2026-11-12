# WARP 出口：让服务器访问指定网站（或全部网站）时改从 Cloudflare 的网络出去。
# 它解决的是"目标网站不欢迎这台 VPS 的 IP"，和客户端到服务器这一段无关。
#
# 直接调用 Cloudflare 的注册接口取得账户，写成 sing-box 自带的 WireGuard 出站。
# 不安装 WARP 客户端，不引入第三方注册程序；注册失败就报错，不使用任何共享的回退密钥。

oget() { kv_get "$CUR/outbound.env" "$1" "${2:-}"; }
oset() { kv_set "$CUR/outbound.env" "$1" "$2"; }

# 默认走 WARP 的站点：常见的会拒绝或反复验证机房 IP 的服务。用户可以整份替换。
WARP_DEFAULT_DOMAINS="openai.com,chatgpt.com,oaistatic.com,oaiusercontent.com,claude.ai,anthropic.com"

warp_on() { [ "$(oget warp off)" = on ]; }

# 注册一个免费账户，结果写进状态。失败返回非 0。
warp_register() {
  local kp priv pub r v4 v6 peer cid ep reserved
  if testing; then
    oset warp_private_key "TEST_WG_$(rand_hex 4)"
    oset warp_v4 172.16.0.2
    oset warp_v6 "2606:4700:110::$(rand_hex 2)"
    oset warp_peer_key TEST_PEER
    oset warp_endpoint 162.159.192.1
    oset warp_reserved "1,2,3"
    return 0
  fi
  kp=$("$BINDIR/sing-box" generate wg-keypair 2>/dev/null) || return 1
  priv=$(printf '%s\n' "$kp" | sed -n 's/^PrivateKey: *//p')
  pub=$(printf '%s\n' "$kp" | sed -n 's/^PublicKey: *//p')
  [ -n "$priv" ] && [ -n "$pub" ] || return 1
  r=$(curl -s --max-time 20 -X POST https://api.cloudflareclient.com/v0a2158/reg \
    -H 'User-Agent: okhttp/3.12.1' -H 'CF-Client-Version: a-6.10-2158' -H 'Content-Type: application/json' \
    -d "{\"key\":\"$pub\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"model\":\"PC\",\"serial_number\":\"\",\"locale\":\"en_US\"}") || return 1
  v4=$(printf '%s' "$r" | grep -o '"v4":"[0-9.]*"' | head -1 | cut -d'"' -f4)
  v6=$(printf '%s' "$r" | grep -o '"v6":"[0-9a-fA-F:]*"' | head -1 | cut -d'"' -f4)
  peer=$(printf '%s' "$r" | grep -o '"public_key":"[^"]*"' | head -1 | cut -d'"' -f4)
  cid=$(printf '%s' "$r" | grep -o '"client_id":"[^"]*"' | head -1 | cut -d'"' -f4)
  # 对端地址直接用接口返回的 IP，省去内核再做一次域名解析
  ep=$(printf '%s' "$r" | grep -o '"v4":"[0-9.]*:[0-9]*"' | head -1 | cut -d'"' -f4 | cut -d: -f1)
  [ -n "$v4" ] && [ -n "$peer" ] && [ -n "$cid" ] && [ -n "$ep" ] || return 1
  # client_id 解码后的三个字节，是 Cloudflare 用来识别账户的保留字段
  reserved=$(printf '%s' "$cid" | openssl base64 -d -A 2>/dev/null | od -An -tu1 | tr -s ' ' ',' | sed 's/^,//; s/,$//')
  oset warp_private_key "$priv"
  oset warp_v4 "$v4"
  oset warp_v6 "$v6"
  oset warp_peer_key "$peer"
  oset warp_endpoint "$ep"
  oset warp_reserved "$reserved"
}

# 以下三个函数输出 sing-box 基础配置里的片段，由 render.sh 拼进去
warp_endpoint_json() {
  local addr
  warp_on || return 0
  addr="\"$(oget warp_v4)/32\""
  [ -n "$(oget warp_v6)" ] && addr="$addr, \"$(oget warp_v6)/128\""
  cat <<EOF

  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp",
      "address": [$addr],
      "private_key": "$(oget warp_private_key)",
      "peers": [
        {
          "address": "$(oget warp_endpoint)",
          "port": 2408,
          "public_key": "$(oget warp_peer_key)",
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "reserved": [$(oget warp_reserved)]
        }
      ]
    }
  ],
EOF
}

warp_rules_json() {
  local d list="" sep=""
  warp_on || return 0
  [ "$(oget warp_mode domains)" = domains ] || return 0
  for d in $(oget warp_domains "$WARP_DEFAULT_DOMAINS" | tr ',' ' '); do
    list="$list$sep\"$d\""
    sep=", "
  done
  # 先嗅探出域名：客户端可能只发来 IP，嗅探后才能按域名分流
  printf '{"action": "sniff"}, {"domain_suffix": [%s], "outbound": "warp"}' "$list"
}

warp_final_json() {
  warp_on || return 0
  [ "$(oget warp_mode domains)" = all ] && printf ',\n    "final": "warp"'
  return 0
}

warp_status() {
  if warp_on; then
    if [ "$(oget warp_mode domains)" = all ]; then
      say "$(t warp_st_all)"
    else
      say "$(t warp_st_domains "$(oget warp_domains "$WARP_DEFAULT_DOMAINS")")"
    fi
  else
    say "$(t warp_st_off)"
  fi
}

# pbox warp <on|off|all|domains [列表]|status|test>
cmd_warp() {
  local act="${1:-status}" val="${2:-}" d
  if [ "$act" = status ]; then
    need_root
    need_installed
    warp_status
    return 0
  fi
  if [ "$act" = test ]; then
    need_root
    need_installed
    detect_sys
    warp_status
    [ "$(kv_get "$STATE/outbound.env" warp off)" = on ] && d_warp
    return
  fi
  edit_begin
  case "$act" in
    on)
      if [ -z "$(oget warp_private_key)" ]; then
        say "$(t warp_registering)"
        warp_register || { txn_abort; die "$(t warp_reg_fail)"; }
      fi
      oset warp on
      [ -n "$(oget warp_mode)" ] || oset warp_mode domains
      ;;
    off) oset warp off ;;
    all)
      warp_on || { txn_abort; die "$(t warp_need_on)"; }
      oset warp_mode all
      ;;
    domains)
      warp_on || { txn_abort; die "$(t warp_need_on)"; }
      if [ "$val" = default ]; then
        oset warp_domains ""
      elif [ -n "$val" ]; then
        val=$(printf '%s' "$val" | tr -d ' ' | tr 'A-Z' 'a-z')
        for d in $(printf '%s' "$val" | tr ',' ' '); do
          valid_domain "$d" || { txn_abort; die "$(t bad_domain "$d")"; }
        done
        oset warp_domains "$val"
      fi
      oset warp_mode domains
      ;;
    *)
      txn_abort
      die "$(t warp_usage)"
      ;;
  esac
  edit_end
  warp_status
}

# 验证 WARP 是否真的在起作用。办法是经由节点去取 Cloudflare 的探测页，页面里有一行 warp=on 或 warp=off。
# 全部模式：取 Cloudflare 自己的探测页。
# 按网站模式：很多网站本身就托管在 Cloudflare 上，同样带这个探测页，所以逐个去取分流名单里的网站，
# 取到的那一个若显示 warp=on，就证明"这个网站确实走了 WARP"。
d_warp() {
  local id out d seen=""
  [ "$(kv_get "$STATE/outbound.env" warp off)" = on ] || return 0
  id=$(protos_enabled | head -1)
  out=$(mktemp)
  if [ "$(kv_get "$STATE/outbound.env" warp_mode domains)" = all ]; then
    SELFTEST_OUT="$out" pcall "$id" selftest
    if grep -Eq '^warp=(on|plus)' "$out"; then
      ok "$(t d_warp_ok)"
      warp_show_exit "$out"
      rm -f "$out"
      return 0
    fi
    rm -f "$out"
    bad "$(t d_warp_bad)"
    hint "pbox warp off"
    return 1
  fi
  for d in $(kv_get "$STATE/outbound.env" warp_domains "$WARP_DEFAULT_DOMAINS" | tr ',' ' '); do
    : >"$out"
    SELFTEST_URL="https://$d/cdn-cgi/trace" SELFTEST_OUT="$out" pcall "$id" selftest >/dev/null 2>&1
    grep -q '^warp=' "$out" || continue
    seen="$d"
    break
  done
  if [ -z "$seen" ]; then
    rm -f "$out"
    note "$(t d_warp_unknown)"
    return 0
  fi
  if grep -Eq '^warp=(on|plus)' "$out"; then
    ok "$(t d_warp_site_ok "$seen")"
    warp_show_exit "$out"
    rm -f "$out"
    return 0
  fi
  rm -f "$out"
  bad "$(t d_warp_site_bad "$seen")"
  return 1
}

# 把经由 WARP 看到的出口地区和服务器自己的地区并排显示，一眼能看出有没有换出口
warp_show_exit() {
  local loc
  loc=$(sed -n 's/^loc=//p' "$1" | head -1)
  [ -n "$loc" ] && hint "$(t d_warp_exit "$loc" "$(kv_get "$STATE/global.env" region -)")"
  return 0
}
