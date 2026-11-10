#!/bin/bash
# ==============================================================================
# heartmula_adapter.sh — 界面 与 HeartMuLa 3B（audio.cpp 的 GGUF 量化版）之间唯一的桥
#
# 它与 render_adapter.sh / yue2_adapter.sh / stable_audio_adapter.sh **同一套契约**：
#   界面写 params.json → 本脚本写 progress.json → 界面读进度、显示产物。
#   退出码也一致。界面上只是多了一个脚本名，其余（进度轮询、停止、试听、
#   导出、在文件夹里看）全部照旧。
#
# 它是 2026-11-10 接的第三台引擎。用户听完它的声音后定的：
#   "旋律写得不差、人声特别干净"；伴奏"不够打"，拿出去精修就行。
#   ⇒ 它的定位是**人声/词草稿机**，不是成品引擎。
#
# 它跑的是本机已经装好的那套 audio.cpp（C++/GGML），**不另装 Python 环境**：
#   audio.cpp      … 推理框架（Metal）
#   audiocpp-bin   … 编好的 audiocpp_cli
#   models/HeartMuLa-GGUF … 7.1GB 的量化权重（Q8）
# 这个脚本只做四件事：
#   1. 把界面的参数翻成它的命令行（歌词 + 英文风格标签 + 时长上限 + 种子）
#   2. 跑生成，按时间把进度往前推（它没有细粒度进度回调）
#   3. 把 wav 摆进这次新建的文件夹
#   4. 全程写 progress.json；本脚本自身不发起任何外部网络请求
#
# 用法：
#   ./heartmula_adapter.sh --params <参数.json> --out-dir <目录> --progress <progress.json>
#
# 参数 JSON（与另外几条共用同一套字段，只用得上前几个）：
#   { "prompt": "英文风格标签", "lyrics": "歌词", "duration": 180,
#     "seed": 42, "title": "这一首叫什么" }
#   ⚠️ **prompt 必须是英文标签**（如 "pop,female vocal,piano,90 bpm"）。
#      这台模型把标签当词表里的 token 匹配，中文标签基本等于没写（2026-11-10 实测）。
#   ⚠️ duration 只是**上限**：歌词唱完它就收尾。要 4–5 分钟得把词写长。
#
# 退出码：0 成功 / 2 参数错 / 3 模型加载失败 / 5 生成失败 / 6 超时被杀 / 7 缺环境
# ==============================================================================

set -uo pipefail
set +m

# ------------------------------ 可配置区 --------------------------------------
# audio.cpp 装在哪：默认是兄弟目录 ../audio.cpp，可用 HEARTMULA_ROOT 覆盖。
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${HEARTMULA_ROOT:-}" ]; then
  HM_ROOT="$HEARTMULA_ROOT"
else
  HM_ROOT="$(cd "$PROJECT_ROOT/../audio.cpp" 2>/dev/null && pwd || echo "")"
fi

# 命令行工具：默认在 audio.cpp 的兄弟目录 audiocpp-bin/ 里。
HM_CLI="${HEARTMULA_CLI:-$(cd "$PROJECT_ROOT/../audiocpp-bin" 2>/dev/null && pwd)/audiocpp_cli}"
HM_MODEL="${HEARTMULA_MODEL:-$HM_ROOT/models/HeartMuLa-GGUF}"

# 官方 3B 模型，实测：3 分钟中文歌约 4 分 11 秒（RTF 1.39，12GB 内存）。
# 时长上下限与其余引擎对齐（10–300 秒）；HeartMuLa 一次超过 300 秒也没意义，
# 真要长就得多给词、让它自然去唱。
MIN_SECONDS=10
MAX_SECONDS=300

# 等结果的硬上限（秒）。3 分钟歌约 4 分钟；5 分钟的整首按比例约 7–8 分钟。
# 留到 40 分钟，纯粹是防卡死，不是性能估计。
WATCHDOG_SECONDS=2400

FFMPEG="/opt/homebrew/bin/ffmpeg"
PY=/usr/bin/python3
# -----------------------------------------------------------------------------

die() { echo "[heartmula] $*" >&2; exit "${2:-5}"; }

PARAMS=""
OUT_DIR=""
PROGRESS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --params)   PARAMS="${2:-}"; shift 2 ;;
    --out-dir)  OUT_DIR="${2:-}"; shift 2 ;;
    --progress) PROGRESS="${2:-}"; shift 2 ;;
    *) die "不认识的参数：$1" 2 ;;
  esac
done

[ -n "$PARAMS" ] || die "缺 --params" 2
[ -f "$PARAMS" ] || die "参数文件不在：$PARAMS" 2

OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/output}"
mkdir -p "$OUT_DIR" || die "建不了输出目录：$OUT_DIR"
# ★ 先解析成绝对路径 —— 后面 cd 到别处就没法回头了。
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
PROGRESS="${PROGRESS:-$OUT_DIR/progress.json}"

[ -x "$HM_CLI" ] || die "audiocpp_cli 不在：${HM_CLI}（audio.cpp 那套装好了吗？）" 7
[ -d "$HM_MODEL" ] || die "HeartMuLa 的权重不在了：${HM_MODEL}" 7
[ -d "$HM_ROOT" ] || die "audio.cpp 的目录不在：${HM_ROOT}" 7

LOG="$OUT_DIR/.heartmula.log"

# ------------------------------ 进度文件 --------------------------------------

# write_progress <percent> <state> <message> [<output 的 JSON 值>] [<detail>]
# 全部交给 python 拼，拼完立刻 json.loads 验一遍 —— 手工拼 JSON 错得特别安静。
write_progress() {
  local pct="$1" state="$2" msg="$3" out="${4:-null}" detail="${5:-}"
  local tmp="${PROGRESS}.tmp"
  "$PY" - "$pct" "$state" "$msg" "$out" "$detail" > "$tmp" <<'JSONEOF'
import json, sys, time
pct, state, msg, out, detail = sys.argv[1:6]
doc = ('{"percent":%d,"state":%s,"message":%s,"detail":%s,"updated":%d,'
       '"output":%s,"score":null}'
       % (int(pct), json.dumps(state), json.dumps(msg), json.dumps(detail),
          int(time.time()), out))
json.loads(doc)
print(doc)
JSONEOF
  [ -s "$tmp" ] && mv -f "$tmp" "$PROGRESS"
}

LAST_PERCENT=0
set_percent() {
  local pct="$1" msg="$2" detail="${3:-}"
  [ "$pct" -lt "$LAST_PERCENT" ] && pct="$LAST_PERCENT"
  LAST_PERCENT="$pct"
  write_progress "$pct" "running" "$msg" "null" "$detail"
}

# ------------------------------ 读参数 ----------------------------------------

read_field() {  # read_field <字段> <默认值>
  "$PY" - "$PARAMS" "$1" "$2" <<'PYEOF'
import json, sys
try:
    p = json.load(open(sys.argv[1]))
except Exception:
    p = {}
v = p.get(sys.argv[2])
if v is None:
    print(sys.argv[3])
elif isinstance(v, (int, float)):
    print(v)
else:
    print(str(v))
PYEOF
}

PROMPT="$(read_field prompt "")"
LYRICS="$(read_field lyrics "")"
[ -n "$LYRICS" ] || die "这一台要唱词：先在「歌词」里写上（带 [Verse] / [Chorus] 这类段落标记更稳）。" 2
case "$LYRICS" in
  "[Instrumental]") die "HeartMuLa 只出有人声的歌，不做纯器乐：把歌词填上就行。" 2 ;;
esac

SECONDS_WANTED="$(read_field duration 180)"
case "$SECONDS_WANTED" in ''|*[!0-9.]*) SECONDS_WANTED=180 ;; esac
SECONDS_WANTED="${SECONDS_WANTED%%.*}"
[ "$SECONDS_WANTED" -lt "$MIN_SECONDS" ] 2>/dev/null && SECONDS_WANTED=$MIN_SECONDS
[ "$SECONDS_WANTED" -gt "$MAX_SECONDS" ] 2>/dev/null && SECONDS_WANTED=$MAX_SECONDS

SEED="$(read_field seed 42)"
case "$SEED" in ''|*[!0-9-]*) SEED=42 ;; esac
[ "$SEED" -lt 0 ] 2>/dev/null && SEED=42

TITLE="$("$PY" - "$PARAMS" <<'PYEOF'
import json, re, sys
try:
    p = json.load(open(sys.argv[1]))
except Exception:
    p = {}
t = (p.get("title") or "").strip() or (p.get("prompt") or "").strip()[:22]
t = re.sub(r'[\\/:*?"<>|\r\n\t]', "-", t).strip(" .-")[:60] or "未命名"
print(t)
PYEOF
)"

# 风格没写就给一个中性的底，但要在进度里说清楚——别让人以为"我什么都没写它却按我的意思来"。
TAG_NOTE=""
if [ -z "$PROMPT" ]; then
  PROMPT="pop"
  TAG_NOTE="（风格框是空的，这一版按 pop 走）"
fi

OUT_AUDIO="$OUT_DIR/$TITLE.wav"

# ------------------------------ 开跑 ------------------------------------------

WATCHDOG=""
start_watchdog() {
  ( sleep "$WATCHDOG_SECONDS"
    kill -TERM "$1" 2>/dev/null
    sleep 10
    kill -KILL "$1" 2>/dev/null ) &
  WATCHDOG=$!
}
stop_watchdog() {
  if [ -n "$WATCHDOG" ]; then kill "$WATCHDOG" 2>/dev/null; WATCHDOG=""; fi
}
trap 'stop_watchdog' EXIT
start_watchdog $$

write_progress 2 "running" "正在准备…" "null" "先把歌词和风格交给 HeartMuLa${TAG_NOTE}"

# ⚠️ 界面（BackendClient）会顺手给子进程塞一个 PYTORCH_ENABLE_MPS_FALLBACK=1 ——
#    那是原来 ACE-Step 要的。这条 C++ 路不需要它，也免得将来有人被环境变量误导。
unset PYTORCH_ENABLE_MPS_FALLBACK PYTORCH_MPS_FAST_MATH

set_percent 5 "正在把模型装进显卡…" "第一次会慢几十秒，之后一两秒"

"$HM_CLI" --task gen --family heartmula --model "$HM_MODEL" --backend metal \
  --lyrics "$LYRICS" \
  --request-option "tags=$PROMPT" \
  --request-option "duration_sec=$SECONDS_WANTED" \
  --seed "$SEED" \
  --out "$OUT_AUDIO" --metrics --log > "$LOG" 2>&1 &
GEN_PID=$!

PCT=10
WAITED=0
while kill -0 "$GEN_PID" 2>/dev/null; do
  sleep 3
  WAITED=$((WAITED + 3))
  if [ "$WAITED" -ge "$WATCHDOG_SECONDS" ]; then
    kill -TERM "$GEN_PID" 2>/dev/null
    sleep 1
    kill -KILL "$GEN_PID" 2>/dev/null
    write_progress 99 "failed" "等得太久了，已经按停" "null" \
      "超过 ${WATCHDOG_SECONDS} 秒还没跑完。日志在 $LOG"
    exit 6
  fi
  if [ "$PCT" -lt 88 ]; then
    PCT=$((PCT + 2))
    set_percent "$PCT" "正在唱…" "它按歌词一句句唱下去，约是歌长的一倍半${TAG_NOTE}"
  fi
done
wait "$GEN_PID"
RC=$?

# 生成失败时，把日志里最后那句人话带出来。
if [ "$RC" -ne 0 ] || [ ! -s "$OUT_AUDIO" ]; then
  TAIL="$("$PY" - "$LOG" <<'PYEOF'
import sys
try:
    lines = [l.strip() for l in open(sys.argv[1], errors="replace") if l.strip()]
except Exception:
    lines = []
print((lines[-1] if lines else "")[:200])
PYEOF
)"
  write_progress 99 "failed" "这一趟没成" "null" "${TAIL:-它没有给出音频。日志在 $LOG}"
  [ "$RC" -eq 0 ] && RC=5
  exit 5
fi

# ------------------------------ 收产物 ----------------------------------------

WALL_MS="$("$PY" - "$LOG" <<'PYEOF'
import re, sys
try:
    txt = open(sys.argv[1], errors="replace").read()
except Exception:
    txt = ""
m = re.search(r"metrics\.wall_ms=([0-9.]+)", txt)
print(m.group(1).split(".")[0] if m else "")
PYEOF
)"
DUR_MS="$("$PY" - "$LOG" <<'PYEOF'
import re, sys
try:
    txt = open(sys.argv[1], errors="replace").read()
except Exception:
    txt = ""
m = re.search(r"metrics\.audio_duration_ms=([0-9.]+)", txt)
print(m.group(1).split(".")[0] if m else "")
PYEOF
)"

# ★ 进度卡里要说人话：用户眼睛不好，「60080 毫秒」这种数他得自己换算，
#   不如直接写「1 分 0 秒」。
LEN_NOTE="$("$PY" - "${DUR_MS:-}" <<'LENEOF'
import sys
raw = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
try:
    s = (int(raw) + 500) // 1000
except Exception:
    s = 0
if s <= 0:
    print("")
else:
    m, ss = divmod(s, 60)
    print("，%d 分 %d 秒长的音频" % (m, ss) if m else "，%d 秒长的音频" % ss)
LENEOF
)"
TIME_NOTE=""
[ -n "$WALL_MS" ] && TIME_NOTE="（用时 $((WALL_MS / 1000)) 秒${LEN_NOTE}）"

# 顺手转一份 mp3 放旁边（界面用 wav 就行；mp3 方便用户拖到别处听）。
if [ -x "$FFMPEG" ]; then
  "$FFMPEG" -y -hide_banner -loglevel error -i "$OUT_AUDIO" \
    -b:a 192k "$OUT_DIR/$TITLE.mp3" >/dev/null 2>&1 || true
fi

write_progress 100 "done" "出好了${TIME_NOTE}" \
  "\"$("$PY" -c 'import json,sys;print(json.dumps(sys.argv[1])[1:-1])' "$OUT_AUDIO")\"" \
  "只出歌：会唱词，但不出谱子。伴奏是草稿，拿出去拆开精修。${TAG_NOTE}"

echo "[heartmula] 音频：$OUT_AUDIO"
exit 0
