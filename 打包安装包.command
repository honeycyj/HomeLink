#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if "$TASK_ROOT/script/package.sh" --reveal; then
  echo '打包完成，已在 Finder 中选中安装包，可以复制给其他 Mac。'
else
  echo '打包失败，请将上面的错误信息交给开发者检查。' >&2
  if [[ -t 0 ]]; then read -r -p '按回车关闭窗口…' _; fi
  exit 1
fi
