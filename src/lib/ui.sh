if [ -t 1 ]; then
  C_R=$'\033[31m' C_G=$'\033[32m' C_Y=$'\033[33m' C_B=$'\033[1m' C_D=$'\033[2m' C_0=$'\033[0m'
else
  C_R="" C_G="" C_Y="" C_B="" C_D="" C_0=""
fi

# t <键> [参数...]：取当前语言的文案，按 printf 格式填入参数。
t() {
  local k="T_$1" f
  shift
  # 只有变量不存在时才回退显示键名；空字符串是合法的文案
  f="${!k-$k}"
  # shellcheck disable=SC2059
  printf "$f" "$@"
}

say() { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n\n' "$C_B" "$*" "$C_0"; }
ok() { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
bad() { printf '  %s✗%s %s\n' "$C_R" "$C_0" "$*"; }
note() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*"; }
hint() { printf '      → %s\n' "$*"; }
warn() { printf '%s! %s%s\n' "$C_Y" "$*" "$C_0" >&2; }
die() {
  printf '%s✗ %s%s\n' "$C_R" "$*" "$C_0" >&2
  unlock
  exit 1
}

# ask <提示> [默认值]，结果在 REPLY。--yes 时直接取默认值。
ask() {
  local d="${2:-}"
  if [ "$ASSUME_YES" = 1 ]; then
    REPLY="$d"
    return 0
  fi
  if [ -n "$d" ]; then printf '%s [%s]: ' "$1" "$d"; else printf '%s: ' "$1"; fi
  IFS= read -r REPLY || REPLY=""
  [ -z "$REPLY" ] && REPLY="$d"
  return 0
}

# confirm <提示> [默认 y|n]。--yes 视为同意。
confirm() {
  local d="${2:-y}" a
  [ "$ASSUME_YES" = 1 ] && return 0
  if [ "$d" = y ]; then printf '%s [Y/n]: ' "$1"; else printf '%s [y/N]: ' "$1"; fi
  IFS= read -r a || a=""
  case "${a:-$d}" in y | Y | yes) return 0 ;; esac
  return 1
}

# 软冲突用：默认取消，必须明确输入 y；--yes 不代答。
confirm_risk() {
  local a
  [ "$ASSUME_YES" = 1 ] && return 1
  printf '%s [y/N]: ' "$1"
  IFS= read -r a || a=""
  case "$a" in y | Y) return 0 ;; esac
  return 1
}

i18n_load() {
  case "$1" in en) i18n_en ;; *) i18n_zh ;; esac
  LANG_CODE="$1"
}

# 已安装时用保存的语言；否则用 PBOX_LANG；都没有就问一次，默认中文。
lang_init() {
  local l
  l=$(kv_get "$STATE/global.env" lang)
  [ -z "$l" ] && l="${PBOX_LANG:-}"
  if [ -z "$l" ]; then
    if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then
      l=zh
    else
      printf '1 中文   2 English [1]: '
      IFS= read -r l || l=""
      case "$l" in 2) l=en ;; *) l=zh ;; esac
    fi
  fi
  i18n_load "$l"
}
