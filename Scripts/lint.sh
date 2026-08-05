#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

if rg -n '(^|[^A-Za-z0-9_])print\(' LayoutLock --glob '*.swift'; then
  echo "Production print() calls are not allowed." >&2
  exit 1
fi
