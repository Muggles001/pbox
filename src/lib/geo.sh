# 屏蔽回国流量要知道哪些域名和 IP 属于中国大陆。这份数据每天都在变，内核也不自带，
# 所以只在用户开启时才下载，放在内核程序旁边（Xray 默认就在那里找），之后随 pbox update 更新。
# 两个内核的格式不同，各取一份：sing-box 用 SagerNet 的规则集，Xray 用 v2fly 的数据文件。
GEO_FILES="geoip-cn.srs|https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs
geosite-cn.srs|https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs
geoip-cn.dat|https://github.com/v2fly/geoip/releases/latest/download/cn.dat
geosite-cn.dat|https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"

block_cn_on() { [ "$(gget block_cn 0)" = 1 ]; }

geo_ready() {
  local line
  while IFS= read -r line; do [ -s "$BINDIR/${line%%|*}" ] || return 1; done <<<"$GEO_FILES"
}

# 四个文件都下载成功才替换，免得两个内核用的数据新旧不一；失败时原来的文件不动
geo_fetch() {
  local tmp line f
  mkdir -p "$BINDIR"
  if testing; then
    while IFS= read -r line; do echo test >"$BINDIR/${line%%|*}"; done <<<"$GEO_FILES"
    return 0
  fi
  tmp=$(mktemp -d) || return 1
  while IFS= read -r line; do
    f="${line%%|*}"
    # 太小的多半是报错页面而不是数据
    if ! fetch --max-time 120 -o "$tmp/$f" "${line#*|}" || [ "$(wc -c <"$tmp/$f")" -lt 10000 ]; then
      rm -rf "$tmp"
      return 1
    fi
  done <<<"$GEO_FILES"
  while IFS= read -r line; do install -m 0644 "$tmp/${line%%|*}" "$BINDIR/${line%%|*}"; done <<<"$GEO_FILES"
  rm -rf "$tmp"
}

# pbox set block-cn <on|off> 的主体，调用方已经开了事务
geo_block_set() {
  case "$1" in
    on)
      say "$(t geo_fetching)"
      spin_start "$(t spin_wait)"
      geo_fetch || { txn_abort; die "$(t geo_fail)"; }
      spin_stop
      gset block_cn 1
      ;;
    off) gset block_cn 0 ;;
    *) txn_abort; die "$(t set_usage)" ;;
  esac
}
