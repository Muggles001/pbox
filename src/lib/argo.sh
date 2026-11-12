# Argo 临时隧道：cloudflared 主动连到 Cloudflare，得到一个 trycloudflare.com 的域名。
# 不需要 Cloudflare 账号。域名在每次 cloudflared 重启后都会变，所以启动后要重新取一次并更新节点。

argo_wanted() { [ -f "$STATE/protocols/vless-ws.env" ]; }
argo_bin() { echo "$BINDIR/cloudflared"; }

# 和内核一样：锁定版本、校验哈希后才安装
argo_ensure() {
  local k tmp
  testing && return 0
  [ "$(kv_get "$LIBDIR/installed.env" cloudflared)" = "$CLOUDFLARED_VERSION" ] && [ -x "$(argo_bin)" ] && return 0
  k="CLOUDFLARED_SHA256_$ARCH"
  tmp=$(mktemp -d) || return 1
  say "$(t dl_fetch "cloudflared $CLOUDFLARED_VERSION")"
  if ! dl_verify "https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/cloudflared-linux-$ARCH" "${!k}" "$tmp/cloudflared"; then
    rm -rf "$tmp"
    return 1
  fi
  mkdir -p "$BINDIR"
  install -m 0755 "$tmp/cloudflared" "$(argo_bin)" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  kv_set "$LIBDIR/installed.env" cloudflared "$CLOUDFLARED_VERSION"
}

# 从 cloudflared 的本地接口读取隧道域名，不去解析它的日志。最多等 40 秒。
argo_fetch_host() {
  local mp h i=0
  mp=$(kv_get "$STATE/protocols/vless-ws.env" metrics_port)
  while [ $i -lt 20 ]; do
    h=$(curl -s --max-time 3 "http://127.0.0.1:$mp/quicktunnel" 2>/dev/null | sed -n 's/.*"hostname":"\([^"]*\)".*/\1/p')
    [ -n "$h" ] && { printf '%s' "$h"; return 0; }
    sleep 2
    i=$((i + 1))
  done
  return 1
}

# 取回当前的隧道域名；有变化就更新节点并推送订阅。
argo_sync() {
  local h
  testing && return 0
  argo_wanted || return 0
  [ "$(kv_get "$STATE/protocols/vless-ws.env" temp on)" = on ] || return 0
  h=$(argo_fetch_host) || return 1
  [ "$h" = "$(kv_get "$STATE/protocols/vless-ws.env" argo_host)" ] && return 0
  kv_set "$STATE/protocols/vless-ws.env" argo_host "$h"
  nodes_write
  sub_push
  return 0
}

argo_svc_exists() { [ -f "/etc/systemd/system/$1.service" ] || [ -f "/etc/init.d/$1" ]; }

# 按当前状态让隧道服务生效。每次改动生效后调用。
# 临时隧道和固定隧道是两个独立的服务，可以同时运行，都把请求转给同一个本机入站。
argo_apply() {
  local port mp f="$STATE/protocols/vless-ws.env"
  if testing; then
    # 测试里没有真的隧道，放一个示例域名让节点输出可以被检查
    if argo_wanted && [ -z "$(kv_get "$f" argo_host)" ]; then
      kv_set "$f" argo_host "example-test.trycloudflare.com"
      nodes_write
    fi
    return 0
  fi
  if ! argo_wanted; then
    argo_svc_exists pbox-argo && svc_remove pbox-argo
    argo_svc_exists pbox-argo-fixed && svc_remove pbox-argo-fixed
    return 0
  fi
  port=$(kv_get "$f" port)
  mp=$(kv_get "$f" metrics_port)
  if [ -f "$STATE/argo-fixed.env" ]; then
    # 有令牌就运行，不必等域名填好：Cloudflare 后台要求连接器先连上，才能继续设置域名。
    # 令牌放在只有 root 可读的文件里交给服务，不出现在命令行和服务文件中。
    svc_write pbox-argo-fixed "$(argo_bin) tunnel --no-autoupdate --protocol http2 --metrics 127.0.0.1:$(kv_get "$f" fixed_metrics) run" 0 "EnvironmentFile=$STATE/argo-fixed.env"
    svc enable pbox-argo-fixed
    if ! svc active pbox-argo-fixed; then svc start pbox-argo-fixed; elif [ "${UNIT_CHANGED:-0}" = 1 ]; then svc restart pbox-argo-fixed; fi
  else
    argo_svc_exists pbox-argo-fixed && svc_remove pbox-argo-fixed
  fi
  if [ "$(kv_get "$f" temp on)" = on ]; then
    # 用 HTTP/2 连 Cloudflare，不依赖 UDP 出站。
    # 开机自启时由服务自己触发一次同步（放到后台，不阻塞启动）；域名变了节点才会跟着更新。
    svc_write pbox-argo "$(argo_bin) tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:$port --metrics 127.0.0.1:$mp" 0 \
      "ExecStartPost=+/bin/sh -c 'nohup $LIBDIR/pbox.sh argo-sync >/dev/null 2>&1 &'"
    svc enable pbox-argo
    if ! svc active pbox-argo; then svc start pbox-argo; elif [ "${UNIT_CHANGED:-0}" = 1 ]; then svc restart pbox-argo; fi
    argo_sync
  else
    argo_svc_exists pbox-argo && svc_remove pbox-argo
  fi
}

# 固定隧道的连接器是否已经连上 Cloudflare。最多等 30 秒。
argo_fixed_ready() {
  local mp i=0
  testing && return 0
  mp=$(kv_get "$STATE/protocols/vless-ws.env" fixed_metrics)
  while [ $i -lt 15 ]; do
    curl -fs --max-time 3 -o /dev/null "http://127.0.0.1:$mp/ready" 2>/dev/null && return 0
    sleep 2
    i=$((i + 1))
  done
  return 1
}

argo_status() {
  local f="$STATE/protocols/vless-ws.env"
  [ -f "$f" ] || die "$(t argo_need_proto)"
  if [ "$(kv_get "$f" temp on)" = on ]; then say "$(t argo_st_temp "$(kv_get "$f" argo_host -)")"; else say "$(t argo_st_temp_off)"; fi
  if [ -n "$(kv_get "$f" fixed_host)" ]; then say "$(t argo_st_fixed "$(kv_get "$f" fixed_host)")"; else say "$(t argo_st_fixed_off)"; fi
  say "$(t argo_st_port "$(kv_get "$f" port)")"
}

# pbox argo <status|fixed <域名>|fixed off|temp <on|off>>
cmd_argo() {
  local act="${1:-status}" val="${2:-}" tok
  need_root
  need_installed
  if [ "$act" = status ]; then
    argo_status
    return 0
  fi
  [ -f "$STATE/protocols/vless-ws.env" ] || die "$(t argo_need_proto)"
  edit_begin
  case "$act" in
    fixed)
      if [ "$val" = off ]; then
        [ "$(pget vless-ws temp on)" = on ] || { txn_abort; die "$(t argo_need_one)"; }
        pset vless-ws fixed_host ""
        rm -f "$CUR/argo-fixed.env"
      else
        # 顺序跟随 Cloudflare 后台的流程：先拿令牌把连接器连上，再回后台设置域名，最后把域名填回来
        tok="${PBOX_ARGO_TOKEN:-}"
        if [ -z "$tok" ]; then
          [ "$ASSUME_YES" = 1 ] && { txn_abort; die "$(t argo_need_token)"; }
          say "$(t argo_fixed_step1)"
          say ""
          read_secret "$(t argo_ask_token)"
          tok="$REPLY"
        fi
        printf '%s' "$tok" | grep -Eq '^[A-Za-z0-9_=-]{20,}$' || { txn_abort; die "$(t argo_bad_token)"; }
        (umask 077 && printf 'TUNNEL_TOKEN=%s\n' "$tok" >"$CUR/argo-fixed.env")
        [ -n "$(pget vless-ws fixed_metrics)" ] || pset vless-ws fixed_metrics "$(random_port tcp)"
        if [ -z "$val" ]; then
          # 交互：先让连接器连上，用户才能在后台走下一步
          edit_end
          say ""
          say "$(t argo_fixed_wait)"
          if argo_fixed_ready; then
            say "${C_G}$(t argo_fixed_connected)${C_0}"
          else
            warn "$(t argo_fixed_notconn)"
          fi
          say ""
          say "$(t argo_fixed_step2 "$(pget vless-ws port)")"
          say ""
          ask "$(t argo_ask_host)" "$(pget vless-ws fixed_host)"
          val="$REPLY"
          txn_begin
        fi
        valid_domain "$val" || { txn_abort; die "$(t bad_domain "$val")"; }
        pset vless-ws fixed_host "$val"
      fi
      ;;
    temp)
      case "$val" in
        on) pset vless-ws temp on ;;
        off)
          [ -n "$(pget vless-ws fixed_host)" ] || { txn_abort; die "$(t argo_need_one)"; }
          pset vless-ws temp off
          ;;
        *) txn_abort; die "$(t argo_usage)" ;;
      esac
      ;;
    *) txn_abort; die "$(t argo_usage)" ;;
  esac
  edit_end
  argo_status
}

# 网友常用的优选地址。它们都是托管在 Cloudflare 上的站点或有人维护的优选域名：
# 客户端连到它们解析出的 Cloudflare 入口，再凭 Host 头回到自己的隧道。
# 是否可用、速度如何因地区和运营商而异；列在这里的只保证实测能连通隧道。
# 前四个是托管在 Cloudflare 上的知名站点；后三个是网友自建并维护的优选域名（会解析到他们测出的较快入口）。
# 七个都在 2026-11 实测能连通隧道。
ARGO_CDN_CHOICES="www.visa.com.sg www.shopify.com www.wto.org cloudflare-ech.com cf.090227.xyz cloudflare.182682.xyz yg1.ygkkk.dpdns.org"
