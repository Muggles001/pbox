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
  h=$(argo_fetch_host) || return 1
  [ "$h" = "$(kv_get "$STATE/protocols/vless-ws.env" argo_host)" ] && return 0
  kv_set "$STATE/protocols/vless-ws.env" argo_host "$h"
  nodes_write
  sub_push
  return 0
}

# 按当前状态让隧道服务生效。每次改动生效后调用。
argo_apply() {
  local port mp
  if testing; then
    # 测试里没有真的隧道，放一个示例域名让节点输出可以被检查
    if argo_wanted && [ -z "$(kv_get "$STATE/protocols/vless-ws.env" argo_host)" ]; then
      kv_set "$STATE/protocols/vless-ws.env" argo_host "example-test.trycloudflare.com"
      nodes_write
    fi
    return 0
  fi
  if ! argo_wanted; then
    [ -f /etc/systemd/system/pbox-argo.service ] || [ -f /etc/init.d/pbox-argo ] && svc_remove pbox-argo
    return 0
  fi
  port=$(kv_get "$STATE/protocols/vless-ws.env" port)
  mp=$(kv_get "$STATE/protocols/vless-ws.env" metrics_port)
  # 用 HTTP/2 连 Cloudflare，不依赖 UDP 出站。
  # 开机自启时由服务自己触发一次同步（放到后台，不阻塞启动）；域名变了节点才会跟着更新。
  svc_write pbox-argo "$(argo_bin) tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:$port --metrics 127.0.0.1:$mp" 0 \
    "ExecStartPost=+/bin/sh -c 'nohup $LIBDIR/pbox.sh argo-sync >/dev/null 2>&1 &'"
  svc enable pbox-argo
  if ! svc active pbox-argo; then
    svc start pbox-argo
  elif [ "${UNIT_CHANGED:-0}" = 1 ]; then
    svc restart pbox-argo
  fi
  argo_sync
}

# 网友常用的优选地址。它们都是托管在 Cloudflare 上的站点或有人维护的优选域名：
# 客户端连到它们解析出的 Cloudflare 入口，再凭 Host 头回到自己的隧道。
# 是否可用、速度如何因地区和运营商而异；列在这里的只保证实测能连通隧道。
# 前四个是托管在 Cloudflare 上的知名站点；后三个是网友自建并维护的优选域名（会解析到他们测出的较快入口）。
# 七个都在 2026-11 实测能连通隧道。
ARGO_CDN_CHOICES="www.visa.com.sg www.shopify.com www.wto.org cloudflare-ech.com cf.090227.xyz cloudflare.182682.xyz yg1.ygkkk.dpdns.org"
