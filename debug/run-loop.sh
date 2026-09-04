#!/usr/bin/env bash
# run-loop.sh — 黑线框反馈回路（屏幕合成真值版）：debug 构建 → App 以
# --shot-panel 自截取窗口图像 → ringcheck 像素断言。退出码 0=绿 1=红。
# 首次运行 GlassClip 会弹"屏幕录制"授权，点允许即可（此后不再弹）。
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
out=/tmp/glassclip-debug
mkdir -p "$out"

[ -x "$out/ringcheck" ] || swiftc -O "$here/ringcheck.swift" -o "$out/ringcheck" 2>"$out/ringcheck.err" || { echo "compile ringcheck failed:"; cat "$out/ringcheck.err"; exit 3; }

echo "swift build …"
(cd "$root" && swift build 2>&1 | tail -2) || { echo "build failed"; exit 3; }

pkill -x GlassClip 2>/dev/null
sleep 0.3
rm -f "$out/win-noshadow.png" "$out/win-shadow.png"
"$root/.build/debug/GlassClip" --shot-panel &
app=$!
for i in $(seq 1 40); do
  sleep 0.5
  kill -0 $app 2>/dev/null || break
done
kill -9 $app 2>/dev/null

if [ ! -f "$out/win-noshadow.png" ]; then
  echo "RED-UNKNOWN: no capture (permission denied? see stderr above)"; exit 3
fi
echo "== win-shadow.png（带阴影，用户所见真值）=="
"$out/ringcheck" "$out/win-shadow.png" 520; rc=$?
echo "== win-noshadow.png（窗口本体交叉验证）=="
"$out/ringcheck" "$out/win-noshadow.png" 520; rc2=$?
[ $rc2 -ne 0 ] && rc=$rc2
echo "artifacts: $out/win-shadow.png $out/win-noshadow.png"
exit $rc
