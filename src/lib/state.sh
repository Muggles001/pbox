# 状态文件是一行一个"键=值"的纯文本。读取时不 source，避免把值当代码执行。
kv_get() { # <文件> <键> [默认值]
  local v=""
  [ -f "$1" ] && v=$(sed -n "s/^$2=//p" "$1" | head -1)
  printf '%s' "${v:-${3:-}}"
}

kv_set() { # <文件> <键> <值>
  local f="$1" k="$2" v="$3" tmp
  mkdir -p "$(dirname "$f")"
  tmp="$f.tmp.$$"
  {
    [ -f "$f" ] && grep -v "^$k=" "$f"
    printf '%s=%s\n' "$k" "$v"
  } >"$tmp"
  mv "$tmp" "$f"
}

gget() { kv_get "$CUR/global.env" "$1" "${2:-}"; }
gset() { kv_set "$CUR/global.env" "$1" "$2"; }
pget() { kv_get "$CUR/protocols/$1.env" "$2" "${3:-}"; }
pset() { kv_set "$CUR/protocols/$1.env" "$2" "$3"; }
uget() { kv_get "$CUR/users/$1.env" "$2" "${3:-}"; }
uset() { kv_set "$CUR/users/$1.env" "$2" "$3"; }

# 按 PROTO_ALL 的固定顺序列出，界面和节点输出的次序因此稳定
protos_enabled() {
  local id
  for id in $PROTO_ALL; do
    [ -f "$CUR/protocols/$id.env" ] && echo "$id"
  done
  return 0
}

users_list() {
  local f
  for f in "$CUR"/users/*.env; do
    [ -f "$f" ] && basename "$f" .env
  done
}

# 每个用户可以带一份协议名单（空格分隔）；留空表示全部协议都对他生效
user_has() { # <用户> <协议>
  local l
  l=$(uget "$1" protocols)
  [ -z "$l" ] && return 0
  case " $l " in *" $2 "*) return 0 ;; esac
  return 1
}

proto_users() { # <协议> → 能用它的用户
  local u
  for u in $(users_list); do
    user_has "$u" "$1" && echo "$u"
  done
  return 0
}

# 客户端模仿哪种浏览器的握手特征。只影响给客户端的输出，服务端不关心。
FP_CHOICES="chrome firefox safari ios android edge random"
fp_of() { pget "$1" fp chrome; }

# 哪个协议有哪个可调项。命令和菜单都问这里，新增协议时只改这一处
proto_opt() { # <协议> <sni|path|fp|cdn>
  case "$2" in
    sni) case "$1" in reality-vision | reality-xhttp | shadowtls) return 0 ;; esac ;;
    path) case "$1" in vless-ws | vless-wstls | vmess | reality-xhttp) return 0 ;; esac ;;
    fp) case "$1" in reality-vision | vless-ws | trojan | vless-wstls | vmess | reality-xhttp | shadowtls) return 0 ;; esac ;;
    # 伪装站上的 WS 要先设了套 CDN 的子域名才有优选可言
    cdn) case "$1" in vless-ws) return 0 ;; vless-wstls | vmess) [ -n "$(gget cdn_host)" ] && return 0 ;; esac ;;
  esac
  return 1
}

# 写进节点信息的端口。NAT 机器上监听的是内网端口，客户端要连的是商家转发出来的外网端口。
# 挂在 443 分流后面的协议，对外永远是 443。
pubport() {
  local e p m
  if [ "$(pmeta "$1" behind)" = site ]; then
    p=443
  else
    e=$(pget "$1" ext_port)
    p="${e:-$(pget "$1" port)}"
  fi
  # 经中转机的节点：换成中转机上对应的端口（NODE_VIA 由 node_each 设置，见 relay.sh）
  for m in ${NODE_VIA:-}; do [ "${m%%=*}" = "$p" ] && { p=${m#*=}; break; }; done
  printf '%s' "$p"
}

proto_enabled() { [ -f "$CUR/protocols/$1.env" ]; }

# 协议模块的统一调用入口：pcall <协议> <函数> [参数]
pcall() {
  local id="$1" fn="$2"
  shift 2
  "proto_${id//-/_}_$fn" "$@"
}
proto_known() { declare -F "proto_${1//-/_}_meta" >/dev/null; }
pmeta() { pcall "$1" meta "$2"; }

# 安装时的设置来源，优先级：环境变量 PBOX_<键> > 应答文件 > 空。
opt() {
  local k="PBOX_$1" v
  v="${!k:-}"
  [ -z "$v" ] && [ -n "${ANSWERS:-}" ] && v=$(kv_get "$ANSWERS" "$1")
  printf '%s' "$v"
}

# 事务：所有改动先写进临时副本，校验通过才替换正式状态。
txn_begin() {
  rm -rf "$ETC/.txn"
  mkdir -p "$ETC/.txn/state/protocols" "$ETC/.txn/state/users"
  [ -d "$STATE" ] && cp -R "$STATE/." "$ETC/.txn/state/"
  CUR="$ETC/.txn/state"
}

txn_abort() {
  rm -rf "$ETC/.txn"
  CUR="$STATE"
}

user_new() { # <用户名>
  uset "$1" uuid "$(gen_uuid)"
  uset "$1" password "$(rand_str "$(rand_int 20 32)")"
  [ -n "$(uget "$1" sub_key)" ] || uset "$1" sub_key "$(rand_str 12)"
}
