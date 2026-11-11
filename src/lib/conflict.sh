# 冲突引擎只看协议声明的属性和状态里的端口，不认识具体协议。
# 规则编号对应 docs/03-冲突规则.md。阶段 1 实现 H1、H2、H4、H12。

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
        if [ "$(pmeta "$a" l4)" = "$(pmeta "$b" l4)" ] && [ "$(pget "$a" port)" = "$(pget "$b" port)" ]; then
          conflict_resolve_port "$a" "$b"
          again=1
          break 2
        fi
      done
    done
  done
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
  return 0
}
