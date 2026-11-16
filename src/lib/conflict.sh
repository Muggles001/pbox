# 冲突引擎只看协议声明的属性和状态里的端口，不认识具体协议。
# 规则编号对应 docs/03-冲突规则.md，哪些已实现、哪些由结构保证也记在那里。

# 两个协议用到的传输层有没有重叠。Shadowsocks 在 TCP 之外还用同一端口的 UDP。
l4_overlap() { # <协议A> <协议B>
  local a b
  a="$(pmeta "$1" l4)$([ "$(pmeta "$1" udp_too)" = 1 ] && echo " udp")"
  b="$(pmeta "$2" l4)$([ "$(pmeta "$2" udp_too)" = 1 ] && echo " udp")"
  case " $a " in *" ${b%% *} "*) return 0 ;; esac
  case " $b " in *" ${a%% *} "*) return 0 ;; esac
  case "$a $b" in *udp*udp*) return 0 ;; esac
  return 1
}

# H1/H2：两个协议要用同一个传输层的同一个端口。
conflict_resolve_port() { # <协议A> <协议B>
  local a="$1" b="$2" l4 port c
  l4=$(pmeta "$a" l4)
  port=$(pget "$a" port)
  [ "$ASSUME_YES" = 1 ] && die "$(t c_port_yes "$(pmeta "$a" title)" "$(pmeta "$b" title)" "$l4" "$port")"
  head1 "$(t c_port_title "$l4" "$port")"
  say "  A  $(pmeta "$a" title)"
  say "  B  $(pmeta "$b" title)"
  say ""
  say "  1 $(t c_port_opt_move A B)"
  say "  2 $(t c_port_opt_move B A)"
  say "  3 $(t c_port_opt_only A)"
  say "  4 $(t c_port_opt_only B)"
  ask "" 1
  c="$REPLY"
  case "$c" in
    2) pset "$a" port "$(random_port "$l4")" ;;
    3) rm -f "$CUR/protocols/$b.env" ;;
    4) rm -f "$CUR/protocols/$a.env" ;;
    *) pset "$b" port "$(random_port "$l4")" ;;
  esac
}

# NAT 机器上两个协议不能写同一个外网端口：商家的一个端口只转给一个内网端口。
# 外网端口是商家给定的，脚本没法替用户换一个，所以只报错
conflict_ext_ports() {
  local a b e
  for a in $(protos_enabled); do
    e=$(pget "$a" ext_port)
    [ -n "$e" ] || continue
    for b in $(protos_enabled); do
      [ "$a" \< "$b" ] || continue
      [ "$e" = "$(pget "$b" ext_port)" ] && l4_overlap "$a" "$b" &&
        die "$(t c_ext_dup "$(pmeta "$a" title)" "$(pmeta "$b" title)" "$e")"
    done
  done
  return 0
}

# 检查临时状态 $CUR。硬冲突逐个解决，每解决一个就从头再查，直到没有为止。
conflict_check() {
  local a b again=1 l4 port owner
  # H4：同一协议只由一个内核承载。状态按协议名一个文件，这里确认它是已知协议且内核有效。
  for a in $(protos_enabled); do
    proto_known "$a" || die "$(t c_unknown "$a")"
    case "$(pmeta "$a" core)" in xray | singbox) ;; *) die "$(t c_unknown "$a")" ;; esac
  done
  while [ "$again" = 1 ]; do
    again=0
    for a in $(protos_enabled); do
      for b in $(protos_enabled); do
        [ "$a" \< "$b" ] || continue
        if l4_overlap "$a" "$b" && [ "$(pget "$a" port)" = "$(pget "$b" port)" ]; then
          conflict_resolve_port "$a" "$b"
          again=1
          break 2
        fi
      done
    done
  done
  # H3：已开启端口跳跃时，新加或改了端口的 UDP 协议不能落在跳跃范围里
  port=$(pget hysteria2 hop_range)
  if [ -n "$port" ] && a=$(hop_overlaps "${port%-*}" "${port#*-}"); then
    [ "$ASSUME_YES" = 1 ] && [ -n "$(kv_get "$STATE/protocols/$a.env" port)" ] && [ "$(pget "$a" port)" != "$(kv_get "$STATE/protocols/$a.env" port)" ] &&
      die "$(t hop_overlap "$port" "$(pmeta "$a" title)" "$(pget "$a" port)")"
    # 端口是脚本自动选的：换一个不在范围里的
    b=0
    while hop_overlaps "${port%-*}" "${port#*-}" >/dev/null && [ "$b" -lt 30 ]; do
      pset "$a" port "$(random_port udp)"
      b=$((b + 1))
    done
  fi
  # H12：端口被 pbox 以外的程序占用。自己正在用的端口不算。
  for a in $(protos_enabled); do
    l4=$(pmeta "$a" l4)
    port=$(pget "$a" port)
    [ "$port" = "$(kv_get "$STATE/protocols/$a.env" port)" ] && continue
    port_in_use "$l4" "$port" || continue
    owner=$(port_owner "$l4" "$port")
    [ "$ASSUME_YES" = 1 ] && die "$(t c_busy "$l4" "$port" "${owner:-?}")"
    warn "$(t c_busy "$l4" "$port" "${owner:-?}")"
    confirm "$(t c_busy_q)" || die "$(t cancelled)"
    pset "$a" port "$(random_port "$l4")"
  done
  conflict_ext_ports
  return 0
}

# 对外开放的端口到这个数就提醒一次（S3）。推荐配置是 2 个，常用的几个协议全开也不到它
PORTS_MANY=6
ports_exposed() { ports_wanted | wc -l | tr -d ' '; }

soft_raise() { # <ask|collect> <文案> [协议]
  if [ "$1" = collect ]; then
    SOFT_NOTES="$SOFT_NOTES$2
"
    return 0
  fi
  warn "$2"
  # 协议自己有补救办法时先问它（SOCKS5 限定来源），补上了就不必再确认
  [ -n "${3:-}" ] && declare -F "proto_${3//-/_}_mitigate" >/dev/null && pcall "$3" mitigate && return 0
  confirm_risk "$(t s_continue)" || { txn_abort; die "$(t cancelled)"; }
}

# 软冲突：只看这次新启用的协议（S1、S2）和因此增加的对外端口（S3）。
# 默认当面确认。collect 只收集到 SOFT_NOTES，由调用方显示：安装时并入安装计划一起确认；
# --yes 时也是收集，因为点名要装哪个协议已经是明确的选择，应答文件装落地机要靠它
conflict_soft() { # [collect]
  local id key n mode="${1:-ask}"
  [ "$ASSUME_YES" = 1 ] && mode=collect
  SOFT_NOTES=""
  for id in $(protos_enabled); do
    [ -f "$STATE/protocols/$id.env" ] && continue
    key=$(pmeta "$id" risk)
    [ -n "$key" ] && soft_raise "$mode" "$(t "$key")" "$id"
  done
  n=$(ports_exposed)
  if [ "$n" -ge "$PORTS_MANY" ] && [ "$(CUR="$STATE" ports_exposed)" -lt "$PORTS_MANY" ]; then
    soft_raise "$mode" "$(t s3_warn "$n")"
  fi
  return 0
}
