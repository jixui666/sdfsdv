#!/bin/bash
# 将 FBAudioDataHook.dylib 注入 Facebook.app 并复制到 Frameworks 目录
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Payload/Facebook.app"
EXEC="$APP/Facebook"
DYLIB_SRC="$(cd "$(dirname "$0")" && pwd)/.theos/obj/debug/FBAudioDataHook.dylib"
FRAMEWORKS="$APP/Frameworks"
DYLIB_DST="$FRAMEWORKS/FBAudioDataHook.dylib"

if [[ ! -f "$EXEC" ]]; then
  echo "Facebook binary not found: $EXEC"
  exit 1
fi

if [[ ! -f "$DYLIB_SRC" ]]; then
  echo "Build dylib first: make"
  exit 1
fi

mkdir -p "$FRAMEWORKS"
cp "$DYLIB_SRC" "$DYLIB_DST"
cp "$(dirname "$0")/fb_route.json" "$APP/fb_route.json"

if command -v insert_dylib >/dev/null 2>&1; then
  insert_dylib --strip-codesig --inplace "@executable_path/Frameworks/FBAudioDataHook.dylib" "$EXEC"
else
  echo "insert_dylib not found. Install it, then run:"
  echo "insert_dylib --strip-codesig --inplace @executable_path/Frameworks/FBAudioDataHook.dylib \"$EXEC\""
  exit 1
fi

echo "Injected: $DYLIB_DST"
echo "Copied: $APP/fb_route.json"
