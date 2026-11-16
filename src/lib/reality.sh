# 内置候选都是有大量正常访问的真实网站，这份名单公开不构成问题。
# 这 44 个都在 2026-11 实测通过：既满足下面的基本条件，也真的作为 Reality 目标完成过握手。是否可用仍以本机实测为准；可用 /etc/pbox/reality-candidates.txt 整份替换（每行一个域名）。
REALITY_CANDIDATES="www.cisco.com www.asus.com www.toyota.com www.adobe.com www.mozilla.org
www.python.org www.debian.org www.rakuten.co.jp www.yahoo.co.jp www.airbnb.com
www.nikon.com www.ricoh.com www.sharp.com www.yamaha.com www.docomo.ne.jp www.softbank.jp www.boeing.com
www.fedex.com www.ups.com www.walmart.com www.target.com www.nasa.gov www.kernel.org www.apache.org
www.postgresql.org www.mysql.com go.dev www.php.net www.ruby-lang.org www.docker.com www.jetbrains.com
www.atlassian.com www.dropbox.com www.wikipedia.org www.bbc.com www.nhk.or.jp www.nikkei.com www.ucla.edu
www.utoronto.ca www.ubc.ca www.nus.edu.sg www.ti.com www.arm.com www.westerndigital.com"

reality_candidates() {
  if [ -f "$ETC/reality-candidates.txt" ]; then
    grep -Ev '^[[:space:]]*(#|$)' "$ETC/reality-candidates.txt"
  else
    # shellcheck disable=SC2086
    printf '%s\n' $REALITY_CANDIDATES
  fi
}

shuffle() { awk -v s="$(rand_int 1 999999)" 'BEGIN{srand(s)} {print rand() "\t" $0}' | sort -n | cut -f2-; }

# reality_check <域名>：通过则输出 TCP 握手的耗时（秒），不含域名解析：解析时快时慢，会掩盖远近。
# 要求握手实际协商出 TLS 1.3 和 HTTP/2、证书校验通过、首页直接返回 200 而非跳转。
reality_check() {
  local d="$1" out res
  if testing; then echo "${PBOX_TEST_RTT:-0.05}"; return 0; fi
  out=$(echo | timeout 8 openssl s_client -connect "$d:443" -servername "$d" -tls1_3 -alpn h2 2>/dev/null) || return 1
  printf '%s' "$out" | grep -q 'TLSv1.3' || return 1
  printf '%s' "$out" | grep -q 'ALPN protocol: h2' || return 1
  printf '%s' "$out" | grep -q 'Verify return code: 0 ' || return 1
  res=$(curl -s -o /dev/null --max-time 8 -w '%{http_code} %{time_namelookup} %{time_connect}' "https://$d/") || return 1
  case "$res" in 200\ *) ;; *) return 1 ;; esac
  # 目标在 CDN 后面时，本机会被当成那家 CDN 的转发点。这里只能识别 Cloudflare 一家。
  curl -s --max-time 5 "https://$d/cdn-cgi/trace" 2>/dev/null | grep -q '^colo=' && return 1
  # 以上条件都满足的网站，仍有少数拿来做 Reality 目标时握手不成功（实测约十六分之一）。
  # 所以最后真的握手一次：通过了才算可用。
  if [ -x "$BINDIR/sing-box" ]; then reality_handshake_ok "$d" || return 1; fi
  echo "$res" | awk '{printf "%.3f\n", $3 - $2}'
}

# 在本机临时起一对 Reality 服务端和客户端，以 <域名> 为伪装目标，经由它实际访问一次外网。
reality_handshake_ok() {
  local sni="$1" d kp prv pub sp cp sport cport i rc=1
  d=$(mktemp -d) || return 1
  kp=$("$BINDIR/sing-box" generate reality-keypair 2>/dev/null)
  prv=$(printf '%s\n' "$kp" | sed -n 's/^PrivateKey: *//p')
  pub=$(printf '%s\n' "$kp" | sed -n 's/^PublicKey: *//p')
  sport=$(random_port tcp) cport=$(random_port tcp)
  cat >"$d/s.json" <<EOF
{"log": {"disabled": true},
 "inbounds": [{"type": "vless", "listen": "127.0.0.1", "listen_port": $sport,
  "users": [{"uuid": "00000000-0000-4000-8000-000000000001", "flow": "xtls-rprx-vision"}],
  "tls": {"enabled": true, "server_name": "$sni",
   "reality": {"enabled": true, "handshake": {"server": "$sni", "server_port": 443}, "private_key": "$prv", "short_id": ["ab12"]}}}],
 "outbounds": [{"type": "direct"}]}
EOF
  cat >"$d/c.json" <<EOF
{"log": {"disabled": true},
 "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": $cport}],
 "outbounds": [{"type": "vless", "server": "127.0.0.1", "server_port": $sport,
  "uuid": "00000000-0000-4000-8000-000000000001", "flow": "xtls-rprx-vision",
  "tls": {"enabled": true, "server_name": "$sni", "utls": {"enabled": true, "fingerprint": "chrome"},
   "reality": {"enabled": true, "public_key": "$pub", "short_id": "ab12"}}}]}
EOF
  "$BINDIR/sing-box" run -c "$d/s.json" -D "$d" >/dev/null 2>&1 &
  sp=$!
  "$BINDIR/sing-box" run -c "$d/c.json" -D "$d" >/dev/null 2>&1 &
  cp=$!
  for i in 1 2 3; do
    sleep 1
    if curl -s -o /dev/null -m 6 -x "socks5h://127.0.0.1:$cport" https://www.cloudflare.com/cdn-cgi/trace; then
      rc=0
      break
    fi
  done
  kill "$sp" "$cp" 2>/dev/null
  wait "$sp" "$cp" 2>/dev/null
  rm -rf "$d"
  return $rc
}

# S4：伪装目标要和服务器所在的网络相称。从服务器握手的耗时超过这个值（秒），
# 这个网站多半没有离服务器近的节点，比如东京的机器借用一个只在美国有服务器的网站。
# 在东京实测，有本地节点的都在 10 毫秒以内，没有的在 90 毫秒以上
REALITY_FAR=0.05
reality_far() { awk -v a="$1" -v b="$REALITY_FAR" 'BEGIN { exit !(a > b) }'; }
ms_of() { awk -v a="$1" 'BEGIN { printf "%d", a * 1000 }'; }

# 用户自己指定的目标太远时提醒。--yes 时只提醒：目标是点名给的，已经是明确的选择
reality_far_confirm() { # <域名> <连接耗时>
  reality_far "$2" || return 0
  warn "$(t s4_warn "$1" "$(ms_of "$2")")"
  [ "$ASSUME_YES" = 1 ] && return 0
  confirm_risk "$(t s_continue)"
}

# 随机顺序实测候选，凑够 5 个可用的就停，从最快的 3 个里随机取一个。
# 不设尝试上限：候选的通过率因机房而异，设了上限就会偶尔一个都挑不到。
reality_pick() {
  local d tm passed="" n=0 round pool
  if testing && [ -n "${PBOX_TEST_SNI:-}" ]; then echo "$PBOX_TEST_SNI"; return 0; fi
  # 网络一时抖动可能让整轮都测不过，所以一个都没挑到时再来一轮
  for round in 1 2; do
    for d in $(reality_candidates | shuffle); do
      tm=$(reality_check "$d") || continue
      passed="$passed$tm $d
"
      n=$((n + 1))
      [ "$n" -ge 5 ] && break
    done
    [ "$n" -gt 0 ] && break
    sleep 3
  done
  [ "$n" -gt 0 ] || return 1
  # 用 sed 取前几行而不是 head：head 读够就退出，会让前面的命令收到管道关闭的信号，
  # 在开启了 pipefail 的情况下整条管道会被判为失败，表现为偶发的"没有找到可用的伪装目标"
  # 有离得近的就只在近的里挑；都很远（服务器所在地区候选少）时才退而求其次
  pool=$(printf '%s' "$passed" | awk -v f="$REALITY_FAR" '$1 <= f')
  [ -n "$pool" ] || pool="$passed"
  printf '%s\n' "$pool" | sort -n | sed -n '1,3p' | shuffle | sed -n '1p' | awk '{print $2}'
}

# 自签证书用的域名：只需要像个正常域名，不需要实测。
random_sni() { reality_candidates | shuffle | sed -n '1p'; }

# 伪装目标（ShadowTLS 的握手对象同理）：用户指定的先验证，没指定就自动挑。结果在 REPLY
reality_sni_choose() { # <选项名，如 REALITY_SNI>
  local tm
  REPLY=$(opt "$1")
  if [ -n "$REPLY" ]; then
    valid_domain "$REPLY" || die "$(t bad_domain "$REPLY")"
    tm=$(reality_check "$REPLY") || die "$(t reality_bad_target "$REPLY")"
    reality_far_confirm "$REPLY" "$tm" || die "$(t cancelled)"
  else
    say "$(t reality_picking)"
    spin_start "$(t spin_wait)"
    REPLY=$(reality_pick) || die "$(t reality_none)"
    spin_stop
  fi
}

# 体检：协议 <id> 借用的那个网站还合不合用。
# 对外的探测偶尔会因为网络抖动失败一次，所以再试一次才下结论
d_reality_target() { # <协议> <通过的文案> <不通过的文案>
  local sni tm
  sni=$(pget "$1" sni)
  if tm=$(reality_check "$sni") || { sleep 2; tm=$(reality_check "$sni"); }; then
    ok "$(t "$2" "$sni")"
    # 太远只是不够自然，节点照常能用，所以只提醒
    if reality_far "$tm"; then
      note "$(t d_reality_far "$sni" "$(ms_of "$tm")")"
      hint "pbox change $1 sni auto"
    fi
  else
    bad "$(t "$3" "$sni")"
    hint "pbox change $1 sni auto"
    return 1
  fi
}

# Reality 系协议的初始密钥：伪装目标、密钥对、短标识
reality_secrets() { # <协议> <伪装目标的选项名>
  local keys
  reality_sni_choose "$2"
  keys=$(gen_reality_keypair) || die "$(t keygen_fail)"
  pset "$1" sni "$REPLY"
  pset "$1" private_key "$(printf '%s\n' "$keys" | sed -n 1p)"
  pset "$1" public_key "$(printf '%s\n' "$keys" | sed -n 2p)"
  # 短标识的长度也随机：2 到 8 字节
  pset "$1" short_id "$(rand_hex "$(rand_int 2 8)")"
}
