#!/bin/bash
# ==============================================================================
# stable_audio_adapter.sh — 界面 与 Stable Audio 3 Medium 之间唯一的桥
#
# 它与 render_adapter.sh / yue2_adapter.sh **同一套契约**：
#   界面写 params.json → 本脚本写 progress.json → 界面读进度、显示产物。
#   退出码也一致。所以界面上只要换个脚本名，其余（进度轮询、停止、
#   试听、导出、在文件夹里看）全部照旧。
#
# 它跑的是本机那份 Stable Audio，**模型不另装一套** ——
# 用的是 Crafting Caster（原名「声音工坊」）已经装好、也一直在用的那一份：
#   /Users/jieda/AI-Studio
# 那边有个本机服务（只监听 127.0.0.1:7861）负责加载模型、翻译中文提示词、
# 写 wav。这个脚本只做四件事：
#   1. 把界面的参数翻成那边的请求（描述 + 时长 + 种子）
#   2. 服务没起着就先把它拉起来
#   3. 等结果，把 wav 拷到这次新建的文件夹里
#   4. 全程写 progress.json；本脚本自身不发起任何外部网络请求
#
# 用法：
#   ./stable_audio_adapter.sh --params <参数.json> --out-dir <目录> --progress <progress.json>
#
# 参数 JSON（与另外两条共用同一套字段，只用得上前几个）：
#   { "prompt": "风格描述", "duration": 30, "seed": 42, "title": "这一首叫什么" }
#   ⚠️ lyrics / bpm / steps 这些它**一律不看** —— 这台不唱词、不认谱。
#
# 退出码：0 成功 / 2 参数错 / 3 模型加载失败 / 5 生成失败 / 6 超时被杀 / 7 缺环境
# ==============================================================================

set -uo pipefail
set +m

# ------------------------------ 可配置区 --------------------------------------
SA3_BASE="${SA3_BASE:-/Users/jieda/AI-Studio}"
SA3_VENV="${SA3_VENV:-$SA3_BASE/stable-audio-3/optimized/mlx/.venv/bin/python}"
SA3_APP="$SA3_BASE/app"
SA3_PORT="${SA3_PORT:-7861}"
SA3_URL="http://127.0.0.1:${SA3_PORT}"

# 官方模型最长 380 秒（6 分 20 秒）；再短也至少 5 秒。
MIN_SECONDS=5
MAX_SECONDS=380

# 等结果的硬上限（秒）。实测满载 6 分 20 秒约 46 秒；
# 这里留到 15 分钟，纯粹是防卡死，不是性能估计。
WATCHDOG_SECONDS=900
# -----------------------------------------------------------------------------

PY=/usr/bin/python3
INSTALLED_ROOT="$(cd "$(dirname "$0")" && pwd)"

die() { echo "[stable_audio] $*" >&2; exit "${2:-5}"; }

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

OUT_DIR="${OUT_DIR:-$INSTALLED_ROOT/output}"
mkdir -p "$OUT_DIR" || die "建不了输出目录：$OUT_DIR"
# ★ 先解析成绝对路径 —— 后面 cd 到别处就没法回头了（YuE2 那条踩过这个坑）。
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
PROGRESS="${PROGRESS:-$OUT_DIR/progress.json}"

[ -x "$SA3_VENV" ] || die "Stable Audio 的模型文件夹不在了：${SA3_BASE}（先看 AI-Studio 还在不在）" 7
[ -f "$SA3_APP/server.py" ] || die "Stable Audio 的服务脚本不见了：$SA3_APP/server.py" 7

LOG="$OUT_DIR/.stable-audio.log"
RESP="$(mktemp -t stable_audio_resp.XXXXXX)"
DONE_FLAG=""
cleanup() {
  [ -n "$DONE_FLAG" ] && rm -f "$DONE_FLAG" 2>/dev/null
  rm -f "$RESP" 2>/dev/null
}
trap cleanup EXIT

# ------------------------------ 进度文件 --------------------------------------

# write_progress <percent> <state> <message> [<output 的 JSON 值>] [<detail>]
# 全部交给 python 拼，拼完立刻 json.loads 验一遍 —— 手工拼 JSON 错得特别安静
#（2026-10-12 在 YuE2 那条上真踩过一次，白丢了一首好好的曲子）。
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

write_progress 1 "running" "正在准备…" "null" "先核对一下这次的设置，马上交给 Stable Audio"

# ------------------------------ 读参数 ----------------------------------------

PROMPT="$("$PY" - "$PARAMS" <<'PYEOF'
import json, sys
try:
    print((json.load(open(sys.argv[1])).get("prompt") or "").strip())
except Exception:
    print("")
PYEOF
)"
[ -n "$PROMPT" ] || die "还没写描述：先在「风格」里说一句你想要的（比如「深夜小巷的雨声」）。" 2

SECONDS_WANTED="$("$PY" - "$PARAMS" <<'PYEOF'
import json, sys
try:
    v = float(json.load(open(sys.argv[1])).get("duration") or 30)
except Exception:
    v = 30.0
print(int(round(v)))
PYEOF
)"
[ "$SECONDS_WANTED" -lt "$MIN_SECONDS" ] 2>/dev/null && SECONDS_WANTED=$MIN_SECONDS
[ "$SECONDS_WANTED" -gt "$MAX_SECONDS" ] 2>/dev/null && SECONDS_WANTED=$MAX_SECONDS

SEED="$("$PY" - "$PARAMS" <<'PYEOF'
import json, random, sys
try:
    raw = json.load(open(sys.argv[1])).get("seed")
    s = int(raw) if raw is not None else -1
except Exception:
    s = -1
if s < 0:
    s = random.randint(0, 2**31 - 1)
print(abs(s) % (2**31))
PYEOF
)"

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

# ------------------------------ 把服务叫醒 ------------------------------------

healthy() {
  "$PY" - "$SA3_URL" <<'PYEOF' >/dev/null 2>&1
import sys, urllib.request
try:
    with urllib.request.urlopen(sys.argv[1] + "/api/health", timeout=2) as r:
        sys.exit(0 if r.status == 200 else 1)
except Exception:
    sys.exit(1)
PYEOF
}

if ! healthy; then
  set_percent 5 "正在把 Stable Audio 叫起来…" "第一次用会慢几秒，之后就快了"
  # 和 Crafting Caster 的启动器同一个起法：独立会话、日志写进它自己的目录。
  ( cd "$SA3_APP" && nohup "$SA3_VENV" server.py >> "$LOG" 2>&1 & ) >/dev/null 2>&1
  WAITED=0
  until healthy; do
    sleep 1
    WAITED=$((WAITED + 1))
    if [ "$WAITED" -ge 120 ]; then
      write_progress 99 "failed" "Stable Audio 没能起来" "null" "服务没有应答。日志在 $LOG"
      exit 3
    fi
    [ $((WAITED % 5)) -eq 0 ] && set_percent 8 "正在把 Stable Audio 叫起来…" "已经等了 ${WAITED} 秒"
  done
fi

# ------------------------------ 发请求 ----------------------------------------

BODY="$("$PY" - "$PROMPT" "$SECONDS_WANTED" "$SEED" <<'PYEOF'
import json, sys
print(json.dumps({"prompt": sys.argv[1], "mode": "music",
                  "seconds": int(sys.argv[2]), "seed": int(sys.argv[3])},
                 ensure_ascii=False))
PYEOF
)"

set_percent 15 "正在写音乐…" "中文描述会先翻成英文，头一次慢一些；写起来很快"

"$PY" - "$SA3_URL" "$BODY" > "$RESP" 2>>"$LOG" <<'PYEOF' &
import json, sys, urllib.request
url, body = sys.argv[1], sys.argv[2]
req = urllib.request.Request(url.rstrip("/") + "/api/generate",
                             data=body.encode("utf-8"),
                             headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=900) as r:
        sys.stdout.write(r.read().decode("utf-8", "replace"))
except Exception as e:
    sys.stderr.write(f"[stable_audio] 请求失败：{e}\n")
    sys.exit(1)
PYEOF
REQ_PID=$!

# 等的时候让进度条慢慢往前爬 —— 百分比涨得不多，但「已经等了 X 秒」一直在涨，
# 那就是"还活着"的证据。
PCT=15
WAITED=0
while kill -0 "$REQ_PID" 2>/dev/null; do
  sleep 2
  WAITED=$((WAITED + 2))
  if [ "$WAITED" -ge "$WATCHDOG_SECONDS" ]; then
    kill -TERM "$REQ_PID" 2>/dev/null
    sleep 1
    kill -KILL "$REQ_PID" 2>/dev/null
    write_progress 99 "failed" "等得太久了，已经按停" "null" "超过 ${WATCHDOG_SECONDS} 秒还没跑完，怕它一直占着机器"
    exit 6
  fi
  if [ "$PCT" -lt 85 ]; then
    PCT=$((PCT + 3))
    set_percent "$PCT" "正在写音乐…" "中文描述会先翻成英文，头一次慢一些；写起来很快"
  fi
done
wait "$REQ_PID"
REQ_STATUS=$?

if [ "$REQ_STATUS" -ne 0 ] || [ ! -s "$RESP" ]; then
  write_progress 99 "failed" "这一趟没成" "null" "Stable Audio 没有应答。日志在 $LOG"
  exit 5
fi

# 解析：{"ok":true,"file":"music_30s_….wav","elapsed":…}
read -r OK FILE ELAPSED ERRMSG <<<"$("$PY" - "$RESP" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("0", "", "", "返回的内容看不懂（不是 JSON）")
    raise SystemExit
if d.get("ok"):
    print("1", d.get("file", "") or "", str(d.get("elapsed", "")), "")
else:
    msg = (d.get("error") or "").replace("\n", " ")[:160]
    print("0", "", "", msg or "不知道为什么没成")
PYEOF
)"

if [ "$OK" != "1" ] || [ -z "$FILE" ]; then
  write_progress 99 "failed" "这一趟没成" "null" "${ERRMSG:-Stable Audio 没有给出音频}"
  exit 5
fi

# ------------------------------ 收产物 ----------------------------------------

SRC="$SA3_BASE/output/studio/$(basename "$FILE")"
[ -f "$SRC" ] || { write_progress 99 "failed" "音频不知道去哪了" "null" "服务说写好了，可 $SRC 不在"; exit 5; }

OUT_AUDIO="$OUT_DIR/$TITLE.wav"
cp -f "$SRC" "$OUT_AUDIO" || { write_progress 99 "failed" "音频拷不过来" "null" "目标是 $OUT_AUDIO"; exit 5; }

LEN_NOTE="$SECONDS_WANTED 秒"
if [ -n "${ELAPSED:-}" ]; then
  LEN_NOTE="${LEN_NOTE}（用时 ${ELAPSED} 秒）"
fi

write_progress 100 "done" "出好了：${LEN_NOTE}" \
  "\"$("$PY" -c 'import json,sys;print(json.dumps(sys.argv[1])[1:-1])' "$OUT_AUDIO")\"" \
  "只出音乐，不唱词，也没有谱子。音频就在这次新建的文件夹里。"

echo "[stable_audio] 音频：$OUT_AUDIO"
exit 0
