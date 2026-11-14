# 直接列出私网网段，不依赖内核附带的地址库文件（本项目不安装它）
PRIVATE_CIDRS='"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16", "100.64.0.0/10", "fc00::/7", "fe80::/10", "::1/128"'

core_render_base() {
  local rules extra block
  block=$(gget block_private 1)
  case "$1" in
    xray)
      cat <<EOF
{
  "log": {"loglevel": "error", "access": "none"},
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {
    "rules": [$([ "$block" = 1 ] && printf '{"type": "field", "ip": [%s], "outboundTag": "block"}' "$PRIVATE_CIDRS")]
  }
}
EOF
      ;;
    singbox)
      # 日志只记致命错误：error 级别会把每个连接失败的来源 IP 写进日志，与"不记录客户端地址"相违
      rules=$(relay_route_rule)
      # Trojan 把密码不对的连接转给本机的伪装站，这条连接也要过路由：
      # 排在最前，免得被下面的私网拦截或 WARP 规则带走
      proto_enabled trojan &&
        rules="$rules${rules:+, }{\"inbound\": [\"trojan\"], \"ip_cidr\": [\"127.0.0.1/32\"], \"port\": [$(gget site_plain_port)], \"action\": \"route\", \"outbound\": \"direct\"}"
      [ "$block" = 1 ] && rules="$rules${rules:+, }{\"ip_is_private\": true, \"action\": \"reject\"}"
      extra=$(warp_rules_json)
      [ -n "$extra" ] && rules="$rules${rules:+, }$extra"
      cat <<EOF
{
  "log": {"level": "fatal", "timestamp": true},
  "outbounds": [
    {"type": "direct", "tag": "direct"}
  ],$(warp_endpoint_json)
  "route": {
    "rules": [$rules]$(warp_final_json)
  }
}
EOF
      ;;
  esac
}

# render_all <输出目录>：按 $CUR 渲染。每个协议一个文件，由内核自己合并加载。
# custom/ 里的用户片段一并复制进来，和生成物一起接受校验。
render_all() {
  local out="$1" core id f d
  rm -rf "$out"
  for core in $(cores_needed); do
    d="$out/$(core_dir "$core")"
    mkdir -p "$d"
    if [ "$core" = nginx ]; then
      nginx_render >"$d/nginx.conf"
      continue
    fi
    core_render_base "$core" >"$d/00_base.json"
    for f in "$CUSTOM/$(core_dir "$core")"/*.json; do
      [ -f "$f" ] && cp "$f" "$d/90_custom_$(basename "$f")"
    done
  done
  for id in $(protos_enabled); do
    pcall "$id" render_inbound >"$out/$(core_dir "$(pmeta "$id" core)")/10_$id.json" || return 1
  done
  relay_fwd_any && relay_render_inbounds >"$out/sing-box/20_relay.json"
  mkdir -p "$out"
}

validate_all() { # <目录>
  local core d msg rc=0
  for core in $CORES_ALL; do
    d="$1/$(core_dir "$core")"
    [ -d "$d" ] || continue
    if ! msg=$(core_validate "$core" "$d"); then
      warn "$(t validate_fail "$(core_title "$core")")"
      printf '%s\n' "$msg" | tail -8 >&2
      printf '%s\n' "$msg" | grep -q '90_custom_' && warn "$(t validate_custom)"
      rc=1
    fi
  done
  return $rc
}

# 让一个内核按 $GEN 的现状生效；不再需要的内核停掉。
# core_sync <内核> <配置是否有变化 0|1>
# 服务文件每次都重写：运行环境的变化（例如解析配置的映射）对所有内核都有效，
# 不能只处理这次配置有变化的那个。但只有确实有变化时才重载或重启，其余内核不受打扰。
core_sync() {
  local core="$1" cfg="${2:-1}" n
  n=$(core_svc "$core")
  if [ ! -d "$GEN/$(core_dir "$core")" ]; then
    testing || svc_remove "$n"
    return 0
  fi
  svc_write "$n" "$(core_cmd "$core")" "$([ "$core" = xray ] && echo 0 || echo 1)"
  svc enable "$n"
  if ! svc active "$n"; then
    # 内核的热重载是异步的：它让出 443 可能比这里晚一点，等它一下再启动 Nginx
    [ "$core" = nginx ] && ! testing && for _ in 1 2 3 4 5 6 7 8 9 10; do port_in_use tcp 443 || break; sleep 0.5; done
    svc start "$n"
  elif [ "${UNIT_CHANGED:-0}" = 1 ]; then
    svc restart "$n"
  elif [ "$cfg" = 1 ]; then
    # sing-box 和 Nginx 支持热重载，连接不断；Xray 只能重启。
    [ "$core" != xray ] && svc reload "$n" 2>/dev/null || svc restart "$n"
  fi
}

probe() {
  local core id
  testing && return 0
  sleep 2
  for core in $(cores_needed); do
    if ! svc active "$(core_svc "$core")"; then
      warn "$(t probe_dead "$(core_title "$core")")"
      # 把内核自己的报错给用户看，否则只知道"没起来"而不知道原因
      tail -n 6 "$LOGDIR/$(core_svc "$core").log" 2>/dev/null >&2
      [ "$INIT" = systemd ] && journalctl -u "$(core_svc "$core")" -n 6 --no-pager 2>/dev/null >&2
      return 1
    fi
  done
  for id in $(protos_enabled); do
    port_in_use "$(pmeta "$id" l4)" "$(pget "$id" port)" || { warn "$(t probe_port "$(pmeta "$id" title)" "$(pget "$id" port)")"; return 1; }
  done
}

rollback() {
  local core
  [ -d "$PREV/state" ] || return 1
  rm -rf "$STATE" "$GEN"
  cp -R "$PREV/state" "$STATE"
  [ -d "$PREV/generated" ] && cp -R "$PREV/generated" "$GEN"
  CUR="$STATE"
  fix_perms
  for core in $(cores_order); do core_sync "$core"; done
}

# 443 在 Nginx 和内核之间易手时，先处理让出端口的那一方：
# 关闭分流时先停 Nginx，开启时先让内核退到本机端口。
cores_order() {
  if [ -d "$GEN/nginx" ]; then echo "xray singbox nginx"; else echo "nginx xray singbox"; fi
}

# 上一次提交若在替换途中被强行终止，这里把目录复原到替换之前。每次启动时调用。
state_recover() {
  [ -d "$ETC" ] || return 0
  if [ ! -d "$STATE" ] && [ -d "$STATE.old" ]; then mv "$STATE.old" "$STATE"; fi
  if [ ! -d "$GEN" ] && [ -d "$GEN.old" ]; then mv "$GEN.old" "$GEN"; fi
  # 状态已换成新的而生成物还没跟上：按现有状态重新渲染一次
  if [ -d "$STATE" ] && [ -d "$GEN.old" ] && [ -d "$GEN" ]; then rm -rf "$GEN.old"; fi
  [ -d "$STATE.old" ] && [ -d "$STATE" ] && rm -rf "$STATE.old"
  return 0
}

# 提交事务：渲染 → 校验 → 比对 → 备份现状 → 替换 → 只动有变化的内核 → 探活，失败回滚。
# 返回 0 表示已生效；非 0 表示未生效且已恢复原状。
txn_commit() {
  local new="$ETC/.txn" core d changed=""
  render_all "$new/generated" || { txn_abort; return 1; }
  if ! validate_all "$new/generated"; then
    txn_abort
    return 1
  fi
  for core in $CORES_ALL; do
    d=$(core_dir "$core")
    if [ -d "$GEN/$d" ] || [ -d "$new/generated/$d" ]; then
      diff -rq "$GEN/$d" "$new/generated/$d" >/dev/null 2>&1 || changed="$changed $core"
    fi
  done
  if [ "$DRY_RUN" = 1 ]; then
    head1 "$(t dry_title)"
    diff -ru "$STATE" "$new/state" 2>/dev/null | grep -E '^[+-][a-z_0-9]+=' | sed -E 's/^([+-][a-z_0-9]*(key|password|uuid)[a-z_0-9]*)=.*/\1=***/; s/^/  /'
    say "  $(t dry_cores "${changed:- -}")"
    txn_abort
    return 0
  fi
  rm -rf "$PREV"
  mkdir -p "$PREV"
  [ -d "$STATE" ] && cp -R "$STATE" "$PREV/state"
  [ -d "$GEN" ] && cp -R "$GEN" "$PREV/generated"
  # 替换的这几步不可被打断：SSH 断线、管道关闭、Ctrl-C 都先忽略，换完再恢复。
  # 每一步都是改名而不是"先删后放"，万一进程还是被强行终止，state_recover 能据此复原。
  trap '' HUP PIPE INT TERM
  rm -rf "$STATE.old" "$GEN.old"
  [ -d "$STATE" ] && mv "$STATE" "$STATE.old"
  mv "$new/state" "$STATE"
  [ -d "$GEN" ] && mv "$GEN" "$GEN.old"
  mv "$new/generated" "$GEN"
  rm -rf "$STATE.old" "$GEN.old" "$new"
  trap 'unlock; exit 130' INT TERM
  trap - HUP PIPE
  CUR="$STATE"
  manifest_add dir "$ETC"
  fix_perms
  for core in $(cores_order); do
    case " $changed " in *" $core "*) core_sync "$core" 1 ;; *) core_sync "$core" 0 ;; esac
  done
  if ! probe; then
    if rollback; then warn "$(t rolled_back)"; elif [ "${FRESH:-0}" != 1 ]; then warn "$(t rollback_none)"; fi
    return 1
  fi
  return 0
}
