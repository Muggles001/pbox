# 链式中转：客户端 → 中转机 → 落地机，出口是落地机。
# 中转机只做端口转发（sing-box 的 direct 入站，把 TCP、UDP 原样转给落地机），不解密，
# 也不需要知道落地机上跑的是什么协议，Reality 的握手和证书指纹因此原样到达落地机。
# 落地机记下中转机的地址和端口对应关系，给每个直连本机的节点多输出一个"经中转"的版本。
#
# 两边的记录都在 relay.env：
#   中转机  fwd_<键>=<名字> <落地机地址> <本机端口>=<落地机端口>/<tcp|udp|tcp+udp> ...
#   落地机  via_<键>=<名字> <中转机地址> <本机端口>=<中转机端口> ...
# 两边交换的"中转码"是这些信息的 base64，只有地址和端口，没有任何凭据。

rget() { kv_get "$CUR/relay.env" "$1" "${2:-}"; }
rset() { kv_set "$CUR/relay.env" "$1" "$2"; }
rdel() {
  [ -f "$CUR/relay.env" ] || return 0
  grep -v "^$1=" "$CUR/relay.env" >"$CUR/relay.env.tmp"
  mv "$CUR/relay.env.tmp" "$CUR/relay.env"
}
relay_keys() { [ -f "$CUR/relay.env" ] && sed -n "s/^\($1_[a-z0-9_]*\)=.*/\1/p" "$CUR/relay.env"; return 0; }
relay_key() { printf '%s_%s' "$1" "$(printf '%s' "$2" | tr 'A-Z-' 'a-z_')"; }
relay_fwd_any() { [ -n "$(relay_keys fwd)" ]; }

relay_encode() { printf '%s' "$1" | openssl base64 -A; }
relay_decode() { printf '%s' "$1" | openssl base64 -d -A 2>/dev/null; }
relay_name_ok() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]{0,15}$'; }
relay_host_ok() { valid_domain "$1" || printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]*:[0-9a-fA-F:]*$'; }
relay_self_addr() { local a; a=$(gget ip4); printf '%s' "${a:-$(gget ip6)}"; }

# 经 Cloudflare 的节点（Argo）不到落地机的 IP，不需要也无法中转
relay_able() { [ "$(pmeta "$1" local)" != 1 ] || [ "$(pmeta "$1" behind)" = site ]; }

# 落地机要中转的端口，每个端口一项：<端口>/<tcp|udp|tcp+udp>
relay_ports_spec() {
  local id p
  for id in $(protos_enabled); do
    relay_able "$id" || continue
    p=$(NODE_VIA="" pubport "$id")
    echo "$p $(pmeta "$id" l4)"
    [ "$(pmeta "$id" udp_too)" = 1 ] && echo "$p udp"
  done | awk '{ if (!($1 in l)) { o[++n] = $1; l[$1] = $2 } else if (l[$1] != $2) l[$1] = "tcp+udp" }
    END { for (i = 1; i <= n; i++) printf "%s%s/%s", (i > 1 ? " " : ""), o[i], l[o[i]] }'
}

# 中转机上转发占用的端口，每行 <端口>/<tcp|udp>
relay_fwd_ports() {
  local key m
  for key in $(relay_keys fwd); do
    for m in $(rget "$key" | cut -d' ' -f3-); do
      case "${m#*/}" in
        tcp+udp) echo "${m%%=*}/tcp"; echo "${m%%=*}/udp" ;;
        *) echo "${m%%=*}/${m#*/}" ;;
      esac
    done
  done
}

# 端口 <p> 在本机是否已被占用（l4 可以是 tcp+udp）：节点、伪装站、端口跳跃、其他转发，以及系统里正在监听的
relay_port_taken() { # <端口> <l4> <本次已分配的端口...>
  local p="$1" l4="$2" x a b
  shift 2
  case " $* " in *" $p "*) return 0 ;; esac
  for x in $(ports_wanted); do
    case "$x" in
      *:*/udp) a=${x%%:*} b=${x#*:} b=${b%/*}
        case "$l4" in *udp*) [ "$p" -ge "$a" ] && [ "$p" -le "$b" ] && return 0 ;; esac ;;
      "$p/tcp") case "$l4" in *tcp*) return 0 ;; esac ;;
      "$p/udp") case "$l4" in *udp*) return 0 ;; esac ;;
    esac
  done
  case "$l4" in *tcp*) port_in_use tcp "$p" && return 0 ;; esac
  case "$l4" in *udp*) port_in_use udp "$p" && return 0 ;; esac
  return 1
}

relay_pick_port() { # <想要的端口> <l4> <本次已分配的端口...>
  local want="$1" l4="$2" p i=0
  shift 2
  relay_port_taken "$want" "$l4" "$@" || { echo "$want"; return 0; }
  while [ $i -lt 50 ]; do
    p=$(rand_int 20000 59999)
    relay_port_taken "$p" "$l4" "$@" || { echo "$p"; return 0; }
    i=$((i + 1))
  done
  return 1
}

# sing-box 入站：每个转发端口一个 direct 入站，目的地改写成落地机
relay_render_inbounds() {
  local key name host m lp r sep="" net
  echo '{'
  echo '  "inbounds": ['
  for key in $(relay_keys fwd); do
    set -- $(rget "$key")
    name=$1 host=$2
    shift 2
    for m in "$@"; do
      lp=${m%%=*} r=${m#*=}
      net=""
      [ "${r#*/}" = tcp+udp ] || net="\"network\": \"${r#*/}\", "
      printf '%s    {"type": "direct", "tag": "relay-%s-%s", "listen": "%s", "listen_port": %s, %s"override_address": "%s", "override_port": %s}' \
        "$sep" "$name" "$lp" "$(listen_addr)" "$lp" "$net" "$host" "${r%%/*}"
      sep=$',\n'
    done
  done
  printf '\n  ]\n}\n'
}

# 路由里排在最前：转发的目的地是用户自己指定的落地机，不受私网拦截和 WARP 规则影响
relay_route_rule() {
  local key name m tags=""
  for key in $(relay_keys fwd); do
    set -- $(rget "$key")
    name=$1
    shift 2
    for m in "$@"; do tags="$tags${tags:+, }\"relay-$name-${m%%=*}\""; done
  done
  [ -n "$tags" ] && printf '{"inbound": [%s], "action": "route", "outbound": "direct"}' "$tags"
  return 0
}

# 给 node_each 用：协议 <id> 经各个中转机的地址行，第四段是端口对应关系
relay_via_hosts() { # <协议>
  local key p name host
  relay_able "$1" || return 0
  p=$(NODE_VIA="" pubport "$1")
  for key in $(relay_keys via); do
    set -- $(rget "$key")
    name=$1 host=$2
    shift 2
    # 建中转之后才启用的协议，中转机上还没有它的端口
    case " $* " in *" $p="*) ;; *) continue ;; esac
    echo "Via-$name|$host||$*"
  done
}

# 落地机：输出给中转机用的中转码
relay_invite() {
  local addr spec
  need_root
  need_installed
  addr=$(relay_self_addr)
  [ -n "$addr" ] || die "$(t relay_noaddr)"
  spec=$(relay_ports_spec)
  [ -n "$spec" ] || die "$(t relay_nothing)"
  say "$(t relay_invite_intro)"
  say ""
  say "  pbox relay forward $(relay_encode "fwd|$(gget region)|$addr|$spec")"
  say ""
}

# 中转机：按中转码建转发，再输出给落地机用的中转码
relay_forward() { # <中转码> [名字]
  local raw name host spec key old item tp l4 lp map="" used="" back="" self
  need_root
  need_installed
  raw=$(relay_decode "${1:-}")
  case "$raw" in fwd\|*) ;; *) die "$(t relay_bad_code)" ;; esac
  IFS='|' read -r _ name host spec <<<"$raw"
  name="${2:-${name:-Exit}}"
  relay_name_ok "$name" || die "$(t relay_bad_name "$name")"
  relay_host_ok "$host" || die "$(t relay_bad_code)"
  [ "$(gget nat 0)" = 1 ] && die "$(t relay_nat)"
  self=$(relay_self_addr)
  [ -n "$self" ] || die "$(t relay_noaddr)"
  [ "$host" = "$self" ] && die "$(t relay_self)"
  edit_begin
  key=$(relay_key fwd "$name")
  old=$(rget "$key")
  if [ -n "$old" ] && [ "$(echo "$old" | cut -d' ' -f2)" != "$host" ]; then
    txn_abort
    die "$(t relay_name_taken "$name")"
  fi
  # 先去掉旧的这一条，端口才不会和它自己冲突；同一个落地机端口沿用原来的本机端口，落地机那边不必跟着改
  rdel "$key"
  for item in $spec; do
    tp=${item%%/*} l4=${item#*/}
    valid_port "$tp" || { txn_abort; die "$(t relay_bad_code)"; }
    case "$l4" in tcp | udp | tcp+udp) ;; *) txn_abort; die "$(t relay_bad_code)" ;; esac
    lp=$(printf '%s\n' $old | sed -n "s#^\([0-9]*\)=$tp/.*#\1#p" | head -1)
    [ -n "$lp" ] || lp=$(relay_pick_port "$tp" "$l4" $used) || { txn_abort; die "$(t relay_no_port)"; }
    used="$used $lp"
    map="$map $lp=$tp/$l4"
    back="$back${back:+ }$tp=$lp"
  done
  rset "$key" "$name $host$map"
  edit_end same
  say ""
  say "$(t relay_fwd_done "$name" "$host")"
  say ""
  say "  pbox relay via $(relay_encode "via|$(gget region)|$self|$back")"
  say ""
}

# 落地机：记下中转机，节点里多出经它中转的版本
relay_via() { # <中转码> [名字]
  local raw name host map key old m
  need_root
  need_installed
  raw=$(relay_decode "${1:-}")
  case "$raw" in via\|*) ;; *) die "$(t relay_bad_code)" ;; esac
  IFS='|' read -r _ name host map <<<"$raw"
  name="${2:-${name:-Relay}}"
  relay_name_ok "$name" || die "$(t relay_bad_name "$name")"
  relay_host_ok "$host" || die "$(t relay_bad_code)"
  for m in $map; do
    valid_port "${m%%=*}" && valid_port "${m#*=}" || die "$(t relay_bad_code)"
  done
  edit_begin
  key=$(relay_key via "$name")
  old=$(rget "$key")
  if [ -n "$old" ] && [ "$(echo "$old" | cut -d' ' -f2)" != "$host" ]; then
    txn_abort
    die "$(t relay_name_taken "$name")"
  fi
  rset "$key" "$name $host $map"
  edit_end
  say "$(t relay_via_done "$name")"
}

relay_off() { # <fwd|via> <名字>
  local key
  [ -n "${2:-}" ] || { cmd_help; exit 1; }
  edit_begin
  key=$(relay_key "$1" "$2")
  [ -n "$(rget "$key")" ] || { txn_abort; die "$(t relay_off_none "$2")"; }
  rdel "$key"
  if [ "$1" = fwd ]; then edit_end same; else edit_end; fi
}

relay_status() {
  local key name host m spec p any=0
  for key in $(relay_keys fwd); do
    any=1
    set -- $(rget "$key")
    name=$1 host=$2
    shift 2
    for m in "$@"; do say "$(t relay_st_fwd "$name" "${m%%=*}" "$(host_fmt "$host")" "${m#*=}")"; done
  done
  spec=$(relay_ports_spec)
  for key in $(relay_keys via); do
    any=1
    set -- $(rget "$key")
    name=$1 host=$2
    shift 2
    say "$(t relay_st_via "$name" "$host" "$*")"
    for p in $spec; do
      case " $* " in *" ${p%%/*}="*) ;; *) note "$(t relay_missing "${p%%/*}" "$name")" ;; esac
    done
  done
  [ $any = 1 ] || say "$(t relay_intro)"
}

# 体检：中转机能不能连到落地机。UDP 没有简单的测法，只测 TCP。
d_relay() {
  local key name host m tp rc=0
  testing && return 0
  for key in $(relay_keys fwd); do
    set -- $(rget "$key")
    name=$1 host=$2
    shift 2
    for m in "$@"; do
      case "${m#*/}" in udp) continue ;; esac
      tp=${m#*=} tp=${tp%%/*}
      if timeout 5 bash -c "exec 3<>/dev/tcp/$host/$tp" 2>/dev/null; then
        ok "$(t d_relay_ok "$name" "$(host_fmt "$host")" "$tp")"
      else
        bad "$(t d_relay_bad "$name" "$(host_fmt "$host")" "$tp")"
        hint "$(t d_relay_hint)"
        rc=1
      fi
    done
  done
  return $rc
}

# pbox relay [status|invite|forward <码> [名字]|forward off <名字>|via <码> [名字]|via off <名字>]
cmd_relay() {
  case "${1:-status}" in
    status) need_root; need_installed; relay_status ;;
    invite) relay_invite ;;
    forward) if [ "${2:-}" = off ]; then relay_off fwd "${3:-}"; else relay_forward "${2:-}" "${3:-}"; fi ;;
    via) if [ "${2:-}" = off ]; then relay_off via "${3:-}"; else relay_via "${2:-}" "${3:-}"; fi ;;
    *) cmd_help; exit 1 ;;
  esac
}
