# 伪装站与 443 分流。需要先有域名证书。
#
# 开启后由 Nginx 监听 TCP 443，只看握手里的域名、不解密，把连接分给两处：
#   握手里是自己的域名 → Nginx 自己的网站（用域名证书），浏览器访问域名看到的是一个正常网页；
#   其余的（包括 Reality 的伪装目标、不认识的域名、不带域名的）→ Reality 入站，行为与没有分流时相同。
# Reality 没有启用或不在 443 上时，其余的连接由网站那一侧拒绝握手。
# 自己域名这一路上还能挂两个协议：Trojan 排在网站前面，VLESS-WS-TLS 是网站上的一个路径。
# 另有一个可选的"套 CDN 的子域名"：它在 Cloudflare 上打开了代理，Cloudflare 回源时
# 握手里写的是这个子域名，Nginx 把它交给网站（不经过 Trojan），WS 路径因此也能经 CDN 访问。
#
# Nginx 用发行版的软件包，但只用它的程序：配置是脚本自己的一份，服务也是自己的，
# 不读取也不修改 /etc/nginx 下的任何东西。机器上原有的网站因此不受影响。

SITE_DIR="$ETC/site"

site_on_p() { [ "$(gget site)" = on ]; }

# 某个协议是否退到了分流后面。目前只有在 443 上的 Reality。
front_on() {
  site_on_p && [ "$1" = reality-vision ] && proto_enabled reality-vision && [ "$(pget reality-vision port)" = 443 ]
}

nginx_bin() { command -v nginx 2>/dev/null; }

nginx_stream_mod() {
  testing && { echo /usr/lib/nginx/modules/ngx_stream_module.so; return 0; }
  find /usr/lib/nginx/modules /usr/lib64/nginx/modules /usr/share/nginx/modules -name ngx_stream_module.so 2>/dev/null | head -1
}

# 分流功能有的发行版编在主程序里，有的是单独的模块
nginx_stream_builtin() { nginx -V 2>&1 | tr ' ' '\n' | grep -qx -- '--with-stream'; }

# "不认识的域名直接拒绝握手"这条指令从 1.19.4 才有
nginx_can_reject() {
  local v a b c
  testing && return 0
  v=$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p')
  a=$(printf '%s' "$v" | cut -d. -f1) b=$(printf '%s' "$v" | cut -d. -f2) c=$(printf '%s' "$v" | cut -d. -f3)
  [ "${a:-0}" -gt 1 ] && return 0
  [ "${b:-0}" -gt 19 ] && return 0
  [ "${b:-0}" = 19 ] && [ "${c:-0}" -ge 4 ]
}

nginx_ensure() {
  local had=0 pk
  testing && return 0
  [ -n "$(nginx_bin)" ] && had=1
  if [ $had = 0 ] || { ! nginx_stream_builtin && [ -z "$(nginx_stream_mod)" ]; }; then
    case "$PKG" in
      apt) pk="nginx libnginx-mod-stream" ;;
      apk | dnf) pk="nginx nginx-mod-stream" ;;
      *) return 1 ;;
    esac
    say "$(t deps_missing " $pk")"
    # shellcheck disable=SC2086
    pkg_install $pk >/dev/null 2>&1 || return 1
    # 软件包会顺带启动它自己的服务并占用 80 端口。那个服务不是我们要的；
    # 只有在这台机器原本没有 Nginx 时才停掉它，原来就有的不碰。
    if [ $had = 0 ]; then
      if [ "$INIT" = systemd ]; then
        systemctl disable --now nginx >/dev/null 2>&1
      else
        rc-service nginx stop >/dev/null 2>&1
        rc-update del nginx >/dev/null 2>&1
      fi
    fi
  fi
  [ -n "$(nginx_bin)" ] && { nginx_stream_builtin || [ -n "$(nginx_stream_mod)" ]; }
}

# 校验时 Nginx 会以 root 身份创建日志和临时目录，之后服务以专用账号运行就写不进去了，
# 所以校验完把这些路径的属主交还给它。
nginx_validate() { # <配置目录>
  local rc
  mkdir -p "$VARDIR/nginx-tmp" "$LOGDIR"
  nginx -t -c "$1/nginx.conf" 2>&1
  rc=$?
  chown -R "$RUN_USER:$RUN_USER" "$VARDIR/nginx-tmp" "$VARDIR/nginx.pid" "$LOGDIR/nginx.log" 2>/dev/null
  return $rc
}

# 伪装站的来源：builtin 用 site/ 目录里的静态页面；否则是一个要转发过去的网址
site_source() { gget site_source builtin; }

nginx_render() {
  local dom sp own rp mod cdn certs="${CERTS#"$R"}" var="${VARDIR#"$R"}" log="${LOGDIR#"$R"}"
  dom=$(gget tls_domain) sp=$(gget site_port) cdn=$(gget cdn_host)
  # 开了 Trojan 时，自己域名的连接先交给它，密码不对的再由它转给网站
  own=$sp
  proto_enabled trojan && own=$(pget trojan port)
  mod=$(nginx_stream_mod)
  [ -n "$mod" ] && echo "load_module $mod;"
  cat <<EOF
worker_processes 1;
pid $var/nginx.pid;
error_log $log/nginx.log crit;
events { worker_connections 1024; }

stream {
  map \$ssl_preread_server_name \$pbox_up {
    $dom 127.0.0.1:$own;
EOF
  [ -n "$cdn" ] && echo "    $cdn 127.0.0.1:$sp;"
  if front_on reality-vision; then
    rp=$(gget site_front_port)
    echo "    default 127.0.0.1:$rp;"
  else
    echo "    default 127.0.0.1:$sp;"
  fi
  cat <<EOF
  }
  server {
    listen 443;
$([ -n "$(gget ip6)" ] && echo "    listen [::]:443;")
    ssl_preread on;
    proxy_pass \$pbox_up;
    proxy_connect_timeout 10s;
  }
}

http {
  access_log off;
  server_tokens off;
  client_body_temp_path $var/nginx-tmp/body;
  proxy_temp_path $var/nginx-tmp/proxy;
  fastcgi_temp_path $var/nginx-tmp/fastcgi;
  uwsgi_temp_path $var/nginx-tmp/uwsgi;
  scgi_temp_path $var/nginx-tmp/scgi;
  types {
    text/html html;
    text/css css;
    application/javascript js;
    image/svg+xml svg;
    image/png png;
    image/jpeg jpg jpeg;
    image/x-icon ico;
  }
  default_type application/octet-stream;
  ssl_certificate $certs/domain.crt;
  ssl_certificate_key $certs/domain.key;
  ssl_protocols TLSv1.2 TLSv1.3;

EOF
  # 握手里不是自己域名的连接走到这里时直接拒绝，不把证书亮给扫描 IP 的人
  if nginx_can_reject; then
    cat <<EOF
  server {
    listen 127.0.0.1:$sp ssl default_server;
    ssl_reject_handshake on;
  }
EOF
  fi
  cat <<EOF
  server {
    listen 127.0.0.1:$sp ssl http2;
    server_name $dom${cdn:+ $cdn};
EOF
  # Cloudflare 的"始终使用 HTTPS"不跳转验证路径，但用户自己的跳转规则可能会，
  # 那时签发方的访问经 HTTPS 送到这里，转给续期时临时监听 80 端口的 acme.sh
  [ -n "$cdn" ] && echo "    location ^~ /.well-known/acme-challenge/ { proxy_pass http://127.0.0.1:80; }"
  site_locations
  echo "  }"
  # Trojan 把密码不对的连接解密后转到这里，所以这一份不加密
  if proto_enabled trojan; then
    echo "  server {"
    echo "    listen 127.0.0.1:$(gget site_plain_port);"
    site_locations
    echo "  }"
  fi
  echo "}"
}

# 网站本身，以及 WS 协议的隐蔽路径。加密和不加密的两个入口共用这一份。
site_locations() {
  local src host id site="${SITE_DIR#"$R"}"
  src=$(site_source)
  for id in vless-wstls vmess; do
    proto_enabled "$id" || continue
    # 路径对但不是 WebSocket 的请求（比如浏览器直接打开）按不存在的页面处理
    cat <<EOF
    location = $(pget "$id" path) {
      if (\$http_upgrade != "websocket") { return 404; }
      proxy_pass http://127.0.0.1:$(pget "$id" port);
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_set_header Host \$host;
      proxy_read_timeout 1d;
      proxy_send_timeout 1d;
    }
EOF
  done
  if [ "$src" = builtin ]; then
    cat <<EOF
    root $site;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
EOF
  else
    host=$(printf '%s' "$src" | sed 's#^https://##; s#/.*##')
    cat <<EOF
    location / {
      proxy_pass https://$host;
      proxy_set_header Host $host;
      proxy_ssl_server_name on;
      proxy_set_header Accept-Encoding "";
    }
EOF
  fi
}

# 内置页面只是后备：所有装了本脚本的机器如果都摆同一个页面，页面本身就成了特征。
# 所以标题、文字、配色都随机组合；更好的做法是换成自己的页面，或转发一个真实的网站。
site_builtin_write() {
  local names="Atlas Harbor Juniper Lumen Meridian Orchard Pinecone Quartz Sparrow Tundra Willow Zephyr"
  local kinds="Studio Notes Works Lab Journal Collective Archive Workshop"
  local lines="Small things, made carefully.|Notes from a quiet corner of the internet.|We build and write about what we build.|An occasional journal of projects and ideas.|Work in progress, as always."
  local name kind line hue
  [ -f "$SITE_DIR/index.html" ] && return 0
  mkdir -p "$SITE_DIR"
  name=$(printf '%s\n' $names | sed -n "$(rand_int 1 12)p")
  kind=$(printf '%s\n' $kinds | sed -n "$(rand_int 1 8)p")
  line=$(printf '%s' "$lines" | tr '|' '\n' | sed -n "$(rand_int 1 5)p")
  hue=$(rand_int 0 359)
  cat >"$SITE_DIR/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$name $kind</title>
<style>
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:hsl($hue,25%,96%);color:hsl($hue,30%,18%);font:16px/1.6 system-ui,sans-serif}
main{max-width:32rem;padding:2rem}
h1{font-size:2rem;margin:0 0 .5rem}
p{margin:0;color:hsl($hue,15%,40%)}
</style>
</head>
<body><main><h1>$name $kind</h1><p>$line</p></main></body>
</html>
EOF
}

site_enable() {
  local id owner
  need_root
  need_installed
  detect_sys
  site_on_p && { say "$(t site_already)"; return 0; }
  { tls_real && ! tls_is_ip; } || die "$(t site_need_domain)"
  for id in $(protos_enabled); do
    [ "$id" = reality-vision ] && continue
    if [ "$(pmeta "$id" l4)" = tcp ] && [ "$(pmeta "$id" local)" != 1 ] && [ "$(pget "$id" port)" = 443 ]; then
      die "$(t site_port_taken "$(pmeta "$id" title)")"
    fi
  done
  if ! testing && port_in_use tcp 443 && ! { proto_enabled reality-vision && [ "$(pget reality-vision port)" = 443 ]; }; then
    owner=$(port_owner tcp 443)
    die "$(t site_443_busy "${owner:-?}")"
  fi
  head1 "$(t site_plan_title)"
  say "$(t site_plan "$(gget tls_domain)")"
  say ""
  confirm "$(t dom_plan_q)" || die "$(t cancelled)"
  nginx_ensure || die "$(t site_nginx_fail)"
  site_builtin_write
  edit_begin
  gset site on
  [ -n "$(gget site_port)" ] || gset site_port "$(random_port tcp)"
  [ -n "$(gget site_front_port)" ] || gset site_front_port "$(random_port tcp)"
  edit_end
  say "${C_G}$(t site_on_done "$(gget tls_domain)")${C_0}"
}

site_disable() {
  local id
  need_root
  need_installed
  detect_sys
  site_on_p || { say "$(t site_not_on)"; return 0; }
  for id in $(protos_enabled); do
    [ "$(pmeta "$id" behind)" = site ] && die "$(t site_in_use "$(pmeta "$id" title)")"
  done
  [ -n "$(gget cdn_host)" ] && die "$(t site_cdn_in_use)"
  edit_begin
  gset site off
  edit_end
  say "$(t site_off_done)"
}

site_set_source() { # <builtin|https://网址>
  local v="${1:-}"
  need_root
  need_installed
  detect_sys
  case "$v" in
    builtin) ;;
    https://*)
      valid_domain "$(printf '%s' "$v" | sed 's#^https://##; s#/.*##')" || die "$(t site_bad_source)"
      v="https://$(printf '%s' "$v" | sed 's#^https://##; s#/.*##')"
      testing || fetch --max-time 10 -o /dev/null "$v" 2>/dev/null || die "$(t site_source_down "$v")"
      ;;
    *) die "$(t site_bad_source)" ;;
  esac
  edit_begin
  gset site_source "$v"
  edit_end
}

site_status() {
  if site_on_p; then
    say "$(t site_status_on "$(gget tls_domain)" "$(site_source)")"
    [ -n "$(gget cdn_host)" ] && say "$(t cdn_status "$(gget cdn_host)")"
  else
    say "$(t site_not_on)"
  fi
}

# 体检：从本机按域名访问一次，证书要能验证通过，网页要有内容
d_site() {
  local dom code
  site_on_p || return 0
  dom=$(gget tls_domain)
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$dom:443:127.0.0.1" "https://$dom/" 2>/dev/null)
  case "$code" in
    2?? | 3??) ok "$(t d_site_ok "$dom")" ;;
    *)
      bad "$(t d_site_bad "$dom" "${code:-000}")"
      hint "$LOGDIR/nginx.log"
      return 1
      ;;
  esac
}

# 这个名字是否已经在 Cloudflare 的代理后面。Cloudflare 的边缘对任何打开了代理的名字
# 都会回应这个路径，与回源是否正常无关。用不加密的 HTTP：二级以下的子域名不在
# Cloudflare 免费证书的范围内，HTTPS 反而会失败；这里只读一段公开信息，不传任何数据。
cf_proxied() {
  testing && { [ "${PBOX_TEST_CF:-0}" = 1 ]; return; }
  curl -sL --max-time 10 "http://$1/cdn-cgi/trace" 2>/dev/null | grep -x "h=$1" >/dev/null
}

# 套 CDN 的子域名。它和直连用的域名分开：打开代理后这个名字解析到 Cloudflare，
# 直连协议用它会连不上。证书重签一次，同时写上两个名字，Cloudflare 的"完全（严格）"模式才能通过。
site_cdn_set() { # <子域名>
  local h="${1:-}" proxied=0 ip4 ip6 owner method
  need_root
  need_installed
  detect_sys
  site_on_p || die "$(t cdn_need_site)"
  h=$(printf '%s' "$h" | tr 'A-Z' 'a-z')
  valid_domain "$h" || die "$(t bad_domain "$h")"
  [ "$h" = "$(gget tls_domain)" ] && die "$(t cdn_same_domain)"
  [ "$h" = "$(gget cdn_host)" ] && { say "$(t cdn_already "$h")"; return 0; }
  method=$(gget tls_method http)
  ip4=$(gget ip4) ip6=$(gget ip6)
  if cf_proxied "$h"; then
    proxied=1
  elif ! { [ -n "$ip4" ] && resolve A "$h" | grep -qxF "$ip4"; } && ! { [ -n "$ip6" ] && resolve AAAA "$h" | grep -qxF "$ip6"; }; then
    die "$(t cdn_no_dns "$h" "${ip4:-$ip6}")"
  fi
  if [ "$method" != dns ] && ! testing && port_in_use tcp 80; then
    owner=$(port_owner tcp 80)
    die "$(t dom_80_busy "${owner:-?}")"
  fi
  head1 "$(t cdn_plan_title)"
  say "$(t cdn_plan "$h" "$(gget tls_domain)")"
  say ""
  confirm "$(t dom_plan_q)" || die "$(t cancelled)"
  if ! domain_issue "$(gget tls_domain)" "$method" "$h" "" force; then
    if [ "$method" != dns ] && [ $proxied = 1 ]; then die "$(t cdn_issue_fail_proxied "$LOGDIR/acme.log")"; fi
    die "$(t dom_issue_fail "$LOGDIR/acme.log")"
  fi
  domain_install_cert "$(gget tls_domain)" || die "$(t dom_issue_fail "$LOGDIR/acme.log")"
  edit_begin
  gset cdn_host "$h"
  edit_end
  say "${C_G}$(t cdn_done "$h")${C_0}"
  [ $proxied = 1 ] || note "$(t cdn_turn_on "$h")"
  note "$(t cdn_ssl_mode)"
}

# 关掉后证书重签成只有主域名，否则续期时还会去验证那个可能已经删掉的子域名
site_cdn_off() {
  local core
  need_root
  need_installed
  detect_sys
  [ -n "$(gget cdn_host)" ] || { say "$(t cdn_not_set)"; return 0; }
  edit_begin
  gset cdn_host ""
  edit_end
  if domain_issue "$(gget tls_domain)" "$(gget tls_method http)" "" "" force && domain_install_cert "$(gget tls_domain)"; then
    testing || for core in $(cores_needed); do svc restart "$(core_svc "$core")"; done
  else
    warn "$(t cdn_off_reissue_fail "$LOGDIR/acme.log")"
  fi
  say "$(t cdn_off_done)"
}

# 体检：经 Cloudflare 真实访问一次子域名。回源失败时 Cloudflare 返回 52x
d_cdn() {
  local h code
  h=$(gget cdn_host)
  [ -n "$h" ] || return 0
  if ! cf_proxied "$h"; then
    bad "$(t d_cdn_not_proxied "$h")"
    return 1
  fi
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$h/" 2>/dev/null)
  case "$code" in
    2?? | 3??) ok "$(t d_cdn_ok "$h")" ;;
    52?)
      bad "$(t d_cdn_origin "$h" "$code")"
      hint "$(t cdn_ssl_mode)"
      return 1
      ;;
    *)
      bad "$(t d_cdn_bad "$h" "${code:-000}")"
      return 1
      ;;
  esac
}

# pbox site [status|on|off|source <builtin|https://网址>|cdn <子域名|off>]
cmd_site() {
  case "${1:-status}" in
    on) site_enable ;;
    off) site_disable ;;
    source) site_set_source "${2:-}" ;;
    cdn) if [ "${2:-}" = off ]; then site_cdn_off; else site_cdn_set "${2:-}"; fi ;;
    status) need_root; need_installed; site_status ;;
    *) cmd_help ;;
  esac
}
