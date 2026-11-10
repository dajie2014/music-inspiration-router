#!/bin/bash
# ==============================================================================
# yue2_adapter.sh — 界面 与 YuE2（本机苹果 MLX 版）之间唯一的桥
#
# 它与 render_adapter.sh **同一套契约**：
#   界面写 params.json → 本脚本写 progress.json → 界面读进度、显示产物。
#   退出码也一致。所以界面上只要换个脚本名，其余（进度轮询、停止、
#   试听、导出、在文件夹里看）全部照旧。
#
# 它做四件事：
#   1. 把界面的参数翻译成 YuE2 的请求 JSON
#   2. 跑生成，把 YuE2 打出来的每一行翻译成 0-100 的进度
#   3. 完成后把三样东西一起摆进输出目录：音频（flac）、ABC 谱、MusicXML（给 Dorico）
#   4. 只往本地磁盘写；本脚本自身不发起任何网络请求
#
# 用法：
#   ./yue2_adapter.sh --params <参数.json> --out-dir <目录> --progress <progress.json>
#
# 参数 JSON（与 ACE-Step 那条共用同一套字段，只用得上前几个）：
#   { "prompt": "风格描述", "lyrics": "歌词", "title": "这一首叫什么",
#     "steps": 8, "seed": -1, "abc_path": "…", "plan_only": false }
#   steps = 声学合成的步数：8 = 快（一首约 4 分半），32 = 标准（约 10 分钟）
#   abc_path  = 照外面这份谱子唱（给了它，YuE2 就不自己现想谱子）
#   plan_only = **只要谱子，不唱**（约 40 秒）。产物只有 .abc 和 .xml；
#               progress.json 里 output 为 null、score 指向那份 .abc。
#               ★ 这一档**故意不认 abc_path** —— 它要的就是"重新写一份谱"，
#                 拿旧谱再"写"一遍等于什么都没干。
#
# 退出码：0 成功 / 2 参数错 / 3 模型加载失败 / 5 生成失败 / 6 超时被杀 / 7 缺环境
# ==============================================================================

set -uo pipefail
set +m            # 关掉 job control 的通知，免得收尾时往日志里打一串「Terminated」

# ------------------------------ 可配置区 --------------------------------------
# 运行时间护栏（秒）。实测：快模式一首 3 分半的歌约 4 分 22、标准模式约 10 分钟。
# 留到 1 小时足够宽松，纯粹是防卡死，不是性能估计。
WATCHDOG_SECONDS=3600
# -----------------------------------------------------------------------------

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"

# YuE2 装在哪：默认是兄弟目录 ../yue2-local，可用环境变量 YUE2_ROOT 覆盖。
if [ -n "${YUE2_ROOT:-}" ]; then
  YUE2_DIR="$YUE2_ROOT"
else
  YUE2_DIR="$(cd "$PROJECT_ROOT/../yue2-local" 2>/dev/null && pwd || echo "")"
fi
YUE2_BIN="$YUE2_DIR/yue2"
ABCXML="$YUE2_DIR/abcxml"
PY=/usr/bin/python3
# YuE2 自带的记谱工具（只依赖标准库）。
# ★ 2026-10-13 用它来**剥掉和弦标注** —— 走「精确旋律线」那一档时，
#   谱子里不许有和弦（`run_yue2.py` 第 45 行会直接报错），而 Dorico 导出的分谱
#   几乎都带着和弦（用户那份就有 101 个）。
ABC_TOOLS="$YUE2_DIR/mlx-Yue/src/lyra/music_tools/abc_tools.py"
# ★ 收拾谱子的总入口（统一格式 → 升八度 → 翻成它认的写法 → 剥和弦 → 它自己验收）。
PREPARE_SCORE="$YUE2_DIR/tools/prepare_score.py"
# 把歌词写进谱子那件事（用户 2026-10-12 定的：「出谱的时候就带上歌词」）。
# 它在产物落盘前给 ABC 插 `w:` 行 ⇒ 随后转出来的 MusicXML 自然也有 `<lyric>`。
ATTACH_LYRICS="$PROJECT_ROOT/scripts/attach_lyrics.py"
# 按「呼吸」给歌词分行（长休止 = 句界）。
# 2026-10-24：多小节休止之后模型会开始念白/说唱，根因是歌词整段没分行 ——
# 它不知道"这里歇了很久，下一句要重新起"。分行就是给它这个信号。
LYRICS_LINES="$PROJECT_ROOT/scripts/lyrics_lines.py"
# 出谱之后自动扫一遍人声谱：默认高音谱号，加线太多就换成低音谱号
#（用户 2026-10-24 定的）。**引擎侧自己判、自己改，不需要人看谱。**
FIX_CLEF="$PROJECT_ROOT/scripts/fix_score_clef.py"

PARAMS=""
OUT_DIR=""
PROGRESS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --params)   PARAMS="${2:-}"; shift 2 ;;
    --out-dir)  OUT_DIR="${2:-}"; shift 2 ;;
    --progress) PROGRESS="${2:-}"; shift 2 ;;
    -h|--help)  sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "[yue2_adapter] 不认识的参数：$1" >&2; exit 2 ;;
  esac
done

die() { echo "[yue2_adapter] $*" >&2; exit "${2:-2}"; }

[ -n "$PARAMS" ] || die "缺少 --params"
[ -x "$YUE2_BIN" ] || die "找不到 YuE2 的启动脚本：${YUE2_BIN}（那边环境还没装好？）" 7
[ -f "$ABCXML" ] || die "找不到 abcxml（ABC ↔ MusicXML 转换）：${ABCXML}" 7

OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/output}"
PROGRESS="${PROGRESS:-$PROJECT_ROOT/output/progress.json}"
mkdir -p "$OUT_DIR" || die "建不了输出目录：${OUT_DIR}"
mkdir -p "$(dirname "$PROGRESS")"

# ─────────── 路径一律先解析成**绝对**，再往下走 ───────────
#
# 为什么非做不可：本脚本中途会 `cd` 进 YuE2 的目录（它的包装脚本自己还会再 cd 一次），
# 带着相对路径过去，同一句话在两边的意思就不一样了。
#
# ★ 2026-10-12 实际踩到，而且**只有命令行调用才露出来**（从界面跑时 BackendClient
#   给的是绝对路径，所以一直没发现）：
#     传 `--out-dir output/xxx`，脚本自己算出的日志路径是相对的，
#     `cd` 之后 tee 去写一个**根本不存在的目录** → tee 一失败，
#     YuE2 立刻吃 SIGPIPE 死掉。症状是「进度停在 1%、日志空白、
#     产物飘到 yue2-local/mlx-Yue/output/ 下面」——查了二十多分钟才认出来。
#     README 的坑表里早就写着这一条（render_adapter.sh 当初就是这么修的），这边漏了。
PARAMS="$(cd "$(dirname "$PARAMS")" && pwd)/$(basename "$PARAMS")"
[ -f "$PARAMS" ] || die "参数文件不存在：${PARAMS}"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
PROGRESS="$(cd "$(dirname "$PROGRESS")" && pwd)/$(basename "$PROGRESS")"

RUN_DIR="$OUT_DIR/.yue2"     # 隐藏子目录：跑生成的杂项留在这儿，界面扫历史时会跳过隐藏项
mkdir -p "$RUN_DIR"
LOG="$RUN_DIR/last-run.log"
LYR_AUDIT=""          # 歌词自查结论（守门用，见下面两处贴词之后）
# 风格提示词：谱号探针先看这里写没写男女声（用户 2026-10-24 定）——
# 写了就照它定谱号；没写，才去扫人声谱的加线。取不到就当空（走扫谱）。
PROMPT_TEXT="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("prompt",""))' "$PARAMS" 2>/dev/null || true)"

# ------------------------------ 进度文件 --------------------------------------

json_escape() { "$PY" -c 'import json,sys;print(json.dumps(sys.argv[1])[1:-1])' "$1"; }

LAST_PERCENT=0

# write_progress <percent> <state> <message> [<output 的 JSON 值>] [<score 的 JSON 值>] [<detail>]
#
# `detail` 是 2026-10-13 加的（界面上大字下面那行小字：还要等多久、为什么慢）。
# 它排在最后而不是插在中间 —— 中间那两个位置已经被 output / score 占了，
# 插进去会让现有调用**静静地把音频路径当成一句话**，那种错不报错、只出错。
# 只想给 detail 不想给前两个时，写 "null" "null" 占位。
#
# `score` 是 2026-10-12 加的：**「只出谱子」那一档没有音频**，产物就是一份谱子。
# 用一个单独的字段报给界面，而不是拿 output 冒充音频路径 —— 后者会让界面
# 把一条没有声音的条目当成"能播的歌"（点了播放键没反应，或者干脆判成失败）。
#
# 原子写入：先写 .tmp 再改名 —— 读的一方永远读不到半截。
#
# ⚠️ 2026-10-12 改成**让 python 拼这份 JSON**（原来是 printf 手工拼的）。
#    那天收尾那两行少写了一个收尾引号，shell 就把后面两行源码当成了消息的一部分，
#    写出去的 progress.json **不是合法 JSON** —— 界面读不出来，于是一首好好的曲子
#    被判成"失败"。手工拼 JSON 就是这么错的：**错得特别安静**（`bash -n` 也查不出来，
#    跨行的字符串在语法上是合法的）。
#    现在交给 python，而且**拼完立刻 json.loads 验一遍**：拼错就当场失败、不留坏文件。
write_progress() {
  local pct="$1" state="$2" msg="$3" out="${4:-null}" score="${5:-null}" detail="${6:-}"
  local tmp="${PROGRESS}.tmp"
  "$PY" - "$pct" "$state" "$msg" "$out" "$score" "$detail" > "$tmp" <<'JSONEOF'
import json, sys, time
if len(sys.argv) != 7:
    sys.exit("write_progress 参数个数不对（%d 个）—— 多半是变量值里有空格却没加引号，"
             "被 shell 分词切碎了" % (len(sys.argv) - 1))
pct, state, msg, out, score, detail = sys.argv[1:7]
doc = ('{"percent":%d,"state":%s,"message":%s,"detail":%s,"updated":%d,"output":%s,"score":%s}'
       % (int(pct), json.dumps(state), json.dumps(msg), json.dumps(detail),
          int(time.time()), out, score))
json.loads(doc)          # 自检：拼错了当场炸，绝不把坏文件交给读的一方
print(doc)
JSONEOF
  [ -s "$tmp" ] && mv -f "$tmp" "$PROGRESS"
}

# 进度只许往前走 —— 那条进度条往回缩，会让人以为出错了。
# 第三个参数是给界面那行小字的补充说明（可省）：这一步大概多久。
set_percent() {
  local pct="$1" msg="$2" detail="${3:-}"
  [ "$pct" -lt "$LAST_PERCENT" ] && pct="$LAST_PERCENT"
  LAST_PERCENT="$pct"
  write_progress "$pct" "running" "$msg" "null" "null" "$detail"
}

# ------------------------------ 参数翻译 -------------------------------------

TITLE_RAW="$("$PY" - "$PARAMS" <<'PYEOF'
import json,sys
try:
    print(json.load(open(sys.argv[1])).get("title","") or "")
except Exception:
    print("")
PYEOF
)"

REQUEST="$RUN_DIR/request.json"
rm -f "$REQUEST"

"$PY" - "$PARAMS" "$REQUEST" "$ABCXML" "$PREPARE_SCORE" "$LYRICS_LINES" <<'PYEOF'
import json, pathlib, random, re, shutil, subprocess, sys

params = json.load(open(sys.argv[1]))
abcxml = sys.argv[3]
lyrics_lines_tool = sys.argv[5] if len(sys.argv) > 5 else ""
# ★ 2026-10-13：收拾谱子的总入口（见 tools/prepare_score.py）。
prepare_score = sys.argv[4]
style  = (params.get("prompt") or "").strip()
lyrics = (params.get("lyrics") or "").strip()
title  = (params.get("title") or "").strip()
steps  = params.get("steps", 8)
seed   = params.get("seed", -1)
# 「只要谱子，不唱」（界面上那个「先出谱子」）。它不改请求本身，
# 只改跑哪条子命令、以及收尾时摆哪些产物 —— 所以这个旗子一路带着走。
plan_only = bool(params.get("plan_only"))

# ★ 2026-10-18 用户要求放开纯器乐（**先不跑**，只把门打开）：
#   · 空歌词 / `[Instrumental]` 不再拒绝 —— 走 YuE2 的器乐路线；
#   · `[Instrumental]` 归一成空字符串（官方写法是「空歌词 + instrumental 风格」）；
#   · 官方文档明说这条路**没有保证零人声的硬开关**：出来若仍有人声，
#     是模型行为，不是参数没给对（`mlx-Yue/.../optimization.md` 也这么写）。
if lyrics == "[Instrumental]":
    lyrics = ""
if not style:
    sys.stderr.write("风格描述是空的。\n")
    sys.exit(2)

try:
    steps = int(steps)
except Exception:
    steps = 8
if steps not in (8, 16, 32):
    steps = 8                      # 界面只给 8 和 32，别的一律当快的走

request = {
    "style": style,
    "lyrics": lyrics,
    "cot": "full",                 # full = 让它自己写谱子
    "generation_config": {"ode_steps": steps},
}

# ── 外面拿进来的谱子（可选）：`abc_path` ──
#
# 有它 =「照这份谱子来」：YuE2 就不再自己现想谱子，照你给的这份出歌。
# 于是「YuE2 出谱 → 进 Dorico 改 → 送回 YuE2 重唱」这条来回才闭合
#（2026-10-12 用户提的：导进来接着打磨）。
#
# ⚠️ YuE2 认的是 **ABC**；给的是 MusicXML（Dorico 导出的那种）就先转一道 ——
#    用的是同一个 abcxml，跟界面里「只转格式」走的是同一条路。
#
# ⚠️ **「只出谱子」这一档故意把它当成没有**（2026-10-12）：那一档要的就是
#    "重新写一份谱"，拿旧谱再"写"一遍等于什么都没干。所以这里直接清掉。
abc_path = "" if plan_only else (params.get("abc_path") or "").strip()
if abc_path:
    src = pathlib.Path(abc_path)
    src_original = src          # 原始给的那份（收拾它用；src 下面会被换掉）
    if not src.is_absolute():
        # 界面给的是绝对路径；万一给了相对的，按 params.json 所在目录解
        src = pathlib.Path(sys.argv[1]).resolve().parent / src
    if not src.exists():
        sys.stderr.write(f"找不到谱子文件：{src}\n")
        sys.exit(2)
    if src.suffix.lower() in (".xml", ".musicxml"):
        # ★ 先抄到本轮运行目录里再转（2026-10-12 修）。
        #   `abcxml to-abc` 的输出**只能落在被转那份的旁边、同名换后缀** ——
        #   原地转，就会把那份 xml 旁边同名 `.abc` **悄悄盖掉**，
        #   而它常常是**原生方言**的谱子（能直接喂回 YuE2 的那种）。
        #   实测确认过它真会发生：用户那首 `20261012-141742 午后的光落在琴键上/`
        #   里的 `.abc` 就被这样换成了通用格式（内容没丢、写法变了）。
        #   这次转换本来就只是喂给模型的**中间步骤**，不该在用户的目录里留副产物。
        staging = pathlib.Path(sys.argv[1]).resolve().parent / "import-staging.xml"
        shutil.copyfile(src, staging)
        converted = staging.with_suffix(".abc")
        proc = subprocess.run([abcxml, "to-abc", str(staging)],
                              capture_output=True, text=True)
        if proc.returncode != 0 or not converted.exists():
            detail = (proc.stderr or proc.stdout or "").strip()
            sys.stderr.write("这份 XML 转不成 ABC：" + (detail[:300] or "没给出原因") + "\n")
            sys.exit(2)
        src = converted
    # ★★ 2026-10-13：**改走「精确旋律线」那一档**（`cot: melody`），
    #    而不是默认的 `full`（＝让它自己写谱）。
    #
    #    为什么（用户 2026-10-13 听完指出来的）：「风格特征很明显，
    #    **旋律是胡的，跟他自己出的乐谱完全不一样**」。
    #    查 YuE2 自己的说明书（`mlx-Yue/README.md`）—— 它是两种模式：
    #      · **Full + Supplied ABC**  = 谱子只是**条件**，旋律自己走（我们原先走的）
    #      · **Melody + Supplied ABC** = 把声学合成**钉在精确旋律线上**（要的是这个）
    #    ⇒ `cot` 改成 `melody`。
    #
    #    ⚠️ melody 档**不接受带和弦的谱子**（`run_yue2.py` 第 45 行直接报错），
    #       而 Dorico 导出的分谱几乎都带和弦（用户那份 101 个）
    #       ⇒ 先用 YuE2 自带的 `abc_tools.py strip-chords` 剥掉。
    #    ⚠️ 剥不掉（工具出错）时**退回老路**（乐谱当参考）—— 宁可唱得不像，
    #       也别让整趟生成跑不掉。
    # ★★ 2026-10-13：**先把谱子收拾成它认的那种写法**，再走「精确旋律线」那一档。
    #
    #    为什么（用户当天听完两版指出来的）：「风格特征很明显，
    #    **旋律是胡的，跟他自己出的乐谱完全不一样**」。
    #    根子：YuE2 认的是一种很死的**原生写法**（X:1 + 空 T: + 两条固定声部行 + 严格时值），
    #    而 Dorico 转出来的是**通用 ABC** ⇒ 它整份不认，只能当参考，旋律就自己走。
    #    更要命的是 `cot=full`（默认）**不检查格式** ⇒ 一路静默忽略，谁都看不出来。
    #
    #    收拾这件事全在 `tools/prepare_score.py` 里（四步 + 它自己的检查器验收）：
    #    统一成 MusicXML → 人声升回高八度 → 翻成原生写法 → 剥和弦。
    #    **两种输入格式都走这一条**（用户 2026-10-13 的要求：「xml / abc 都一样」）。
    #
    #    ⚠️ 收拾不成时**退回老路**（乐谱只当参考）—— 宁可这一趟唱得不像，
    #       也别让整首生成跑不掉。
    try:
        run_dir = pathlib.Path(sys.argv[1]).resolve().parent
        native_out = run_dir / "import-staging.melody.abc"
        # ★ 2026-10-20：界面上的「速度」框能盖掉谱子里的速度。
        #   由头：示例谱谱子开头是 72、定稿是 158，MusicXML 只带一个速度，
        #   转换器取了第一个 —— 整首唱慢。0 / 空 = 照谱，不问。
        prep_cmd = [sys.executable, prepare_score, str(src_original),
                    str(native_out), str(run_dir)]
        bpm = str(params.get("bpm") or "").strip()
        if bpm and bpm not in ("0", "0.0", "None"):
            prep_cmd += ["--tempo", bpm]
        prep = subprocess.run(prep_cmd,
                              capture_output=True, text=True,
                              encoding="utf-8", errors="replace")
        if prep.returncode == 0 and native_out.exists():
            request["abc"] = native_out.read_text(encoding="utf-8")
            request["cot"] = "melody"
            # ★ 2026-10-24：歌词按「呼吸」分行（长休止 = 句界）。
            #
            #   用户实测：多小节休止之后，模型会开始念白/说唱。
            #   根因是整段歌词没句界 —— 它不知道"这里歇了很久，下一句重新起"。
            #
            #   ★★ 用户 2026-10-24 定：**手动分行优先**。
            #   他自己导入谱子、在歌词框里排好行，那个版本一定比机器猜的准。
            #   所以这里**只在歌词还是一整行时**才自动分；他已经分了行就一个字不动。
            if (lyrics_lines_tool and "\n" not in lyrics
                    and src_original.suffix.lower() in (".xml", ".musicxml", ".mxl")):
                try:
                    out = subprocess.run(
                        [sys.executable, lyrics_lines_tool, str(src_original), "--max", "14", "--blank"],
                        capture_output=True, text=True, encoding="utf-8", errors="replace")
                    rows = [l.strip() for l in (out.stdout or "").splitlines() if l.strip()]
                    rows = [l for l in rows if not l.startswith(("声部：", "自动切成"))]
                    candidate = "\n".join(rows)
                    plain = re.sub(r"\s", "", lyrics)
                    cand_plain = re.sub(r"\s", "", candidate)
                    if candidate and plain and abs(len(cand_plain) - len(plain)) <= max(6, len(plain) // 8):
                        request["lyrics"] = candidate
                        sys.stderr.write("歌词按呼吸分成 %d 行（长休止处断开）\n" % len(rows))
                except Exception:
                    pass
        else:
            detail = (prep.stderr or prep.stdout or "").strip()
            sys.stderr.write("谱子没收拾成，这一趟按老路走（谱子只当参考，不照它唱）："
                             + (detail[:300] or "没给出原因") + "\n")
            request["abc"] = src.read_text(encoding="utf-8")
    except Exception as exc:
        sys.stderr.write(f"读不了谱子文件：{exc}\n")
        sys.exit(2)
# YuE2 对 id 有硬要求：只认 ASCII 字母数字和 _.-（中文标题会被它当场拒掉，
# 2026-10-12 实测踩到）。id 只是它内部的标识，产物名字由本脚本自己起，
# 所以这里把标题里能用的字符挑出来，挑不出就用一个固定的。
safe_id = re.sub(r"[^A-Za-z0-9_.-]", "-", title).strip("-.")
if not safe_id or not re.match(r"[A-Za-z0-9]", safe_id):
    safe_id = "yue2-song"
request["id"] = safe_id[:180]

# 界面上的种子 -1 = 随便来一首；YuE2 要一个非负整数，所以这里现摇一个。
if not (isinstance(seed, int) and 0 <= seed < 2**63):
    seed = random.randrange(2**63)
request["seed"] = seed

json.dump(request, open(sys.argv[2], "w"), ensure_ascii=False, indent=2)
PYEOF
RC=$?
[ "$RC" -eq 0 ] || { write_progress 0 "failed" "还差歌词或者风格" "null" "null" \
  "YuE2 是写歌的，得有词才唱；风格也得说一句它才能动笔"; exit 2; }

STEPS="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["generation_config"]["ode_steps"])' "$REQUEST")"
if [ "$STEPS" -le 8 ]; then MODE_NOTE="快"; else MODE_NOTE="标准"; fi

# 这一趟是「只出谱子」还是「出整首歌」？
#   plan  = 只跑写谱那一步（约 40 秒），产物只有谱子
#   run   = 写谱 + 唱 + 解码，产物是音频加谱子
PLAN_ONLY="$(/usr/bin/python3 -c 'import json,sys;print("1" if json.load(open(sys.argv[1])).get("plan_only") else "0")' "$PARAMS")"
if [ "$PLAN_ONLY" = "1" ]; then
  ACTION="plan"; WORK_DIR="$RUN_DIR/plan"
  write_progress 1 "running" "正在准备…" "null" "null" "这一趟只出谱子，不唱"
else
  ACTION="generate"; WORK_DIR="$RUN_DIR/run"
  write_progress 1 "running" "正在准备…" "null" "null" \
    "${MODE_NOTE}档；歌多长由你的词多长决定"
fi

# ── 对一下「词」和「谱子」的字数（用户 2026-10-20 交办：**只提示，不阻断**）──
#
# 为什么在开跑**之前**就查：这一趟要跑几分钟，等唱完才发现错位就白等了。
# 为什么会错位：它是**一字一个音位**往前排的 ——
#   词比音位少 ⇒ 从缺字那里起，后面全体错位；
#   词比音位多 ⇒ 多出来的字没地方落。
# 结论写进日志，并且（只在**对不上**时）挂到界面上那行小字和最后的详情里。
# ⚠️ 一律 `|| true`：查不出来、谱子是 ABC 而不是 MusicXML，都不许影响这一趟。
LYR_COUNT_AUDIT=""
LYR_COUNT_NOTE=""
if [ "$PLAN_ONLY" != "1" ]; then
  ABC_PATH_AUDIT="$("$PY" - "$PARAMS" <<'PYEOF'
import json, os, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    doc = {}
p = (doc.get("abc_path") or "").strip()
if p and not os.path.isabs(p):
    # 与上面参数翻译同一条规矩：相对路径按 params.json 所在目录解
    p = os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), p)
print(p)
PYEOF
)"
  case "$ABC_PATH_AUDIT" in
    *.xml|*.XML|*.musicxml|*.MusicXML)
      if [ -f "$ABC_PATH_AUDIT" ]; then
        LYR_COUNT_AUDIT="$("$PY" "$PROJECT_ROOT/scripts/lyrics_lines.py" \
          "$ABC_PATH_AUDIT" --check-params "$PARAMS" 2>>"$LOG" | tee -a "$LOG" | tail -1 || true)"
        echo "[yue2_adapter] 词谱字数：${LYR_COUNT_AUDIT:-校验没跑起来}" >> "$LOG"
        case "$LYR_COUNT_AUDIT" in
          *会错位*|*唱不进去*)
            LYR_COUNT_NOTE="　·　${LYR_COUNT_AUDIT}"
            set_percent "$LAST_PERCENT" "正在准备…" \
              "词和谱子字数对不上，唱起来可能错位（详情见最后一行的说明）"
            ;;
        esac
      fi
      ;;
  esac
fi

# ------------------------------ 运行 -----------------------------------------

# 清掉上一轮的残留，免得读进度的人看到旧数据。
# ⚠️ 除了 run/ 目录，YuE2 还会在它旁边写 run.resources.jsonl 和 run.resources.json
#    两份资源记录，而这两份是「已经存在就不干活」（2026-10-12 实测：
#    第二次跑直接 FileExistsError）。所以一并删掉。
rm -rf "$RUN_DIR/run" "$RUN_DIR/plan" \
       "$RUN_DIR"/run.resources.jsonl "$RUN_DIR"/run.resources.json \
       "$RUN_DIR"/plan.resources.jsonl "$RUN_DIR"/plan.resources.json

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

parse_line() {
  local line="$1" sec tok inner chunk pct
  case "$line" in
    *"Verifying model files"*)
      set_percent 2 "先检查一下引擎文件还在不在" "几秒钟的事"
      ;;
    *"Planning score"*)
      # Running Planning score: 1185 tokens | 59.2 tokens/s | elapsed 20.0s
      sec="${line##*elapsed }"; sec="${sec%s}"
      case "$sec" in ''|*[!0-9.]*) sec=0 ;; esac
      pct="$(awk -v s="$sec" 'BEGIN{p=3+int(s/40*12); if(p>15)p=15; print p}')"
      set_percent "$pct" "正在写谱子…" "通常半分钟左右${LYR_COUNT_NOTE}"
      ;;
    *"Generating song"*)
      # Running Generating song: 503 tokens | 50.3 tokens/s | elapsed 10.0s
      tok="${line#*song: }"; tok="${tok%% *}"
      case "$tok" in ''|*[!0-9]*) tok=0 ;; esac
      pct="$(awk -v t="$tok" 'BEGIN{p=16+int(t/6000*29); if(p>45)p=45; print p}')"
      set_percent "$pct" "正在照着谱子唱…" "这一步最花时间，通常一分钟上下${LYR_COUNT_NOTE}"
      ;;
    *"Synthesizing audio"*"steps ("*)
      # Running Synthesizing audio: 6/32 steps (19%) | elapsed 5.0s
      inner="${line##*steps (}"; inner="${inner%%)*}"
      case "$inner" in ''|*[!0-9]*) inner=0 ;; esac
      pct="$(awk -v s="$inner" 'BEGIN{p=46+int(s*0.46); if(p>92)p=92; print p}')"
      set_percent "$pct" "把唱好的变成能听的声音…" "通常一两分钟"
      ;;
    *"Decoding audio"*"chunks"*)
      # Completed Decoding audio: 2/2 chunks (100%) | elapsed 0.8s
      chunk="${line##*Decoding audio: }"; chunk="${chunk%%/*}"
      case "$chunk" in ''|*[!0-9]*) chunk=0 ;; esac
      pct=$((93 + chunk * 3))
      [ "$pct" -gt 99 ] && pct=99
      set_percent "$pct" "快好了，正在收尾…" "最后一道工序，几秒钟"
      ;;
  esac
}

cd "$YUE2_DIR" || die "进不去 YuE2 目录：${YUE2_DIR}" 7

# ⚠️ 界面（BackendClient）会顺手给子进程塞一个 PYTORCH_ENABLE_MPS_FALLBACK=1 ——
#    那是 ACE-Step 要的，可 YuE2 一见到它就**拒绝启动**（它明说那不是一条
#    被验证过的执行路径）。两条路要的环境不一样，所以在这条路的门口摘掉。
#    2026-10-12 界面自检时实测踩到：日志里一句
#    「Unset PYTORCH_ENABLE_MPS_FALLBACK; fallback/fast-math is not a validated
#     execution path」，进程随即退出码 1。
unset PYTORCH_ENABLE_MPS_FALLBACK PYTORCH_MPS_FAST_MATH

# ── LoRA（2026-10-24 加）──
#
# mlx-Yue 从 2026-10-13 那版起支持挂社区的 safetensors LoRA：
#   --lora <文件> --lora-scale <倍数>
# 它改的是**唱法／音色**（上游 README 写的是 Custom Style/Artist LoRA），
# 不是"把字唱准"—— 这一点写在这儿，免得将来有人以为挂了 LoRA 就能治咬字。
#
# 没给 `lora_path` 就一个字都不传（空数组）。⚠️ macOS 自带的是 bash 3.2，
# `"${arr[@]}"` 在空数组 + `set -u` 下会报 unbound，所以用
# `${arr[@]+"${arr[@]}"}` 这种写法。
LORA_ARGS=()
LORA_PATH="$(/usr/bin/python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("lora_path") or "")' "$PARAMS" 2>/dev/null || true)"
if [ -n "$LORA_PATH" ]; then
  # 相对路径按 params.json 所在目录解（跟本脚本别的路径一个规矩）
  case "$LORA_PATH" in
    /*) ;;
    *)  LORA_PATH="$(cd "$(dirname "$PARAMS")" && pwd)/$LORA_PATH" ;;
  esac
  if [ ! -f "$LORA_PATH" ]; then
    MSG="找不到这个 LoRA 文件：${LORA_PATH}"
    write_progress "$LAST_PERCENT" "failed" "$MSG"
    echo "[yue2_adapter] $MSG" >&2
    exit 2
  fi
  LORA_SCALE="$(/usr/bin/python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));v=d.get("lora_scale");print(v if v is not None else 1.0)' "$PARAMS" 2>/dev/null || echo 1.0)"
  LORA_ARGS=(--lora "$LORA_PATH" --lora-scale "$LORA_SCALE")
  # ★ 挂了 LoRA 就把内存预算抬到 24 GiB（2026-10-25 实测）：
  #   引擎自带 16 GiB 的硬上限，而一个正常大小的社区 LoRA（100 MB 上下、
  #   一百多个权重矩阵）折进模型后峰值到 16.17 GiB —— 正好撞线，
  #   报的是 MemoryError，界面上看起来只是"生成失败"。
  #   抬到 24 GiB 能跑到 47 秒出歌；**没挂 LoRA 的路径一个字不动**，
  #   预算照旧 16，免得动到已经稳的那条路。
  LORA_ARGS+=(--memory-budget-gib 24)
fi

# ★ 2026-11-02 纯器乐：YuE2 不给词照样会哼，唯一可靠的办法是改谱。
#   先单独出谱（约 40 秒）→ 清空人声轨、旋律搬到器乐轨 → 再按改好的谱生成。
#   （`--instrumental` 是空壳；`[Instrumental]` 原来只归一成空歌词。）
ABC_OVERRIDE=""
INSTRUMENTAL_ONLY="$("$PY" -c 'import json,sys;d=json.load(open(sys.argv[1]));print("1" if (d.get("lyrics") or "").strip()=="[Instrumental]" else "0")' "$PARAMS" 2>/dev/null || echo 0)"
if [ "$INSTRUMENTAL_ONLY" = "1" ] && [ "$PLAN_ONLY" != "1" ]; then
  write_progress 2 "running" "纯器乐：先出谱（约 40 秒）" "null" "null" \
    "出来之后会把人声轨清空，只留乐器"
  INST_PLAN_DIR="$RUN_DIR/inst-plan"
  rm -rf "$INST_PLAN_DIR" 2>/dev/null || true
  if "$YUE2_BIN" plan "$REQUEST" \
       --model models/converted --vae models/vae --precision 8bit \
       --offline --require-ac --output "$INST_PLAN_DIR" >>"$LOG" 2>&1 \
     && [ -f "$INST_PLAN_DIR/score.abc" ] \
     && "$PY" "$PROJECT_ROOT/tools/strip_vocal.py" "$INST_PLAN_DIR/score.abc" >>"$LOG" 2>&1; then
    ABC_OVERRIDE="$INST_PLAN_DIR/score.abc"
    echo "[yue2_adapter] 纯器乐：人声轨已清空，按改好的谱生成" >>"$LOG"
  else
    write_progress 2 "failed" "纯器乐：改谱没成功" "null" "null" "日志里有原因"
    echo "[yue2_adapter] 纯器乐改谱失败" >&2
    exit 3
  fi
fi
INST_ARGS=()
[ -n "$ABC_OVERRIDE" ] && INST_ARGS+=(--abc "$ABC_OVERRIDE")

# ── 「契约版」（2026-11-08）：一份**已经是 YuE2 原生写法**的谱，直接喂给引擎 ──
#
# 由头：用户要「给器乐版本定旋律」。谱由 `scripts/midi_to_ins.py` 从 MIDI 压出来，
# 出来就是原生两声部（人声整小节休止、器乐那条有内容）—— 用户 2026-11-08 的原话：
# 「并不是干预伴奏，而是给器乐版本定旋律」。
#
# ⚠️ **为什么不能走 `abc_path`**：那条路会过 `prepare_score.py`，而它**只取人声那条
#    part、把 Ins 行写成整小节休止** —— 等于把器乐线整个抹掉（它是给外来谱收拾用的）。
#    所以契约版单独开一条：**谱一个字节都不动，直接塞进请求**。
CONTRACT_ABC="$(/usr/bin/python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("contract_abc") or "").strip())' "$PARAMS" 2>/dev/null || true)"
if [ -n "$CONTRACT_ABC" ]; then
  case "$CONTRACT_ABC" in
    /*) ;;
    *) CONTRACT_ABC="$(cd "$(dirname "$PARAMS")" && pwd)/$CONTRACT_ABC" ;;
  esac
  if [ ! -f "$CONTRACT_ABC" ]; then
    write_progress "$LAST_PERCENT" "failed" "找不到契约版的谱：$CONTRACT_ABC" "null" "null"
    echo "[yue2_adapter] 找不到契约版的谱：$CONTRACT_ABC" >&2
    exit 2
  fi
  /usr/bin/python3 - "$REQUEST" "$CONTRACT_ABC" <<'PYEOF'
import json, sys
req_path, abc_path = sys.argv[1], sys.argv[2]
data = json.load(open(req_path, encoding="utf-8"))
data["abc"] = open(abc_path, encoding="utf-8").read()
data["cot"] = "melody"
data["lyrics"] = data.get("lyrics") or ""
json.dump(data, open(req_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PYEOF
  INST_ARGS=()          # 契约版优先：别让纯器乐那套 --abc 盖掉
  echo "[yue2_adapter] 契约版：按给的谱直出，谱一个字不动" >>"$LOG"
fi

# `$ACTION` 是 plan（只要谱子）或 generate（出整首歌）—— 两条子命令
# 共用同一份请求 JSON 和同一组参数，差别只在它跑到哪一步停。
"$YUE2_BIN" "$ACTION" "$REQUEST" \
  --model models/converted \
  --vae models/vae \
  --precision 8bit \
  --offline \
  --require-ac \
  --output "$WORK_DIR" \
  ${LORA_ARGS[@]+"${LORA_ARGS[@]}"} \
  ${INST_ARGS[@]+"${INST_ARGS[@]}"} 2>&1 | tee "$LOG" | while IFS= read -r line; do
    parse_line "$line"
  done

RC=${PIPESTATUS[0]}
stop_watchdog

# 上面那句 `tee "$LOG"` 是**覆盖写**，会把开跑前记的「词谱字数」一行冲掉 —— 补记一次。
[ -n "$LYR_COUNT_AUDIT" ] && echo "[yue2_adapter] 词谱字数：${LYR_COUNT_AUDIT}" >> "$LOG"

# ------------------------------ 收尾 -----------------------------------------

safe_stem() {
  local s="$1"
  s="${s//\//_}"; s="${s//:/_}"; s="${s//$'\n'/ }"
  printf '%s' "$s"
}

if [ "$RC" -ne 0 ]; then
  MSG="生成失败（退出码 ${RC}）"
  case "$RC" in
    2)   MSG="参数不对：歌词或风格是空的（YuE2 得有词才唱）" ;;
    3)   MSG="模型没加载起来 —— 权重可能没下全（看 mlx-Yue/models/）" ;;
    6)   MSG="等太久，已经中止（超过 ${WATCHDOG_SECONDS} 秒）" ;;
    7)   MSG="YuE2 那边环境不完整" ;;
    124|137) MSG="被中止了" ;;
  esac
  # 作者定了「要插着电源跑」；电池下它会直接不干活 —— 把原因翻译成人话
  if [ -f "$LOG" ] && grep -qi "AC power\|on battery\|require_ac" "$LOG"; then
    MSG="要插上电源才能跑（YuE2 的规矩，怕电池掉太快）"
  fi
  write_progress "$LAST_PERCENT" "failed" "$MSG"
  echo "[yue2_adapter] $MSG" >&2
  exit "$RC"
fi

# ── 「只出谱子」这一档：产物只有谱子，到这儿就收工 ──
#
# 必须**在**下面那段音频检查之前返回 —— 这一档压根没有 `run/` 目录，
# 硬往下走会撞上「跑完了，但没找到音频文件」（退出码 5），
# 而谱子明明出得好好的。
if [ "$PLAN_ONLY" = "1" ]; then
  SCORE="$RUN_DIR/plan/score.abc"
  if [ ! -f "$SCORE" ]; then
    write_progress "$LAST_PERCENT" "failed" "跑完了，但没找到谱子文件"
    exit 5
  fi
  STEM="$(safe_stem "$TITLE_RAW")"
  [ -n "$STEM" ] || STEM="$(date +%Y%m%d-%H%M%S)"
  OUT_ABC="$OUT_DIR/$STEM.abc"
  cp -f "$SCORE" "$OUT_ABC" || { write_progress "$LAST_PERCENT" "failed" "谱子拷不过来"; exit 5; }
  # ★ 先把歌词写进这份谱子（插 `w:` 行）—— **必须在转 MusicXML 之前**：
  #   那份 XML 是从带词的 ABC 转出来的，自然也就带词了。
  #   失败不算整趟失败（谱子本身还在，只是没词）。
  "$PY" "$ATTACH_LYRICS" --abc-only "$OUT_ABC" "$PARAMS" >/dev/null 2>&1 || true
  # ★ 守门（用户 2026-10-16 的要求）：「**抄的时候也是这个原则 —— vocal 声部有音符
  #   就必须有歌词**，有可能这条是个废话，但是**怕他抽风**」。
  #   ⇒ 贴完词**立刻自查一遍**：结论写进日志、并附进进度的 detail（界面上看得见）。
  #   **只报告、不改产物** —— 达标不达标都如实说，别粉饰。
  LYR_AUDIT="$("$PY" "$ATTACH_LYRICS" --check "$OUT_ABC" 2>/dev/null | tail -1)"
  echo "[yue2_adapter] 歌词自查：${LYR_AUDIT:-自查没跑起来}" >> "$LOG"
  # 顺手出一份 Dorico 能直接打开的 MusicXML；这一步失败不算整趟失败
  "$ABCXML" to-xml "$OUT_ABC" >/dev/null 2>&1 || true
  # 自检探针：先看提示词写没写男女声；没写再扫人声谱的加线（引擎侧自动判，不需要人看谱）
  "$PY" "$FIX_CLEF" "${OUT_ABC%.abc}.xml" --prompt "$PROMPT_TEXT" >> "$LOG" 2>&1 || true
  # output 留空（这一条没有声音）、score 指那份 .abc —— 界面据此把它记成
  # 「谱子已出、还没唱」，并且能把这份谱子顶到"这次照它唱"的位置。
  write_progress 100 "done" "谱子出好了，还没唱。按「生成」就照这一份唱" \
    "null" "\"$(json_escape "$OUT_ABC")\"" "这份谱子就在这次新建的文件夹里${LYR_AUDIT:+　·　歌词：$LYR_AUDIT}"
  echo "[yue2_adapter] 谱子：$OUT_ABC"
  exit 0
fi

AUDIO="$RUN_DIR/run/audio.flac"
# ★ 2026-10-13：交给用户的谱**用"给人看的"那一份**（通用写法、带和弦、原始八度）。
#   模型自己那份是**原生写法**（标题空、和弦被剥掉、八度挪过）—— 它读着顺手，人看着别扭。
#   模型实际唱的谱仍在 `.yue2/run/score.abc`，要核对随时有。
SCORE="$RUN_DIR/run/score.abc"
if [ -f "$OUT_DIR/import-staging.foruser.abc" ]; then
  SCORE="$OUT_DIR/import-staging.foruser.abc"
fi
if [ ! -f "$AUDIO" ]; then
  write_progress "$LAST_PERCENT" "failed" "跑完了，但没找到音频文件"
  exit 5
fi

STEM="$(safe_stem "$TITLE_RAW")"
[ -n "$STEM" ] || STEM="$(date +%Y%m%d-%H%M%S)"

OUT_AUDIO="$OUT_DIR/$STEM.flac"
OUT_ABC="$OUT_DIR/$STEM.abc"
cp -f "$AUDIO" "$OUT_AUDIO" || { write_progress "$LAST_PERCENT" "failed" "音频拷不过来"; exit 5; }
SCORE_JSON="null"
if [ -f "$SCORE" ]; then
  cp -f "$SCORE" "$OUT_ABC"
  # ★ 先把歌词写进这份谱子（插 `w:` 行），再转 MusicXML —— 与「只出谱子」那一档
  #   同一个理由：那份 XML 从带词的 ABC 转出来，自然就带词了。
  "$PY" "$ATTACH_LYRICS" --abc-only "$OUT_ABC" "$PARAMS" >/dev/null 2>&1 || true

  # ★ 2026-10-18 用户要的：歌词框空着时，YuE2 会**自己编词唱**（实测），
  #   那段词只活在音频里，谱子上一个字都没有。这里用本机听写把它抓出来贴上去。
  #
  #   三条边界：
  #     · **只对中文采用** —— attach_lyrics 是按"一字一个音符位"贴的，
  #       英文会被拆成字母逐个贴（实测 `I 'm _ no t _ b os s`），等于拼字。
  #       asr_lyrics.py 发现不是中文就退出码 10，这里据此跳过。
  #     · **用户填了词就不动** —— 他写的词比听写准，别拿猜的盖掉真的。
  #     · **失败不算整趟失败** —— 听写服务没开、听不清，都只是"谱子没词"，
  #       音频和谱子照旧给。
  EMPTY_LYRICS="$("$PY" -c 'import json,sys
try:
    v=(json.load(open(sys.argv[1])).get("lyrics") or "").strip()
except Exception:
    v=""
print("1" if (not v or v=="[Instrumental]") else "0")' "$PARAMS")"
  if [ "$EMPTY_LYRICS" = "1" ]; then
    if "$PY" "$PROJECT_ROOT/scripts/asr_lyrics.py" "$OUT_AUDIO" > "$RUN_DIR/asr-lyrics.txt" 2>>"$LOG"; then
      "$PY" "$ATTACH_LYRICS" --abc-only "$OUT_ABC" "$RUN_DIR/asr-lyrics.txt" >/dev/null 2>&1 || true
      # 谱子头上留一句：这些字是**听出来的**，不是人写的 —— 错字以耳朵为准。
      # 不写这一句，拿到谱子的人会以为模型真的"照词唱对了"。
      "$PY" - "$OUT_ABC" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p, encoding='utf-8').read().split('\n')
if not any('来自听写' in l for l in lines[:5]):
    lines.insert(0, '% 歌词来自听写：模型自己编的词，仅供参考，错字以耳朵为准')
    open(p, 'w', encoding='utf-8').write('\n'.join(lines))
PYEOF
      echo "[yue2_adapter] 谱子上的词来自听写（这首歌没填词）：$(head -c 80 "$RUN_DIR/asr-lyrics.txt")" >> "$LOG"
    fi
  fi
  # ★ 守门（用户 2026-10-16 的要求）：「**抄的时候也是这个原则 —— vocal 声部有音符
  #   就必须有歌词**，有可能这条是个废话，但是**怕他抽风**」。
  #   ⇒ 贴完词**立刻自查一遍**：结论写进日志、并附进进度的 detail（界面上看得见）。
  #   **只报告、不改产物** —— 达标不达标都如实说，别粉饰。
  LYR_AUDIT="$("$PY" "$ATTACH_LYRICS" --check "$OUT_ABC" 2>/dev/null | tail -1)"
  echo "[yue2_adapter] 歌词自查：${LYR_AUDIT:-自查没跑起来}" >> "$LOG"
  # 顺手出一份 Dorico 能直接打开的 MusicXML；这一步失败不算整趟失败
  "$ABCXML" to-xml "$OUT_ABC" >/dev/null 2>&1 || true
  # 自检探针：先看提示词写没写男女声；没写再扫人声谱的加线（引擎侧自动判，不需要人看谱）
  "$PY" "$FIX_CLEF" "${OUT_ABC%.abc}.xml" --prompt "$PROMPT_TEXT" >> "$LOG" 2>&1 || true
  SCORE_JSON="\"$(json_escape "$OUT_ABC")\""
fi

DURATION="$("$PY" - "$RUN_DIR/run/result.json" <<'PYEOF'
import json,sys
try:
    s=int(round(json.load(open(sys.argv[1])).get("audio_seconds",0)))
except Exception:
    print(""); raise SystemExit
print(f"{s//60} 分 {s%60} 秒" if s>=60 else f"{s} 秒")
PYEOF
)"

if [ -n "$DURATION" ]; then
  write_progress 100 "done" "出好了：${DURATION}" \
    "\"$(json_escape "$OUT_AUDIO")\"" "$SCORE_JSON" \
    "音频和谱子（.abc、给 Dorico 的 MusicXML）都在这次新建的文件夹里${LYR_AUDIT:+　·　歌词：$LYR_AUDIT}${LYR_COUNT_NOTE}"
else
  write_progress 100 "done" "出好了" \
    "\"$(json_escape "$OUT_AUDIO")\"" "$SCORE_JSON" \
    "音频和谱子都在这次新建的文件夹里${LYR_AUDIT:+　·　歌词：$LYR_AUDIT}${LYR_COUNT_NOTE}"
fi

echo "[yue2_adapter] 音频：$OUT_AUDIO"
exit 0
