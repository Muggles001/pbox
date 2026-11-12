# 内置候选都是有大量正常访问的真实网站，这份名单公开不构成问题。
# 这 47 个都在 2026-11 实测通过过筛选（美国与日本的机房各测过一部分）。是否可用仍以本机实测为准；可用 /etc/pbox/reality-candidates.txt 整份替换（每行一个域名）。
REALITY_CANDIDATES="www.cisco.com www.asus.com www.toyota.com www.bosch.com www.adobe.com www.mozilla.org
www.python.org www.debian.org www.rakuten.co.jp www.yahoo.co.jp www.airbnb.com
www.nikon.com www.ricoh.com www.sharp.com www.yamaha.com www.docomo.ne.jp www.softbank.jp www.boeing.com
www.fedex.com www.ups.com www.walmart.com www.target.com www.nasa.gov www.kernel.org www.apache.org
www.postgresql.org www.mysql.com go.dev www.php.net www.ruby-lang.org www.docker.com www.jetbrains.com
www.atlassian.com www.dropbox.com www.wikipedia.org www.bbc.com www.nhk.or.jp www.nikkei.com www.ucla.edu
www.utoronto.ca www.ubc.ca www.nus.edu.sg www.kth.se www.ti.com www.arm.com www.micron.com www.westerndigital.com"

reality_candidates() {
  if [ -f "$ETC/reality-candidates.txt" ]; then
    grep -Ev '^[[:space:]]*(#|$)' "$ETC/reality-candidates.txt"
  else
    # shellcheck disable=SC2086
    printf '%s\n' $REALITY_CANDIDATES
  fi
}

shuffle() { awk -v s="$(rand_int 1 999999)" 'BEGIN{srand(s)} {print rand() "\t" $0}' | sort -n | cut -f2-; }

# reality_check <域名>：通过则输出连接耗时（秒）。
# 要求握手实际协商出 TLS 1.3 和 HTTP/2、证书校验通过、首页直接返回 200 而非跳转。
reality_check() {
  local d="$1" out res
  if testing; then echo 0.05; return 0; fi
  out=$(echo | timeout 8 openssl s_client -connect "$d:443" -servername "$d" -tls1_3 -alpn h2 2>/dev/null) || return 1
  printf '%s' "$out" | grep -q 'TLSv1.3' || return 1
  printf '%s' "$out" | grep -q 'ALPN protocol: h2' || return 1
  printf '%s' "$out" | grep -q 'Verify return code: 0 ' || return 1
  res=$(curl -s -o /dev/null --max-time 8 -w '%{http_code} %{time_connect}' "https://$d/") || return 1
  case "$res" in 200\ *) ;; *) return 1 ;; esac
  # 目标在 CDN 后面时，本机会被当成那家 CDN 的转发点。这里只能识别 Cloudflare 一家。
  curl -s --max-time 5 "https://$d/cdn-cgi/trace" 2>/dev/null | grep -q '^colo=' && return 1
  echo "${res#* }"
}

# 随机顺序实测候选，凑够 5 个可用的就停，从最快的 3 个里随机取一个。
# 不设尝试上限：候选的通过率因机房而异，设了上限就会偶尔一个都挑不到。
reality_pick() {
  local d tm passed="" n=0 round
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
  printf '%s' "$passed" | sort -n | head -3 | shuffle | head -1 | awk '{print $2}'
}

# 自签证书用的域名：只需要像个正常域名，不需要实测。
random_sni() { reality_candidates | shuffle | head -1; }
