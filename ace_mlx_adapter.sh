#!/bin/bash
# ==============================================================================
# ace_mlx_adapter.sh — MIR 与「本机 mlx-serve 上的 ACE-Step 1.5 XL Turbo」之间唯一的桥
#
# 它与 yue2_adapter.sh / render_adapter.sh 同一套契约：
#   界面写 params.json → 本脚本写 progress.json → 界面读进度、收产物。
#
# ★ 2026-11-19 换的引擎：不再是官方 PyTorch 那套（一跑就把整机内存拖空、
#   被看门狗按停），而是 MLX-Serve.app 里的 ACE-Step 1.5 XL Turbo 8bit：
#   8 步出结果、48 kHz 立体声、峰值内存约 10.5 GB、90 秒的歌约 30 秒出。
#
# 它只做四件事：
#   1. 服务没起就起（低内存模式：VAE 分块解码，输出与默认模式逐字节相同）
#   2. 把参数交给 scripts/ace_mlx_generate.py（请求 + SSE 进度 + 写 wav）
#   3. 用完把模型从内存里卸掉（不常占 6.5 GB）
#   4. 全过程写 progress.json；本脚本自身不发起任何外部网络请求
#
# 用法：
#   ./ace_mlx_adapter.sh --params <参数.json> --out-dir <目录> --progress <progress.json>
#
# 参数 JSON（与另外几条共用）：
#   { "prompt": "风格描述", "lyrics": "歌词或 [Instrumental]", "duration": 90,
#     "bpm": 88, "keyscale": "C major", "timesignature": "4/4", "seed": 42,
#     "language": "zh", "mode": "generate|repaint|reference",
#     "ref_audio": "", "src_audio": "", "cover_strength": 0.5, "title": "这一首叫什么" }
# 退出码：0 成功 / 2 参数错 / 5 生成失败 / 6 超时 / 7 缺环境
# ==============================================================================

set -uo pipefail

BIN=/Applications/MLX-Serve.app/Contents/MacOS/mlx-serve
PORT=11234
HEALTH="http://127.0.0.1:${PORT}/health"
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
GEN="$PROJECT_ROOT/scripts/ace_mlx_generate.py"
PY=/usr/bin/python3
LOGDIR="$PROJECT_ROOT/logs"

PARAMS=""
OUT_DIR="$PROJECT_ROOT/output"
PROGRESS=""

die() { printf '%s\n' "[ace_mlx_adapter] $1" >&2; exit "${2:-2}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --params)    PARAMS="${2:-}"; shift 2 ;;
    --out-dir)   OUT_DIR="${2:-}"; shift 2 ;;
    --progress)  PROGRESS="${2:-}"; shift 2 ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    *)           die "不认识的参数：$1" ;;
  esac
done

[ -n "$PARAMS" ] || die "缺少 --params <参数.json>"
[ -f "$PARAMS" ] || die "参数文件不存在：$PARAMS"
[ -x "$BIN" ] || die "找不到 MLX-Serve.app（应在 /Applications 里）" 7
[ -f "$GEN" ] || die "找不到生成脚本：$GEN" 7
[ -x "$PY" ] || die "找不到 python3：$PY" 7

[ -n "$PROGRESS" ] || PROGRESS="$OUT_DIR/progress.json"
mkdir -p "$OUT_DIR" "$LOGDIR" "$(dirname "$PROGRESS")"

# 写一条"还没开始"的状态，界面立刻有字可看
"$PY" - "$PROGRESS" <<'PY'
import json, os, sys, time
path = sys.argv[1]
payload = {"percent": 0, "state": "running", "message": "正在启动…",
           "detail": "先把本机引擎拉起来，马上就有下文", "updated": int(time.time())}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False)
os.replace(tmp, path)
PY

# ---- 1. 服务在不在；不在就起（低内存模式：峰值约 10.5 GB，不碰整段 VAE）-----
STARTED_BY_US=0
if ! curl -s -m 2 "$HEALTH" >/dev/null 2>&1; then
  MLXSERVE_LOWMEM=1 nohup "$BIN" serve --host 127.0.0.1 --port "$PORT" \
      > "$LOGDIR/ace_mlx_server.log" 2>&1 &
  STARTED_BY_US=1
  for i in $(seq 1 60); do
    curl -s -m 1 "$HEALTH" >/dev/null 2>&1 && break
    sleep 0.5
  done
  if ! curl -s -m 2 "$HEALTH" >/dev/null 2>&1; then
    "$PY" - "$PROGRESS" <<'PY'
import json, os, sys, time
path = sys.argv[1]
payload = {"percent": 0, "state": "failed", "message": "引擎没起来",
           "detail": "日志在 my-songwriter/logs/ace_mlx_server.log", "updated": int(time.time())}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False)
os.replace(tmp, path)
PY
    die "mlx-serve 起不来（看 logs/ace_mlx_server.log）" 7
  fi
fi

# ---- 2. 出歌（python 负责请求、进度、落盘）-----
"$PY" "$GEN" --params "$PARAMS" --out-dir "$OUT_DIR" --progress "$PROGRESS" --port "$PORT"
STATUS=$?

# ---- 3. 卸模型：跑完就把那 6.5 GB 还回去（服务进程留着，只占几十 MB）-----
MODEL=$(curl -s -m 3 "http://127.0.0.1:${PORT}/v1/models" \
        | "$PY" -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(next((m['id'] for m in d['data'] if 'ACE-Step' in m['id']), ''))
except Exception:
    print('')")
if [ -n "${MODEL}" ]; then
  curl -s -m 10 -X POST "http://127.0.0.1:${PORT}/v1/unload-model" \
       -H 'Content-Type: application/json' -d "{\"model\":\"${MODEL}\"}" >/dev/null 2>&1
fi
if [ "$STARTED_BY_US" = "1" ]; then
  pkill -f 'mlx-serve serve' 2>/dev/null
fi

exit "$STATUS"
