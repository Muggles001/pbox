# 伪装站与 443 分流。需要先有域名证书。
#
# 开启后由 Nginx 监听 TCP 443，只看握手里的域名、不解密，把连接分给两处：
#   握手里是自己的域名 → Nginx 自己的网站（用域名证书），浏览器访问域名看到的是一个正常网页；
#   其余的（包括 Reality 的伪装目标、不认识的域名、不带域名的）→ Reality 入站，行为与没有分流时相同。
# Reality 没有启用或不在 443 上时，其余的连接由网站那一侧拒绝握手。
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
      apk) pk="nginx nginx-mod-stream" ;;
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
  local dom sp rp mod src host certs="${CERTS#"$R"}" var="${VARDIR#"$R"}" log="${LOGDIR#"$R"}" site="${SITE_DIR#"$R"}"
  dom=$(gget tls_domain) sp=$(gget site_port) src=$(site_source)
  mod=$(nginx_stream_mod)
  [ -n "$mod" ] && echo "load_module $mod;"
  cat <<EOF
worker_processes 1;
pid $var/nginx.pid;
error_log $log/nginx.log crit;
events { worker_connections 1024; }

stream {
  map \$ssl_preread_server_name \$pbox_up {
    $dom 127.0.0.1:$sp;
EOF
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
    server_name $dom;
EOF
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
  cat <<EOF
  }
}
EOF
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
  need_root
  need_installed
  detect_sys
  site_on_p || { say "$(t site_not_on)"; return 0; }
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

# pbox site [status|on|off|source <builtin|https://网址>]
cmd_site() {
  case "${1:-status}" in
    on) site_enable ;;
    off) site_disable ;;
    source) site_set_source "${2:-}" ;;
    status) need_root; need_installed; site_status ;;
    *) cmd_help ;;
  esac
}
