#!/bin/bash
# MIR Remote · 构建 APK
#
# 不用 Gradle：这个壳只有一个 Activity、不引外部库，
# 直接 aapt2 → javac → d8 → zipalign → apksigner，几秒钟出包，也不用联网拉依赖。
# 工具链借 voicecasterrecorder 那套（同一台机、同一把签名）。
#
# 用法：./tools/build.sh
# 产物：dist/mir-remote.apk
set -euo pipefail

TOOLS="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TOOLS/.." && pwd)"
APP="$ROOT/app"
SRC_TOOLS="$ROOT/../../voicecasterrecorder/tools"

# 工具链：优先自己的 tools/，没有就用录音 App 那套
if [ ! -e "$TOOLS/android-sdk" ] && [ -e "$SRC_TOOLS/android-sdk" ]; then
  ln -sfn "$SRC_TOOLS/android-sdk" "$TOOLS/android-sdk"
fi
if ! ls "$TOOLS"/zulu* >/dev/null 2>&1 && ls "$SRC_TOOLS"/zulu* >/dev/null 2>&1; then
  for d in "$SRC_TOOLS"/zulu*; do ln -sfn "$d" "$TOOLS/$(basename "$d")"; done
fi
if [ ! -e "$TOOLS/vc.jks" ] && [ -e "$SRC_TOOLS/vc.jks" ]; then
  ln -sfn "$SRC_TOOLS/vc.jks" "$TOOLS/vc.jks"
fi

# ── 找 JDK ──
JAVA_HOME=""
for d in "$TOOLS"/zulu* "$TOOLS"/jdk*; do
  [ -d "$d" ] || continue
  for c in "$d" "$d/zulu-17.jdk/Contents/Home" "$d/Contents/Home"; do
    if [ -x "$c/bin/javac" ]; then JAVA_HOME="$c"; break 2; fi
  done
done
if [ -z "$JAVA_HOME" ]; then
  echo "✗ 没找到 JDK（voicecasterrecorder/tools 里那套在不在？）" >&2
  exit 1
fi
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

SDK="$TOOLS/android-sdk"
BT="$SDK/build-tools/34.0.0"
AJ="$SDK/platforms/android-34/android.jar"
for f in "$BT/aapt2" "$BT/d8" "$BT/zipalign" "$BT/apksigner" "$AJ"; do
  if [ ! -e "$f" ]; then
    echo "✗ 缺 $f" >&2
    exit 1
  fi
done

OUT="$ROOT/build"
DIST="$ROOT/dist"
rm -rf "$OUT"
mkdir -p "$OUT/gen" "$OUT/classes" "$OUT/dex" "$DIST"

echo "▸ 1/6 编译资源"
"$BT/aapt2" compile --dir "$APP/res" -o "$OUT/res.zip"

echo "▸ 2/6 链接资源"
"$BT/aapt2" link -o "$OUT/base.apk" \
  -I "$AJ" \
  --manifest "$APP/AndroidManifest.xml" \
  -R "$OUT/res.zip" \
  --java "$OUT/gen" \
  --min-sdk-version 26 --target-sdk-version 34 \
  --auto-add-overlay

echo "▸ 3/6 编译 Java"
find "$APP/src" "$OUT/gen" -name "*.java" > "$OUT/sources.txt"
"$JAVA_HOME/bin/javac" -nowarn \
  -source 8 -target 8 \
  -classpath "$AJ" \
  -d "$OUT/classes" \
  @"$OUT/sources.txt" 2>&1 | grep -v "^注意" || true

if [ ! -f "$OUT/classes/com/jieda/mirremote/MainActivity.class" ]; then
  echo "✗ Java 没编出来" >&2
  exit 1
fi

echo "▸ 4/6 转 dex"
find "$OUT/classes" -name "*.class" > "$OUT/classes.txt"
"$BT/d8" --lib "$AJ" --min-api 26 --release \
  --output "$OUT/dex" @"$OUT/classes.txt"

echo "▸ 5/6 打包 + 对齐"
cp "$OUT/base.apk" "$OUT/unsigned.apk"
( cd "$OUT/dex" && zip -q -X "$OUT/unsigned.apk" classes.dex )
"$BT/zipalign" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

echo "▸ 6/6 签名"
KS="$TOOLS/vc.jks"
if [ ! -f "$KS" ]; then
  echo "✗ 没找到签名文件 vc.jks" >&2
  exit 1
fi
"$BT/apksigner" sign --ks "$KS" --ks-key-alias vc \
  --ks-pass pass:voicecaster --key-pass pass:voicecaster \
  --out "$DIST/mir-remote.apk" "$OUT/aligned.apk"

"$BT/apksigner" verify --print-certs "$DIST/mir-remote.apk" | head -3
echo
echo "✅ 好了：$DIST/mir-remote.apk  ($(du -h "$DIST/mir-remote.apk" | cut -f1))"
