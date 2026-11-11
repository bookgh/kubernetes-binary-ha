#!/usr/bin/env bash
# 验证仓库 JSON 配置有效且采用多行、双空格缩进格式。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '[ERROR] missing command: %s\n' "$1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd cmp
require_cmd find

checked=0
while IFS= read -r -d '' file; do
  formatted="$(mktemp)"
  trap 'rm -f "$formatted"' EXIT

  jq . "$file" > "$formatted" || {
    printf '[ERROR] invalid JSON: %s\n' "$file" >&2
    exit 1
  }

  if ! cmp -s "$file" "$formatted"; then
    printf '[ERROR] JSON must use jq-compatible pretty formatting: %s\n' "$file" >&2
    diff -u "$file" "$formatted" || true
    exit 1
  fi

  if (( $(wc -l < "$file") < 2 )); then
    printf '[ERROR] JSON must not be compressed into one line: %s\n' "$file" >&2
    exit 1
  fi

  rm -f "$formatted"
  trap - EXIT
  checked=$((checked + 1))
done < <(find "$ROOT/config" -type f -name '*.json' -print0 | sort -z)

printf '[PASS] validated %s formatted JSON files.\n' "$checked"
