# 自建订阅：订阅文件由本机的 Nginx 提供，地址是 https://<域名或 IP>[:端口]/<随机路径>/<格式>。
# 每个用户一条随机路径，彼此读不到对方的；路径不对的请求与访问网站上不存在的页面结果相同。
# 伪装站开着时挂在 443 的网站上；否则用域名证书或 IP 证书单独开一个端口。
# 没有证书时不提供：订阅内容就是全部密钥，明文传输等于公开，自签证书客户端又不认。
# 只含本机的节点；几台机器合并成一个地址仍要用私有仓库订阅。
# Nginx 的配置里只有匹配规则，不含任何人的路径，换路径不必重载

SELFSUB_RE='^/([0-9a-f]{32})/(v2ray|clash|singbox)$'

selfsub_on() { [ "$(gget selfsub 0)" = 1 ]; }

selfsub_mode() {
  selfsub_on || return 1
  if site_on_p; then
    echo site
  elif tls_real; then
    echo port
  else
    return 1
  fi
}

selfsub_port_on() { [ "$(selfsub_mode)" = port ]; }

selfsub_base() {
  case "$(selfsub_mode)" in
    site) printf 'https://%s' "$(gget tls_domain)" ;;
    port) printf 'https://%s:%s' "$(gget tls_domain)" "$(gget selfsub_ext_port "$(gget selfsub_port)")" ;;
    *) return 1 ;;
  esac
}

selfsub_new_path() { rand_hex 16; }

# 单独端口不能和协议、中转用的 TCP 端口重
selfsub_port_taken() { # <端口>
  local id
  for id in $(protos_enabled); do
    [ "$(pmeta "$id" l4)" = udp ] && [ "$(pmeta "$id" udp_too)" != 1 ] && continue
    [ "$(pget "$id" port)" = "$1" ] && return 0
  done
  relay_fwd_ports | grep -qx "$1/tcp"
}

# 由 conflict_check 调用。订阅已经在这个端口上提供时，换端口等于换地址，客户端会悄悄停止更新，
# 所以拒绝占用它的改动；刚切换到单独端口、还没对外提供时，被占了就另选一个
selfsub_port_fix() {
  local n=0 p
  selfsub_port_on || return 0
  p=$(gget selfsub_port)
  if [ -n "$p" ] && selfsub_port_taken "$p"; then
    grep -q "listen $p ssl" "$GEN/nginx/nginx.conf" 2>/dev/null && { txn_abort; die "$(t selfsub_port_clash "$p")"; }
    gset selfsub_port ""
  fi
  while { [ -z "$(gget selfsub_port)" ] || selfsub_port_taken "$(gget selfsub_port)"; } && [ $n -lt 30 ]; do
    gset selfsub_port "$(random_port tcp)"
    n=$((n + 1))
  done
}

# Nginx 里的订阅位置。<回落>：文件不存在时交给谁。网站上交给网站自己，
# 这样猜错的路径和网站上任何不存在的页面得到同样的回应
selfsub_location() { # <回落>
  local var="${VARDIR#"$R"}" r
  selfsub_mode >/dev/null || return 0
  r=$(gget region)
  cat <<EOF
    location ~ "$SELFSUB_RE" {
      root $var/sub;
      try_files /\$1/\$2 $1;
      default_type text/plain;
      charset utf-8;
      add_header Cache-Control "no-store";
      add_header Content-Disposition 'attachment; filename="pbox${r:+-$r}"';
      add_header Profile-Update-Interval 12;
    }
EOF
}

# 没有伪装站时单独开一个端口，只认订阅路径。用域名证书时，不带这个域名的握手直接拒绝，
# 扫描 IP 的人看不到证书；IP 证书的连接本来就不带域名，没法这样区分
nginx_render_port() {
  local p v6="" var="${VARDIR#"$R"}" log="${LOGDIR#"$R"}"
  p=$(gget selfsub_port)
  [ -n "$(gget ip6)" ] && v6=1
  cat <<EOF
worker_processes 1;
pid $var/nginx.pid;
error_log $log/nginx.log crit;
events { worker_connections 1024; }

http {
$(nginx_http_head)

EOF
  if ! tls_is_ip && nginx_can_reject; then
    printf '  server {\n    listen %s ssl default_server;\n' "$p"
    [ -n "$v6" ] && printf '    listen [::]:%s ssl default_server;\n' "$p"
    printf '    ssl_reject_handshake on;\n  }\n'
    printf '  server {\n    listen %s ssl;\n' "$p"
    [ -n "$v6" ] && printf '    listen [::]:%s ssl;\n' "$p"
    printf '    server_name %s;\n' "$(gget tls_domain)"
  else
    printf '  server {\n    listen %s ssl default_server;\n' "$p"
    [ -n "$v6" ] && printf '    listen [::]:%s ssl default_server;\n' "$p"
  fi
  selfsub_location '=404'
  printf '    location / { return 404; }\n  }\n}\n'
}

# 由 nodes_write 调用：按当前的路径重建 Nginx 读取的目录。先建好新的再换上，
# 换路径后旧地址立即失效
selfsub_build() {
  local d="$VARDIR/sub" u p
  rm -rf "$d.new" "$d.old"
  if selfsub_mode >/dev/null; then
    mkdir -p "$d.new"
    for u in $(users_list); do
      p=$(uget "$u" sub_path)
      [ -n "$p" ] && [ -d "$NODES/users/$u/sub" ] || continue
      cp -R "$NODES/users/$u/sub" "$d.new/$p"
    done
    chmod -R u=rwX,go= "$d.new"
    testing || chown -R "$RUN_USER:$RUN_USER" "$d.new"
  fi
  [ -d "$d" ] && mv "$d" "$d.old"
  [ -d "$d.new" ] && mv "$d.new" "$d"
  rm -rf "$d.old"
  return 0
}

selfsub_show() { # <用户>
  local b p k
  head1 "$(t selfsub_title) · $1"
  if ! b=$(selfsub_base); then
    note "$(t selfsub_need_cert)"
    return 0
  fi
  p=$(uget "$1" sub_path)
  for k in v2ray clash singbox; do
    printf '  %s%s%s\n  %s\n\n' "$C_B" "$(t "sub_c_$k")" "$C_0" "$b/$p/$k"
  done
}

selfsub_notes() {
  local cdn
  selfsub_mode >/dev/null || return 0
  note "$(t selfsub_url_note)"
  sub_enabled || note "$(t selfsub_local_note)"
  cdn=$(gget cdn_host)
  if [ "$(selfsub_mode)" = site ] && [ -n "$cdn" ]; then note "$(t selfsub_cdn_note "$cdn")"; fi
  if selfsub_port_on && [ "$(gget nat 0)" = 1 ] && [ -z "$(gget selfsub_ext_port)" ]; then note "$(t selfsub_nat_note "$(gget selfsub_port)")"; fi
  return 0
}

d_selfsub() {
  local u p b got code
  selfsub_on || return 0
  b=$(selfsub_base) || { bad "$(t d_selfsub_nocert)"; return 1; }
  u=$(users_list | sed -n 1p)
  p=$(uget "$u" sub_path)
  testing && { ok "$(t d_selfsub_ok "$b")"; return 0; }
  # 连本机，但握手和请求里仍是订阅地址上的名字，证书照常校验
  got=$(curl -s --max-time 10 --connect-to "::127.0.0.1:" "$b/$p/clash" 2>/dev/null)
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --connect-to "::127.0.0.1:" "$b/$(selfsub_new_path)/clash" 2>/dev/null)
  if [ -n "$got" ] && [ "$got" = "$(cat "$NODES/users/$u/sub/clash" 2>/dev/null)" ] && [ "$code" = 404 ]; then
    ok "$(t d_selfsub_ok "$b")"
  else
    bad "$(t d_selfsub_bad "$b")"
    hint "$LOGDIR/nginx.log"
    return 1
  fi
}

cmd_selfsub() {
  local u
  case "${1:-}" in
    on)
      edit_begin
      tls_real || { txn_abort; die "$(t selfsub_need_cert)"; }
      gset selfsub 1
      for u in $(users_list); do [ -n "$(uget "$u" sub_path)" ] || uset "$u" sub_path "$(selfsub_new_path)"; done
      edit_end same
      [ "$DRY_RUN" = 1 ] && return 0
      sub_show
      ;;
    off)
      edit_begin
      gset selfsub 0
      edit_end same
      say "$(t selfsub_off_done)"
      ;;
    reset)
      [ -z "${2:-}" ] || [ -f "$STATE/users/$2.env" ] || die "$(t user_missing "$2")"
      edit_begin
      selfsub_on || { txn_abort; die "$(t selfsub_not_on)"; }
      for u in ${2:-$(users_list)}; do uset "$u" sub_path "$(selfsub_new_path)"; done
      edit_end same
      [ "$DRY_RUN" = 1 ] && return 0
      note "$(t selfsub_reset_done)"
      sub_show "${2:-}"
      ;;
    port)
      # NAT 机器只转发指定的端口，要用服务商分配的那一对；外网端口不同时一起给出
      case "${2:-}:${3:-0}" in *[!0-9:]* | :*) die "$(t selfsub_usage)" ;; esac
      [ "$2" -ge 1 ] && [ "$2" -le 65535 ] && [ "${3:-1}" -ge 1 ] && [ "${3:-1}" -le 65535 ] || die "$(t selfsub_usage)"
      edit_begin
      selfsub_port_taken "$2" && { txn_abort; die "$(t selfsub_port_taken "$2")"; }
      if [ "$2" != "$(gget selfsub_port)" ] && port_in_use tcp "$2"; then txn_abort; die "$(t c_busy tcp "$2" "$(port_owner tcp "$2")")"; fi
      gset selfsub_port "$2"
      gset selfsub_ext_port "${3:-}"
      edit_end same
      [ "$DRY_RUN" = 1 ] && return 0
      selfsub_on && sub_show
      ;;
    *) die "$(t selfsub_usage)" ;;
  esac
  return 0
}
