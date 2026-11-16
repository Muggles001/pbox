#!/usr/bin/env bash
# 生成发布物里的改动清单 dist/changes.txt：每行"版本<TAB>一句话"，新版本在前，包含全部历史版本，
# 所以隔了好几个版本才更新的机器也能一次看全。一句话取自提交说明的第一行，去掉末尾的版本号。
# 需要完整的提交历史和标签。
set -euo pipefail
cd "$(dirname "$0")/.."
for t in $(git tag -l 'v*' --sort=-v:refname); do
  p=$(git describe --tags --abbrev=0 --match 'v*' "$t^" 2>/dev/null || true)
  git log --no-merges --format=%s "${p:+$p..}$t" |
    sed -e 's/；版本 [0-9.]*$//' -e '/^版本 [0-9.]*$/d' |
    awk -v t="$t" 'NF {print t "\t" $0}'
done >dist/changes.txt
