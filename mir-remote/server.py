#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MIR Remote — 手机上遥控本机 MIR 引擎出一首歌。

它做的只有一件事：把「选引擎 → 写词 → 出歌 → 拿歌拿谱」这条路做全。
算力全在本机：这个服务只传话，不动 MIR 的 SwiftUI 本体，也不发任何出网请求。

它复用的是 MIR 早就定好的引擎契约（四台 adapter 同一套）：
    写 params.json → 跑 <引擎>_adapter.sh → 读 progress.json → 看退出码
所以 MIR 那边换引擎、改参数，这边只要跟着 /v1/info 变，不用改代码。

协议（一页纸，/v1/，改协议就开 /v2/）：
    GET  /v1/info                  我是谁、能干什么（引擎清单、能力）
    POST /v1/pair                  {code} → {token}
    POST /v1/jobs                  {engine,title,lyrics,style,...} → {id}
    GET  /v1/jobs/<id>             {percent,state,message,eta_seconds,outputs}
    POST /v1/jobs/<id>/cancel      停
    GET  /v1/jobs/<id>/files/<n>   下载（要 token）
    GET  /v1/songs                 作品库
    GET  /s/<id>                   分享页（不用 token，链接本身就是钥匙）
    GET  /s/<id>/files/<n>         分享页里的下载

用法：
    python3 mir-remote/server.py            # 0.0.0.0:7871
    MIR_PORT=7872 python3 mir-remote/server.py

环境变量：MIR_PORT / MIR_HOST / MIR_SONGS_DIR（默认外盘）
"""

import errno
import json
import mimetypes
import os
import queue
import re
import secrets
import shutil
import socket
import subprocess
import sys
import threading
import time
import traceback
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse
import urllib.error
import urllib.request

# ────────────────────────────── 位置与配置 ──────────────────────────────

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)                 # my-songwriter/
STATE = os.path.join(HERE, "state")
JOBS_DIR = os.path.join(STATE, "jobs")
WEB_DIR = os.path.join(HERE, "web")
# 手机 App（壳）的安装包；编译脚本是 tools/build.sh
APK_PATH = os.path.join(HERE, "dist", "mir-remote.apk")
LOG_PATH = os.path.join(STATE, "server.log")


def _env_path(key, default):
    v = os.environ.get(key)
    return os.path.expanduser(v) if v else default


SONGS_DIR = _env_path("MIR_SONGS_DIR", "/Volumes/REBIRTH/MI/Songs")
PORT = int(os.environ.get("MIR_PORT") or 7871)
HOST = os.environ.get("MIR_HOST") or "0.0.0.0"

PROTOCOL_VERSION = 1

# 手机到底连到没连到、连上来又走没走 —— 出问题时要能回答这个。
# 只记时间/来源地址/结果，不记内容；每次启动重开，别让它长成几 MB。
REQ_LOG = os.path.join(STATE, "requests.log")


def reqlog(kind, client, detail=""):
    try:
        with open(REQ_LOG, "a") as f:
            f.write("%s %-4s %-15s %s\n" % (time.strftime("%H:%M:%S"), kind,
                                             client[0] if client else "-", detail))
    except Exception:
        pass


ENGINE_RUNNING_PATTERNS = (
    "ace_mlx_adapter.sh",
    "yue2_adapter.sh",
    "stable_audio_adapter.sh",   # 入口已撤，但手动跑时也要算"有活"
    "render_adapter.sh",          # 旧 PyTorch 那条，同理
)


def find_tool(name):
    """本机 PATH 只有 /usr/bin:/bin:…，所以家用工具要按绝对路径找。"""
    for cand in ("/opt/homebrew/bin/" + name, "/usr/local/bin/" + name, "/usr/bin/" + name):
        if os.path.exists(cand):
            return cand
    return None


FFMPEG = find_tool("ffmpeg")
FFPROBE = find_tool("ffprobe")
CAFFEINATE = "/usr/bin/caffeinate" if os.path.exists("/usr/bin/caffeinate") else None


def log(msg):
    line = "[%s] %s" % (datetime.now().strftime("%H:%M:%S"), msg)
    print(line, flush=True)
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


class WriteError(Exception):
    """成品往作品库里放的时候写不进去（外盘没插 / 被别的程序占着）。"""


# ────────────────────────────── 四台引擎 ──────────────────────────────
#
# params 里的每一项都是**给遥控器看的**：遥控器完全照它画界面，
# 不认识的就跳过。所以学生做的 Windows 版少一台引擎也不会崩。
#
# ⚠️ local 一律 true —— 四台全是本机推理。偷偷调云端等于把这件事的价值抽掉。

ENGINES = [
    {
        "id": "acestep",
        "title": "成曲",
        "hint": "完整编曲，唱得准；也能出纯器乐",
        "eta_hint": "90 秒的歌约 30 秒出",
        "script": "ace_mlx_adapter.sh",
        "outputs": ["audio:wav"],
        # 2026-11-19 换的引擎：本机 MLX 上的 ACE-Step 1.5 XL Turbo 8bit。
        # 不再查 python_embeded / checkpoints（那套已经退役）。
        "needs": ["/Applications/MLX-Serve.app",
                  "~/.mlx-serve/models/ACE-Step-1.5-XL-Turbo-MLX-Serve-8bit"],
        "lyrics": True,
        "style": "text",
        "steps": None,            # 8 步固定，没有档位可挑
        "duration": {"min": 10, "max": 600, "default": 90},
        "eta": None,
        "presets": ["流行女声", "流行男声", "民谣", "摇滚", "爵士", "古风", "电子", "电影配乐"],
    },
    {
        "id": "yue2",
        "title": "写歌",
        "hint": "会唱词，还出谱",
        "eta_hint": "约 5 分钟（快档）",
        "script": "yue2_adapter.sh",
        "outputs": ["audio:flac", "score:abc", "score:musicxml"],
        "needs": ["../yue2-local/yue2", "../yue2-local/abcxml"],
        "lyrics": True,
        "style": "text",
        "steps": [8, 32],
        "duration": None,
        "eta": {8: 300, 32: 700},
        "presets": ["流行女声", "流行男声", "民谣", "爵士", "Bossa Nova", "古风", "电子", "电影配乐"],
    },
]

ENGINE_BY_ID = {e["id"]: e for e in ENGINES}

# ACE-Step 吃的是**描述性长句**，而且本机这个 8bit 移植**没有 LM 扩写**
# （官方那套有个规划器会把短句补全，这里没有）。所以手机上的中文按钮
# 由服务端换成一句写全的英文描述 —— 和 MIR 界面里那套写法一致（2026-11-19）。
ACE_STYLE = {
    "流行女声": "warm Mandarin pop ballad, soft piano, strings, intimate female vocal, 88 bpm, C major, 4/4",
    "流行男声": "modern Mandarin pop, acoustic guitar, warm male vocal, 95 bpm, C major, 4/4",
    "民谣": "acoustic folk, fingerpicked steel guitar, upright bass, soft male vocal, 72 bpm, G major, 3/4",
    "摇滚": "stadium rock, crunchy electric guitars, driving drums, powerful male vocal, 120 bpm, E minor, 4/4",
    "爵士": "jazz trio, upright bass, brushed drums, warm piano, 100 bpm, F major, 4/4",
    "古风": "Chinese guzheng and dizi, cinematic strings, gentle female vocal, 75 bpm, D minor, 4/4",
    "电子": "electronic pop, synth arpeggios, punchy drums, female vocal, 118 bpm, A minor, 4/4",
    "电影配乐": "cinematic orchestral, sweeping strings, epic brass, dramatic percussion, instrumental, 80 bpm, D minor, 4/4",
}


def ace_style(raw):
    """中文按钮换成写全的英文描述；自由输入原样交出去（编码器是多语言的）。"""
    s = (raw or "").strip()
    if s in ACE_STYLE:
        return ACE_STYLE[s]
    return s


def _abs_path(rel):
    """引擎本体可以写在项目里，也可以写在家目录里（Stable Audio 就是 ~/AI-Studio）。"""
    rel = os.path.expanduser(rel)
    return rel if os.path.isabs(rel) else os.path.join(PROJECT, rel)


def engine_available(e):
    """这台引擎在本机装好了吗。缺什么要说得出来。"""
    missing = [p for p in e["needs"] if not os.path.exists(_abs_path(p))]
    return (not missing), missing


# ────────────────────────────── 小工具 ──────────────────────────────


# ───────────────────────── 乐谱工作台（NotaGen）代理 ─────────────────────────
#
# 曲谱工作台是一个独立的本机服务（127.0.0.1:7874，FastAPI）。它只绑本机，
# 手机够不着 —— 所以由这里代转，手机只跟 7871 说话。
#
# 它的接口（2026-11-19 核对）：
#   GET  /api/options              → {combos: [[时期, 作曲家, 编制], ...]}
#   POST /api/generate             → {task_id}
#   GET  /api/task/<tid>           → {status, chars_now, chars, elapsed, xml, preview, error}
#   GET  /api/settings             → {output_dir}
# 它只报「已经写了多少字」，没有总量 ⇒ 进度条按字符数估，并显示真实字数。

NOTAGEN_URL = os.environ.get("MIR_NOTAGEN_URL") or "http://127.0.0.1:7874"
SCORE_TASKS = {}          # 本服务这边的 id -> {tid, period, composer, instrument, ...}
SCORE_LOCK = threading.Lock()


def notagen_call(path, body=None, timeout=20):
    url = NOTAGEN_URL + path
    if body is None:
        req = urllib.request.Request(url)
    else:
        req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def notagen_ready():
    try:
        notagen_call("/api/options", timeout=3)
        return True
    except Exception:
        return False


def score_title(task):
    return "%s · %s · %s" % (task["period"], task["composer"], task["instrument"])


def score_percent(st):
    """它只给字数，没有总量：按 3000 字当满格、封顶 95%，剩下的 5% 留给转谱。"""
    if st.get("status") == "done":
        return 100
    chars = int(st.get("chars_now") or 0)
    return max(2, min(95, int(chars / 3000.0 * 95)))


def archive_score(task, st):
    """把 xml 收进作品库（外盘），并登记成一条能分享的作品。只做一次。"""
    if task.get("archived"):
        return
    xml_name = st.get("xml")
    if not xml_name:
        return
    try:
        out_dir = (notagen_call("/api/settings", timeout=5).get("output_dir") or "").strip()
    except Exception:
        out_dir = ""
    src = os.path.join(os.path.expanduser(out_dir), xml_name) if out_dir else ""
    if not src or not os.path.isfile(src):
        # 找不到原文件就只报链接不可用，不假装成功
        task["archive_error"] = "乐谱文件不在原来那个文件夹里了"
        return
    stamp = time.strftime("%Y%m%d-%H%M%S")
    name = "%s %s" % (stamp, score_title(task))
    name = re.sub(r"[\\/:*?\"<>|]", "-", name)[:90]
    dest_dir = os.path.join(SONGS_DIR, name)
    os.makedirs(dest_dir, exist_ok=True)
    dst = os.path.join(dest_dir, os.path.basename(src))
    shutil.copy2(src, dst)
    size = os.path.getsize(dst)
    sid = task["id"]
    song = {
        "id": sid,
        "title": score_title(task),
        "engine": "score",
        "engine_title": "乐谱",
        "created": datetime.now().strftime("%Y-%m-%d %H:%M"),
        "seconds": st.get("elapsed") or 0,
        "files": [{"name": os.path.basename(dst), "kind": "score", "size": size}],
        "style": "%s / %s / %s" % (task["period"], task["composer"], task["instrument"]),
        "dir": dest_dir,
    }
    task["store"].add_song(song)
    task["archived"] = True
    task["share_id"] = sid
    log("乐谱收好了：%s" % song["title"])


def read_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def write_json(path, obj):
    """原子写：网页随时在轮询，不能让它读到半截 JSON。"""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def now_ts():
    return time.time()


def fmt_time(ts):
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")


def safe_stem(raw, max_length=40):
    """跟 MIR 的 FileName.safe 同一套规则 —— 目录名和文件名都用它。"""
    t = str(raw or "")
    for ch in ("/", ":", "\\"):
        t = t.replace(ch, "_")
    t = t.replace("\n", " ").replace("\r", " ").replace("\t", " ")
    t = re.sub(r" {2,}", " ", t).strip()
    t = t.rstrip(".")
    if len(t) > max_length:
        cut = t[:max_length]
        # 英文别切在半截词上；中文没有空格，退不动就原样截
        sp = cut.rfind(" ")
        if sp >= max_length // 2:
            cut = cut[:sp]
        t = cut.strip()
    return t or "未命名"


def fmt_duration(seconds):
    if seconds is None:
        return ""
    s = int(round(seconds))
    if s >= 60:
        return "%d分%d秒" % (s // 60, s % 60)
    return "%d秒" % max(s, 1)


def fmt_size(n):
    """文件大小说人话：B / KB / MB（分享页上让人一眼知道下哪个）。"""
    try:
        n = int(n)
    except (TypeError, ValueError):
        return "—"
    if n < 1024:
        return "%d B" % n
    if n < 1024 * 1024:
        return "%.0f KB" % (n / 1024.0)
    return "%.1f MB" % (n / 1024.0 / 1024.0)


def probe_duration(path):
    if not (FFPROBE and path and os.path.exists(path)):
        return None
    try:
        out = subprocess.run(
            [FFPROBE, "-v", "error", "-show_entries", "format=duration",
             "-of", "default=nw=1:nk=1", path],
            capture_output=True, text=True, timeout=30).stdout.strip()
        return float(out)
    except Exception:
        return None


def clean_env():
    env = os.environ.copy()
    for k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "all_proxy"):
        env.pop(k, None)
    env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
    return env


AUDIO_EXT = {".flac", ".wav", ".mp3", ".m4a", ".aac", ".ogg"}
SCORE_EXT = {".abc", ".musicxml", ".xml", ".mid", ".midi"}
SKIP_DIRS = {".yue2", ".heartmula", ".stable_audio", ".acestep", "__pycache__"}


def walk_outputs(root):
    """收集产物。跳过各引擎自己的隐藏工作目录（里面有日志和中间文件）。"""
    audio, scores = [], []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".") and d not in SKIP_DIRS]
        for name in filenames:
            if name.startswith("."):
                continue
            ext = os.path.splitext(name)[1].lower()
            full = os.path.join(dirpath, name)
            if ext in AUDIO_EXT:
                audio.append(full)
            elif ext in SCORE_EXT:
                scores.append(full)
    # 主音频：wav 与 flac 都是无损，取最大的那份（yue2 会出分段小文件）
    def _size(p):
        try:
            return os.path.getsize(p)
        except OSError:
            return 0
    audio.sort(key=_size, reverse=True)
    return audio, scores


def guess_mime(name):
    ext = os.path.splitext(name)[1].lower()
    table = {
        ".flac": "audio/flac", ".wav": "audio/wav", ".mp3": "audio/mpeg",
        ".m4a": "audio/mp4", ".aac": "audio/aac", ".ogg": "audio/ogg",
        ".abc": "text/plain; charset=utf-8",
        ".musicxml": "application/vnd.recordare.musicxml",
        ".xml": "application/xml", ".mid": "audio/midi", ".midi": "audio/midi",
        ".html": "text/html; charset=utf-8", ".js": "application/javascript; charset=utf-8",
        ".css": "text/css; charset=utf-8", ".json": "application/json; charset=utf-8",
        ".png": "image/png", ".svg": "image/svg+xml", ".ico": "image/x-icon",
    }
    return table.get(ext) or mimetypes.guess_type(name)[0] or "application/octet-stream"


# ────────────────────────────── 状态 ──────────────────────────────


class Store:
    def __init__(self):
        self.lock = threading.RLock()
        os.makedirs(JOBS_DIR, exist_ok=True)
        self.jobs = {}
        for name in sorted(os.listdir(JOBS_DIR)):
            if not name.endswith(".json"):
                continue
            j = read_json(os.path.join(JOBS_DIR, name))
            if isinstance(j, dict) and j.get("id"):
                self.jobs[j["id"]] = j
        self.songs = read_json(os.path.join(STATE, "songs.json"), [])
        if not isinstance(self.songs, list):
            self.songs = []
        self.tokens = read_json(os.path.join(STATE, "tokens.json"), {"items": []})
        if not isinstance(self.tokens.get("items"), list):
            self.tokens = {"items": []}
        self.pair_code = self._load_pair_code()
        self._heal_after_restart()

    # ── 配对码 ──
    def _load_pair_code(self):
        path = os.path.join(STATE, "pair_code.txt")
        code = ""
        try:
            with open(path, "r", encoding="utf-8") as f:
                code = f.read().strip()
        except Exception:
            pass
        if not (len(code) == 6 and code.isdigit()):
            code = "%06d" % secrets.randbelow(1000000)
            with open(path, "w", encoding="utf-8") as f:
                f.write(code + "\n")
        return code

    # ── 服务重启后，别让旧任务永远「正在跑」 ──
    def _heal_after_restart(self):
        changed = False
        for j in self.jobs.values():
            if j.get("state") in ("queued", "running", "waiting"):
                j["state"] = "failed"
                j["message"] = "上次没跑完（服务重启了），再点一次就好"
                j["finished"] = now_ts()
                j["percent"] = 0
                changed = True
                self.save_job(j)
        if changed:
            log("把上次没跑完的任务标成失败（服务重启过）")

    def save_job(self, job):
        with self.lock:
            path = os.path.join(JOBS_DIR, job["id"] + ".json")
            write_json(path, job)
            self.jobs[job["id"]] = job

    def job(self, jid):
        with self.lock:
            return self.jobs.get(jid)

    def add_song(self, song):
        with self.lock:
            self.songs.insert(0, song)
            write_json(os.path.join(STATE, "songs.json"), self.songs)

    def song(self, sid):
        with self.lock:
            for s in self.songs:
                if s.get("id") == sid:
                    return s
        return None

    # ── token ──
    def check_token(self, token):
        if not token:
            return False
        with self.lock:
            for item in self.tokens.get("items", []):
                if secrets.compare_digest(str(item.get("token", "")), token):
                    return True
        return False

    def issue_token(self, name):
        token = secrets.token_urlsafe(24)
        with self.lock:
            self.tokens.setdefault("items", []).append(
                {"token": token, "name": (name or "手机")[:40], "created": fmt_time(now_ts())})
            write_json(os.path.join(STATE, "tokens.json"), self.tokens)
        return token


# ────────────────────────────── 出歌 ──────────────────────────────


class Runner(threading.Thread):
    """一次只跑一首。队列串行 —— 引擎吃内存，两首同时跑会把机器撑爆。"""

    def __init__(self, store):
        super().__init__(daemon=True)
        self.store = store
        self.q = queue.Queue()
        self.cancelled = set()
        self.current = None
        self.lock = threading.Lock()

    # ---- 对外：排一首 ----
    def enqueue(self, job):
        with self.lock:
            pending = sum(1 for j in self.store.jobs.values()
                          if j.get("state") in ("queued", "running", "waiting"))
        if pending >= 4:
            raise RuntimeError("已经排了几首了，等它们出来再点")
        self.q.put(job["id"])

    def cancel(self, jid):
        with self.lock:
            self.cancelled.add(jid)

    # ---- 主循环 ----
    def run(self):
        while True:
            jid = self.q.get()
            try:
                self.execute(jid)
            except Exception:
                log("任务 %s 炸了：\n%s" % (jid, traceback.format_exc()))
                self._fail(jid, "这次没成，换一个引擎再试一次")

    def _update(self, job, **kw):
        job.update(kw)
        self.store.save_job(job)

    def _fail(self, job, message, detail=""):
        if isinstance(job, str):
            job = self.store.job(job)
        if not job:
            return
        self._update(job, state="failed", message=message,
                     detail=detail, finished=now_ts(), eta_seconds=None)

    def execute(self, jid):
        job = self.store.job(jid)
        if not job:
            return
        if jid in self.cancelled:
            self._update(job, state="cancelled", message="已经停了", finished=now_ts())
            return

        e = ENGINE_BY_ID.get(job.get("engine"))
        if not e:
            self._fail(job, "这台引擎不认得，换一台再试")
            return
        ok, missing = engine_available(e)
        if not ok:
            self._fail(job, "这台引擎还没准备好（缺 %s）" % "、".join(os.path.basename(p) for p in missing))
            return
        if not os.path.isdir(SONGS_DIR):
            self._fail(job, "外盘没插（作品要存到外盘），插上再试")
            return

        job_dir = os.path.join(JOBS_DIR, jid)
        out_dir = os.path.join(job_dir, "out")
        prog_path = os.path.join(job_dir, "progress.json")
        params_path = os.path.join(job_dir, "params.json")
        run_log = os.path.join(job_dir, "run.log")
        os.makedirs(out_dir, exist_ok=True)

        self.current = jid
        if self._other_engine_pid():
            self._update(job, state="waiting", percent=0,
                         message="另一头在出一首，等它出来就轮到你",
                         detail="MIR 界面和遥控器共用同一批引擎，一次只跑一首")
            if not self._wait_until_idle(jid):
                return

        # ── 写参数（字段名与 MIR 的 GenerationRequest 一致）──
        title = job.get("title") or "未命名"
        seed = job.get("seed")
        if seed is None:
            seed = secrets.randbelow(2 ** 31 - 1)
        style = job.get("style") or ""
        if e["id"] == "acestep":
            style = ace_style(style)
        params = {
            "prompt": style,
            "lyrics": job.get("lyrics") or "[Instrumental]",
            "mode": "generate",
            "duration": job.get("duration") or (e["duration"]["default"] if e.get("duration") else 60),
            "steps": job.get("steps") or (8 if e.get("steps") else 8),
            "seed": seed,
            "thinking": False,
            "language": "unknown",
            "title": title,
            "engine": "acestep" if e["id"] == "acestep" else e["id"],
            "plan_only": False,
        }
        write_json(params_path, params)

        script = os.path.join(PROJECT, e["script"])
        if not os.path.exists(script):
            self._fail(job, "这台引擎的脚本不在了（%s），换一台再试" % e["script"])
            return

        self._update(job, state="running", percent=0,
                     message="正在启动…", detail="先把这一趟交给引擎，马上就有下文",
                     started=now_ts(), pid=None, eta_seconds=self._default_eta(job, e))

        logf = open(run_log, "w", encoding="utf-8")
        proc = subprocess.Popen(
            ["/bin/bash", script, "--params", params_path, "--out-dir", out_dir, "--progress", prog_path],
            cwd=PROJECT, stdout=logf, stderr=subprocess.STDOUT,
            env=clean_env(), start_new_session=True)
        self._update(job, pid=proc.pid)

        # 跑歌期间别让机器睡着；adapter 一退，caffeinate 自己跟着退
        caf = None
        if CAFFEINATE:
            try:
                caf = subprocess.Popen([CAFFEINATE, "-dimsu", "-w", str(proc.pid)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                caf = None

        last_write = 0.0
        last_percent = -1
        killed = False
        try:
            while True:
                rc = proc.poll()
                snap = read_json(prog_path, {}) or {}
                p = snap.get("percent")
                msg = snap.get("message") or ""
                state = snap.get("state") or ""
                changed = False
                if isinstance(p, (int, float)) and int(p) != last_percent:
                    job["percent"] = max(0, min(100, int(p)))
                    last_percent = int(p)
                    changed = True
                if msg and msg != job.get("message"):
                    job["message"] = msg
                    changed = True
                job["eta_seconds"] = self._estimate_eta(job, e)
                if changed and time.time() - last_write > 0.9:
                    self.store.save_job(job)
                    last_write = time.time()

                if jid in self.cancelled or job.get("cancel_requested"):
                    self._kill(proc)
                    killed = True

                if rc is not None:
                    break
                if state == "failed" and rc is None and time.time() - job.get("started", 0) > 3:
                    # 脚本自己说失败了却还在跑 —— 等它退，避免误杀正在收尾的进程
                    pass
                time.sleep(0.6)
        finally:
            if caf and caf.poll() is None:
                try:
                    caf.terminate()
                except Exception:
                    pass
            try:
                logf.close()
            except Exception:
                pass

        rc = proc.wait()
        if killed:
            self._update(job, state="cancelled", message="已经停了", finished=now_ts(), eta_seconds=None)
            return

        snap = read_json(prog_path, {}) or {}
        if rc != 0:
            self._fail(job, self._human_error(rc, snap), detail=self._log_tail(run_log))
            return

        # ── 收产物 ──
        try:
            outputs, seconds, dest = self._collect(job, out_dir, snap)
        except WriteError as ex:
            # ★ 存不进去时**绝不删成品目录** —— 那等于白跑一首（2026-11-17 实际踩到）
            log("成品存不进去：%s" % ex)
            self._fail(job, "成品存不进去：外盘写不了。插好外盘、或确认它没被别的程序占着，再点一次")
            return
        except Exception:
            log("收集产物失败：\n%s" % traceback.format_exc())
            outputs, seconds, dest = [], None, None
        if not outputs:
            self._fail(job, "跑完了但没看到成品。成品目录先留着，可以到电脑上看一看")
            return

        song = {
            "id": jid,
            "title": job.get("title") or "未命名",
            "engine": e["id"],
            "engine_title": e["title"],
            "created": fmt_time(now_ts()),
            "seconds": seconds,
            "files": outputs,
            "seed": job.get("seed"),
            "lyrics": job.get("lyrics") or "",
            "style": job.get("style") or "",
            "dir": dest,
        }
        self.store.add_song(song)
        self._update(job, state="done", percent=100,
                     message=job.get("message") or "出好了",
                     outputs=outputs, song_id=jid, finished=now_ts(),
                     seconds=song["seconds"], eta_seconds=0)
        log("出好了：%s（%s，%s）" % (song["title"], e["title"], fmt_duration(song["seconds"])))
        self._cleanup_job_dir(job)

    # ---- 等别的引擎跑完 ----
    def _wait_until_idle(self, jid):
        job = self.store.job(jid)
        start = time.time()
        while True:
            if jid in self.cancelled:
                self._update(job, state="cancelled", message="已经停了", finished=now_ts())
                return False
            other = self._other_engine_pid()
            if not other:
                return True
            if time.time() - start > 7200:
                self._fail(job, "另一头跑了太久，这一首先撤下来，等会儿再点")
                return False
            time.sleep(5)
            if time.time() - start > 20:
                job["detail"] = "另一头正跑到一半，轮到你就自动开始"

    def _other_engine_pid(self):
        """MIR 界面那边是不是正在跑。

        第一判据是它自己的进度文件：MIR 每半秒写一次 output/progress.json，
        state=running 且 updated 还在动，就说明那边真的在跑。
        （2026-11-17 实测：DSH 的沙箱里 `ps` 会被拒 —— 所以不能只靠 ps。）
        我们自己的任务写到 mir-remote/state/jobs/…，跟它不是一个文件，不会误判。
        """
        gui_prog = os.path.join(PROJECT, "output", "progress.json")
        snap = read_json(gui_prog, {}) or {}
        if snap.get("state") == "running":
            upd = snap.get("updated") or 0
            if upd and abs(time.time() - upd) < 30:
                return "gui"

        try:
            out = subprocess.run(["/bin/ps", "-eo", "pid=,command="],
                                 capture_output=True, text=True, timeout=8).stdout
        except Exception:
            return None
        for line in out.splitlines():
            if not any(s in line for s in ENGINE_RUNNING_PATTERNS):
                continue
            if "mir-remote/state/jobs" in line:
                continue
            parts = line.strip().split(None, 1)
            if parts and parts[0].isdigit():
                return parts[0]
        return None

    def _estimate_eta(self, job, e):
        """估还要多久。

        ★ 别用「已等时间 × 剩余百分比」硬推 —— 百分比停住时那个数会一直涨
          （2026-11-17 实测：p 卡在 8%，eta 从 243 秒涨到 361 秒，越等越久）。
          改成按「最近一次百分比变化的速度」算，percent 不动时保持上次的估计。
        """
        p = job.get("percent") or 0
        now = now_ts()
        p0 = job.get("_p0")
        t0 = job.get("_t0")
        if p0 is None or p > p0:
            job["_p0"] = p
            job["_t0"] = now
            p0, t0 = p, now
        default = self._default_eta(job, e)
        if p >= 5 and p0 is not None and t0 and p > p0 and now > t0:
            rate = (p - p0) / (now - t0)
            eta = (100 - p) / rate
            return int(max(10, min(eta, default * 2.5)))
        return int(default)

    def _default_eta(self, job, e):
        steps = job.get("steps")
        if e.get("eta") and steps in e["eta"]:
            return int(e["eta"][steps])
        dur = job.get("duration") or (e["duration"]["default"] if e.get("duration") else 60)
        # 粗略：音频长度 × 1.5（RTF 实测 1.39）+ 启动余量
        return int(dur * 1.5 + 45)

    def _kill(self, proc):
        try:
            os.killpg(os.getpgid(proc.pid), 15)
        except Exception:
            try:
                proc.terminate()
            except Exception:
                pass
        time.sleep(3)
        if proc.poll() is None:
            try:
                os.killpg(os.getpgid(proc.pid), 9)
            except Exception:
                pass

    def _human_error(self, rc, snap):
        msg = (snap.get("message") or "").strip()
        table = {
            2: "给的参数它不认，换一台再试",
            3: "这台引擎这次没起来（模型没加载上），等一会儿再试",
            4: "这台引擎缺个东西，先换一台",
            5: "这次没成，换一个引擎再试一次",
            6: "这次跑太久了，已经停了。短一点再试",
            7: "这台引擎还没准备好，换一台",
        }
        # ★ 失败只说人话：引擎名、脚本名、退出码、英文报错一律不进眼睛
        # （adapter 自己的 message 留在 detail 里，愿意细看的人能查到）
        return table.get(rc, "这次没成，换一个引擎再试一次")

    def _log_tail(self, path, limit=1500):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                data = f.read()
            return data[-limit:]
        except Exception:
            return ""

    # ---- 收成品并并进作品库 ----
    def _collect(self, job, out_dir, snap):
        audio_paths, score_paths = walk_outputs(out_dir)
        # progress.json 里点名的产物优先（adapter 自己最清楚哪份是主音频）
        named_out = snap.get("output")
        named_score = snap.get("score")
        if isinstance(named_out, str) and os.path.exists(named_out):
            audio_paths = [named_out] + [p for p in audio_paths if p != named_out]
        if isinstance(named_score, str) and os.path.exists(named_score):
            score_paths = [named_score] + [p for p in score_paths if p != named_score]
        audio_paths = [p for p in audio_paths if os.path.getsize(p) > 1024]
        score_paths = [p for p in score_paths if os.path.getsize(p) > 0]
        if not audio_paths and not score_paths:
            return []

        title = job.get("title") or "未命名"
        primary = audio_paths[0] if audio_paths else None
        seconds = probe_duration(primary) if primary else None
        stem = safe_stem(title)
        suffix = ("-" + fmt_duration(seconds)) if seconds else ""
        base = stem + suffix

        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        dest = os.path.join(SONGS_DIR, "%s %s" % (stamp, stem))
        try:
            os.makedirs(dest, exist_ok=True)
        except OSError as ex:
            raise WriteError("建不了作品文件夹（%s）：%s" % (dest, ex))

        files = []

        def add(name, kind, path):
            files.append({"name": name, "kind": kind,
                          "size": os.path.getsize(path)})

        # 主音频
        if primary:
            ext = os.path.splitext(primary)[1].lower()
            name = base + ext
            target = os.path.join(dest, name)
            try:
                shutil.copy2(primary, target)
            except OSError as ex:
                raise WriteError("音频存不进去：%s" % ex)
            add(name, "audio", target)

            # mp3 试听 / 转发（微信、破电脑都能直接吃）
            if FFMPEG and ext != ".mp3":
                mp3 = os.path.join(dest, base + ".mp3")
                try:
                    subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-i", primary,
                                    "-codec:a", "libmp3lame", "-b:a", "192k",
                                    "-map_metadata", "-1", mp3],
                                   capture_output=True, timeout=300, check=True)
                    files.insert(0, {"name": os.path.basename(mp3), "kind": "preview",
                                     "size": os.path.getsize(mp3)})
                except Exception:
                    log("转 mp3 失败（不影响下载原文件）")

        # 其余音频（一般没有；有就一并带上）
        for extra in audio_paths[1:]:
            ext = os.path.splitext(extra)[1].lower()
            # adapter 常会顺手把成品转一份 mp3 放在 out/ 里；上面已经统一转过了，
            # 再收一遍会在手机上冒出两个一模一样的「下载」按钮（2026-11-17 实测 HeartMuLa）。
            if ext == ".mp3":
                continue
            name = base + "-" + safe_stem(os.path.splitext(os.path.basename(extra))[0], 20) + ext
            target = os.path.join(dest, name)
            try:
                shutil.copy2(extra, target)
                add(name, "audio", target)
            except Exception:
                pass

        # 谱子：yue2 那档才有，其余引擎这里一定是空的
        for i, sp in enumerate(score_paths):
            ext = os.path.splitext(sp)[1].lower()
            name = base + ("" if i == 0 else "-%d" % (i + 1)) + ext
            target = os.path.join(dest, name)
            try:
                shutil.copy2(sp, target)
                add(name, "score", target)
            except Exception:
                pass

        return files, seconds, dest

    def _cleanup_job_dir(self, job):
        """跑完把大文件清掉（成品已经并进作品库了），只留 params.json 便于复现。"""
        jid = job.get("id")
        if not jid:
            return
        out_dir = os.path.join(JOBS_DIR, jid, "out")
        if os.path.isdir(out_dir):
            shutil.rmtree(out_dir, ignore_errors=True)
        prog = os.path.join(JOBS_DIR, jid, "progress.json")
        if os.path.exists(prog):
            try:
                os.remove(prog)
            except Exception:
                pass


# ────────────────────────────── 网页与分享页 ──────────────────────────────

APP_PAGE = """<!DOCTYPE html>
<html lang="zh-CN"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>装到手机上 · MIR Remote</title>
<style>
  :root{{color-scheme:dark}}
  *{{box-sizing:border-box}}
  body{{margin:0;padding:22px 18px 40px;background:#0f1115;color:#e8eaef;
       font:17px/1.7 -apple-system,"PingFang SC",sans-serif;max-width:520px;margin:0 auto}}
  h1{{font-size:26px;margin:6px 0 6px}}
  .sub{{color:#8b93a5;font-size:15px;margin:0 0 20px}}
  .card{{background:#171a21;border:1px solid #242833;border-radius:18px;padding:18px;margin:16px 0}}
  a.btn{{display:block;text-align:center;text-decoration:none;background:#4ade80;color:#08130b;
        font-weight:700;font-size:20px;padding:18px;border-radius:16px;margin:6px 0}}
  .qr{{display:block;width:100%;max-width:320px;margin:10px auto;border-radius:12px;background:#fff;padding:10px}}
  .note{{color:#8b93a5;font-size:14px;margin-top:10px;line-height:1.65}}
  b{{color:#e8eaef}}
  code{{color:#4ade80;font-size:13px}}
</style></head>
<body>
  <h1>装到手机上</h1>
  <p class="sub">MIR Remote · 手机上的遥控镜子</p>

  <div class="card">
    <a class="btn" href="/app/mir-remote.apk">下载 MIR Remote</a>
    <div class="note">装的时候如果提示「未知来源」，选允许就行（自己做的，没上应用商店）。</div>
  </div>

  <div class="card">
    <div class="note" style="margin-top:0">用微信扫这个码，也能回到这一页：</div>
    <img class="qr" src="/app/qr.png" alt="下载二维码">
    <div class="note">如果在微信里点下载没反应：点右上角「…」→「在浏览器打开」，再点一次。</div>
  </div>

  <div class="card">
    <div class="note" style="margin-top:0">
      装好以后打开它，填一次 <b>6 位配对码</b>（就在电脑上 MIR Remote 的窗口里）。
      之后它会自己记住。<br><br>
      电脑得开着；在外面用的话，手机和电脑都要开着 Tailscale。
    </div>
  </div>
</body></html>
"""


SHARE_PAGE = """<!DOCTYPE html>
<html lang="zh-CN"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>__TITLE__ · MIR Remote</title>
<style>
  :root{{color-scheme:dark}}
  *{{box-sizing:border-box}}
  body{{margin:0;padding:20px 16px 40px;background:#0f1115;color:#e8eaef;
       font:17px/1.6 -apple-system,"PingFang SC",sans-serif}}
  .card{{max-width:520px;margin:0 auto;background:#171a21;border:1px solid #242833;
        border-radius:18px;padding:20px}}
  h1{{font-size:26px;margin:0 0 6px;line-height:1.3}}
  .meta{{color:#8b93a5;font-size:15px;margin-bottom:18px}}
  audio{{width:100%;margin:8px 0 18px}}
  a.btn{{display:block;text-align:center;text-decoration:none;background:#4ade80;color:#08130b;
        font-weight:600;font-size:18px;padding:16px;border-radius:14px;margin:10px 0}}
  a.ghost{{background:#232833;color:#e8eaef}}
  .grp{{font-size:14px;color:#8b93a5;letter-spacing:.08em;margin:20px 0 4px}}
  .note{{color:#8b93a5;font-size:14px;margin-top:14px;line-height:1.65}}
</style></head>
<body><div class="card">
  <h1>__TITLE__</h1>
  <div class="meta">__ENGINE__ · __DURATION__ · __CREATED__</div>
  __PLAYER__
  __DOWNLOADS__
  <div class="note">下载到手机后，用微信发出去就行。<br>
  在微信里点下载没反应的话：点右上角「…」→「在浏览器打开」。<br>
  链接只在家里 WiFi 或你自己的回家路上有用。</div>
</div></body></html>
"""


def build_share_page(song):
    sid = song["id"]
    files = song.get("files") or []
    preview = next((f for f in files if f.get("kind") == "preview"), None)
    audio = next((f for f in files if f.get("kind") == "audio"), None)
    scores = [f for f in files if f.get("kind") == "score"]
    play = preview or audio
    player = ""
    if play:
        player = '<audio controls preload="metadata" src="/s/%s/files/%s"></audio>' % (
            sid, quote_name(play["name"]))
    blocks = []

    def link(f, label, ghost):
        return '<a class="btn%s" href="/s/%s/files/%s?dl=1" download>%s</a>' % (
            " ghost" if ghost else "", sid, quote_name(f["name"]), label)

    # ── 歌：先给能直接听/转发的 mp3，再给要精修的原文件 ──
    if preview or audio:
        blocks.append('<div class="grp">歌</div>')
    if preview:
        blocks.append(link(preview, "下载歌（mp3 · %s）— 直接听、转发" % fmt_size(preview.get("size")),
                           False))
    if audio and (not preview or audio["name"] != preview.get("name")):
        ext = os.path.splitext(audio["name"])[1].lstrip(".").upper()
        blocks.append(link(audio, "下载原文件（%s · %s）— 要精修" % (ext, fmt_size(audio.get("size"))),
                           preview is not None))

    # ── 谱子：只有 YuE2 那档有，放同一页让人自己挑 ──
    if scores:
        blocks.append('<div class="grp">谱子</div>')
    for f in scores:
        ext = os.path.splitext(f["name"])[1].lstrip(".").upper()
        label = "下载谱（%s · %s）" % (ext, fmt_size(f.get("size")))
        if ext in ("XML", "MUSICXML"):
            label += " — 可进 Dorico"
        blocks.append(link(f, label, True))
    html = SHARE_PAGE
    html = html.replace("__TITLE__", html_escape(song.get("title") or "未命名"))
    html = html.replace("__ENGINE__", html_escape(song.get("engine_title") or song.get("engine") or ""))
    html = html.replace("__DURATION__", html_escape(fmt_duration(song.get("seconds")) or "—"))
    html = html.replace("__CREATED__", html_escape(song.get("created") or ""))
    html = html.replace("__PLAYER__", player)
    html = html.replace("__DOWNLOADS__", "\n  ".join(blocks))
    return html


def html_escape(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;"))


def quote_name(name):
    from urllib.parse import quote
    return quote(name, safe="")


# ────────────────────────────── HTTP ──────────────────────────────


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MIRRemote/1"

    store = None
    runner = None

    # 安静：默认实现每个请求就往 stderr 打一行
    def log_message(self, fmt, *args):
        pass

    # 2026-11-19 加的：手机说「连不上」时，要能分辨是「根本没连上来」
    # 还是「连上来又等不及走了」。答案就在 state/requests.log。
    def setup(self):
        BaseHTTPRequestHandler.setup(self)
        self._t0 = time.time()
        reqlog("CONN", self.client_address)

    def log_request(self, code="-", size="-"):
        reqlog("REQ", self.client_address,
               "%-40s %s %.2fs" % (self.path, code, time.time() - getattr(self, "_t0", time.time())))

    def handle_one_request(self):
        try:
            BaseHTTPRequestHandler.handle_one_request(self)
        except Exception as e:
            reqlog("ERR", self.client_address,
                   "%-40s %s: %s %.2fs" % (self.path, type(e).__name__, e,
                                           time.time() - getattr(self, "_t0", time.time())))
            raise

    # ---- 工具 ----
    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _error(self, code, message):
        self._json({"error": message, "message": message}, code)

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except Exception:
            n = 0
        if n <= 0:
            return {}
        raw = self.rfile.read(min(n, 2 * 1024 * 1024))
        try:
            obj = json.loads(raw.decode("utf-8"))
            return obj if isinstance(obj, dict) else {}
        except Exception:
            return {}

    def _authed(self):
        h = self.headers.get("Authorization") or ""
        if h.lower().startswith("bearer "):
            return self.store.check_token(h[7:].strip())
        # 网页 <audio>/<a download> 带不了 header —— 文件下载允许 ?token=
        from urllib.parse import parse_qs
        q = parse_qs(urlparse(self.path).query)
        return self.store.check_token((q.get("token") or [""])[0])

    # ---- GET ----
    def do_GET(self):
        path = unquote(urlparse(self.path).path)
        try:
            if path == "/healthz":
                return self._json({"ok": True, "jobs": len(self.store.jobs)})
            if path == "/v1/info":
                return self._json(self._info())
            if path == "/v1/score/options":
                if not self._authed():
                    return self._error(401, "先配对")
                return self._json(self._score_options())
            m = re.match(r"^/v1/score/jobs/([A-Za-z0-9]+)$", path)
            if m:
                if not self._authed():
                    return self._error(401, "先配对")
                return self._json(self._score_status(m.group(1)))
            if path == "/v1/songs":
                if not self._authed():
                    return self._error(401, "先配对")
                # dir 是本机路径，只服务端自己用（分享页也不显示）
                return self._json({"songs": [{k: v for k, v in s.items() if k != "dir"}
                                             for s in self.store.songs]})
            m = re.match(r"^/v1/jobs/([A-Za-z0-9]+)$", path)
            if m:
                if not self._authed():
                    return self._error(401, "先配对")
                j = self.store.job(m.group(1))
                if not j:
                    return self._error(404, "没有这个任务")
                return self._json(public_job(j))
            m = re.match(r"^/v1/jobs/([A-Za-z0-9]+)/files/(.+)$", path)
            if m:
                if not self._authed():
                    return self._error(401, "先配对")
                return self._send_song_file(m.group(1), m.group(2))
            m = re.match(r"^/s/([A-Za-z0-9]+)$", path)
            if m:
                song = self.store.song(m.group(1))
                if not song:
                    return self._error(404, "这首不在了")
                body = build_share_page(song).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                return self.wfile.write(body)
            m = re.match(r"^/s/([A-Za-z0-9]+)/files/(.+)$", path)
            if m:
                return self._send_song_file(m.group(1), m.group(2))
            if path == "/app":
                body = APP_PAGE.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                return self.wfile.write(body)
            if path == "/app/qr.png":
                return self._static(os.path.join(WEB_DIR, "app-qr.png"))
            if path == "/app/mir-remote.apk":
                if not os.path.exists(APK_PATH):
                    return self._error(404, "安装包还没打出来（tools/build.sh）")
                return self._send_file(APK_PATH, "MIR Remote.apk", as_attachment=True)
            if path in ("/", "/index.html"):
                return self._static(os.path.join(WEB_DIR, "index.html"))
            if path.startswith("/web/"):
                return self._static(os.path.join(WEB_DIR, os.path.basename(path)))
            return self._error(404, "没有这个地方")
        except BrokenPipeError:
            pass
        except Exception:
            log("GET %s 出错：\n%s" % (path, traceback.format_exc()))
            try:
                self._error(500, "服务这边出了点问题")
            except Exception:
                pass

    # ---- POST ----
    def do_POST(self):
        path = unquote(urlparse(self.path).path)
        try:
            if path == "/v1/pair":
                return self._pair()
            if path == "/v1/jobs":
                if not self._authed():
                    return self._error(401, "先配对")
                return self._create_job()
            if path == "/v1/score/jobs":
                if not self._authed():
                    return self._error(401, "先配对")
                return self._score_create()
            m = re.match(r"^/v1/jobs/([A-Za-z0-9]+)/cancel$", path)
            if m:
                if not self._authed():
                    return self._error(401, "先配对")
                j = self.store.job(m.group(1))
                if not j:
                    return self._error(404, "没有这个任务")
                j["cancel_requested"] = True
                self.store.save_job(j)
                self.runner.cancel(j["id"])
                return self._json({"ok": True})
            return self._error(404, "没有这个地方")
        except BrokenPipeError:
            pass
        except Exception:
            log("POST %s 出错：\n%s" % (path, traceback.format_exc()))
            try:
                self._error(500, "服务这边出了点问题")
            except Exception:
                pass

    # ---- 接口实现 ----
    def _score_options(self):
        """把曲谱工作台的「时期 / 作曲家 / 编制」名单原样转给手机。"""
        try:
            d = notagen_call("/api/options", timeout=8)
        except Exception:
            return {"ready": False, "combos": [], "reason": "曲谱工作台没开着"}
        combos = d.get("combos") or []
        return {"ready": True, "combos": combos}

    def _score_create(self):
        body = self._body()
        period = str(body.get("period") or "").strip()
        composer = str(body.get("composer") or "").strip()
        instrument = str(body.get("instrument") or "").strip()
        if not (period and composer and instrument):
            return self._error(400, "时期、作曲家、编制三样都要选")
        try:
            d = notagen_call("/api/generate", {"period": period, "composer": composer,
                                               "instrumentation": instrument}, timeout=30)
        except urllib.error.HTTPError as ex:
            try:
                msg = json.loads(ex.read().decode("utf-8")).get("detail") or "这个组合它不写"
            except Exception:
                msg = "这个组合它不写"
            return self._error(400, msg)
        except Exception:
            return self._error(409, "曲谱工作台没开着（先在那台电脑上打开它）")
        sid = secrets.token_hex(4)
        with SCORE_LOCK:
            SCORE_TASKS[sid] = {
                "id": sid, "tid": d.get("task_id"), "period": period,
                "composer": composer, "instrument": instrument,
                "store": self.store, "created": now_ts(),
            }
        log("排上一份乐谱：%s（%s / %s / %s）" % (sid, period, composer, instrument))
        return self._json({"id": sid}), 201

    def _score_status(self, sid):
        task = SCORE_TASKS.get(sid)
        if not task:
            return self._error(404, "没有这份乐谱")
        try:
            st = notagen_call("/api/task/" + str(task["tid"]), timeout=8)
        except Exception:
            return self._error(409, "曲谱工作台断了（它还在跑吗？）")
        status = st.get("status")
        if status == "done":
            archive_score(task, st)
        out = {
            "id": sid,
            "state": {"queued": "queued", "running": "running", "done": "done"}.get(status, "failed"),
            "percent": score_percent(st),
            "chars": st.get("chars_now") or st.get("chars") or 0,
            "elapsed": st.get("elapsed") or 0,
            "title": score_title(task),
            "message": {"queued": "排上了，马上开始",
                        "running": "正在写谱子…",
                        "done": "谱子写好了"}.get(status, "这一趟没成"),
        }
        if status == "error":
            out["detail"] = st.get("error") or ""
        if status == "done":
            if task.get("archived"):
                out["share_id"] = task["id"]
                out["files"] = [{"name": f["name"], "kind": "score", "size": f["size"],
                                 "url": "/s/%s/files/%s?dl=1" % (task["id"], quote_name(f["name"]))}
                                for f in (self.store.song(task["id"]) or {}).get("files", [])]
            elif task.get("archive_error"):
                out["detail"] = task["archive_error"]
            out["preview"] = st.get("preview") or ""
        return out

    def _info(self):
        engines = []
        for e in ENGINES:
            ok, missing = engine_available(e)
            engines.append({
                "id": e["id"],
                "title": e["title"],
                "hint": e["hint"],
                "eta_hint": e.get("eta_hint") or "",
                "local": True,
                "available": ok,
                "reason": "" if ok else "缺 %s" % "、".join(os.path.basename(p) for p in missing),
                "outputs": e["outputs"],
                "params": {
                    "lyrics": {"type": "text"} if e["lyrics"] else None,
                    "style": {"type": e["style"], "presets": e.get("presets") or []},
                    "steps": {"options": e["steps"]} if e.get("steps") else None,
                    "duration": e.get("duration"),
                },
            })
        return {
            "v": PROTOCOL_VERSION,
            "name": "MIR Remote 后端",
            "platform": "macos",
            "version": "1.0",
            "engines": engines,
            "limits": {"one_at_a_time": True, "max_queue": 4},
            "songs_dir_ready": os.path.isdir(SONGS_DIR),
        }

    def _pair(self):
        body = self._body()
        code = str(body.get("code") or "").strip()
        if not self._rate_ok():
            return self._error(429, "试太多次了，等一分钟")
        if not (len(code) == 6 and secrets.compare_digest(code, self.store.pair_code)):
            return self._error(403, "配对码不对，再看一下屏幕上或文件里的那 6 位")
        token = self.store.issue_token(body.get("name") or "手机")
        log("配对成功：%s" % (body.get("name") or "手机"))
        return self._json({"token": token})

    _ip_hits = {}

    def _rate_ok(self):
        """配对码只有 6 位，得挡住猜。每 IP 每分钟 8 次。"""
        ip = self.client_address[0]
        now = time.time()
        hits = [t for t in Handler._ip_hits.get(ip, []) if now - t < 60]
        if len(hits) >= 8:
            return False
        hits.append(now)
        Handler._ip_hits[ip] = hits
        return True

    def _create_job(self):
        body = self._body()
        engine_id = str(body.get("engine") or "")
        e = ENGINE_BY_ID.get(engine_id)
        if not e:
            return self._error(400, "没有这台引擎")
        ok, missing = engine_available(e)
        if not ok:
            return self._error(409, "这台引擎还没准备好")
        if not os.path.isdir(SONGS_DIR):
            return self._error(409, "外盘没插（作品要存到外盘）")
        if not os.access(SONGS_DIR, os.W_OK):
            return self._error(409, "作品文件夹写不进去，检查一下外盘")

        lyrics = str(body.get("lyrics") or "").strip()[:6000]
        style = str(body.get("style") or "").strip()[:1000]
        if not e["lyrics"]:
            lyrics = "[Instrumental]"
        if not lyrics:
            lyrics = "[Instrumental]"
        if not style and not e["lyrics"]:
            return self._error(400, "写一句风格吧（纯音乐没有词，全靠它）")

        steps = body.get("steps")
        if e.get("steps"):
            try:
                steps = int(steps)
            except Exception:
                steps = e["steps"][0]
            if steps not in e["steps"]:
                steps = e["steps"][0]
        else:
            steps = None

        duration = None
        if e.get("duration"):
            try:
                duration = float(body.get("duration"))
            except Exception:
                duration = float(e["duration"]["default"])
            duration = max(e["duration"]["min"], min(e["duration"]["max"], duration))

        title = str(body.get("title") or "").strip()
        if not title:
            if lyrics and lyrics != "[Instrumental]":
                title = lyrics.splitlines()[0][:12]
            else:
                title = style[:12]
        title = safe_stem(title)

        jid = secrets.token_hex(4)
        job = {
            "id": jid,
            "engine": e["id"],
            "title": title,
            "lyrics": lyrics,
            "style": style,
            "steps": steps,
            "duration": duration,
            "seed": secrets.randbelow(2 ** 31 - 1),
            "state": "queued",
            "percent": 0,
            "message": "排上了，马上开始",
            "created": now_ts(),
            "created_text": fmt_time(now_ts()),
        }
        self.store.save_job(job)
        try:
            self.runner.enqueue(job)
        except RuntimeError as ex:
            self.store.jobs.pop(jid, None)
            return self._error(429, str(ex))
        log("排上一首：%s（%s）" % (title, e["title"]))
        return self._json({"id": jid, "job": public_job(job)}, 201)

    # ---- 文件 ----
    def _send_song_file(self, sid, name):
        song = self.store.song(sid)
        if not song:
            return self._error(404, "这首不在了")
        if not any(f.get("name") == name for f in (song.get("files") or [])):
            return self._error(404, "没有这个文件")
        folder = song.get("dir")
        if not folder or not os.path.isdir(folder):
            return self._error(404, "这一首的文件夹不在了（外盘插着吗？）")
        full = os.path.realpath(os.path.join(folder, name))
        if not full.startswith(os.path.realpath(folder) + os.sep):
            return self._error(403, "不行")
        if not os.path.exists(full):
            return self._error(404, "文件不在了")
        # ?dl=1 才用 attachment：手机浏览器/WebView 见到 inline 的 audio/mpeg
        # 容易"打开播放"而不是下载，安卓 WebView 那边干脆报下载失败。
        want_dl = "dl=1" in (urlparse(self.path).query or "")
        self._send_file(full, name, as_attachment=want_dl)

    def _send_file(self, path, name, as_attachment=False):
        """支持 Range —— iOS 的 <audio> 不会播一个不支持 Range 的链接。"""
        size = os.path.getsize(path)
        ctype = guess_mime(name)
        start, end = 0, size - 1
        rng = (self.headers.get("Range") or "").strip()
        partial = False
        if rng.startswith("bytes=") and size > 0:
            spec = rng[6:].split(",")[0].strip()
            a, _, b = spec.partition("-")
            try:
                if a:
                    start = int(a)
                if b:
                    end = int(b)
            except ValueError:
                start, end = 0, size - 1
            if not a:
                # "bytes=-500" = 最后 500 字节
                start = max(0, size - (int(b) if b.isdigit() else size))
                end = size - 1
            if start > end or start >= size:
                self.send_response(416)
                self.send_header("Content-Range", "bytes */%d" % size)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            end = min(end, size - 1)
            partial = True

        length = end - start + 1
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if partial:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        try:
            from urllib.parse import quote
            disp = "attachment" if as_attachment else "inline"
            self.send_header("Content-Disposition",
                             disp + "; filename*=UTF-8''" + quote(name, safe=""))
        except Exception:
            pass
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk = f.read(min(256 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def _static(self, path):
        if not os.path.exists(path):
            return self._error(404, "页面文件不在了")
        with open(path, "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Type", guess_mime(path))
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)


def public_job(job):
    """给网页看的那一份。本机路径、pid、日志一律不出去。"""
    out = {}
    for k in ("id", "engine", "title", "state", "percent", "message", "detail",
              "eta_seconds", "created", "created_text", "finished", "seconds",
              "outputs", "song_id", "steps", "duration"):
        if k in job:
            out[k] = job[k]
    if out.get("outputs"):
        out["outputs"] = [{"name": f["name"], "kind": f["kind"], "size": f["size"],
                           "url": "/s/%s/files/%s?dl=1" % (job["id"], quote_name(f["name"]))}
                          for f in out["outputs"]]
    return out


# ────────────────────────────── 启动 ──────────────────────────────


def local_ips():
    ips = []
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None):
            ip = info[4][0]
            if ":" in ip or ip.startswith("127."):
                continue
            if ip not in ips:
                ips.append(ip)
    except Exception:
        pass
    # 兜底：直接问一个外网地址（不会真的发数据）
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("192.168.31.1", 80))
        ip = s.getsockname()[0]
        s.close()
        if ip not in ips and not ip.startswith("127."):
            ips.append(ip)
    except Exception:
        pass
    return ips


def cleanup_stale_job_dirs(max_age_days=3):
    """失败/取消的任务，成品目录留着方便人去看；但别一直堆着。清掉三天前的。"""
    cutoff = time.time() - max_age_days * 86400
    for name in os.listdir(JOBS_DIR):
        full = os.path.join(JOBS_DIR, name)
        if not os.path.isdir(full):
            continue
        job_file = os.path.join(JOBS_DIR, name + ".json")
        j = read_json(job_file, {}) or {}
        if j.get("state") in ("queued", "running", "waiting"):
            continue
        try:
            if os.path.getmtime(full) < cutoff:
                shutil.rmtree(full, ignore_errors=True)
        except OSError:
            pass


def main():
    os.makedirs(STATE, exist_ok=True)
    os.makedirs(JOBS_DIR, exist_ok=True)
    try:
        open(REQ_LOG, "w").close()   # 每次启动重开，日志别越滚越大
    except Exception:
        pass
    try:
        cleanup_stale_job_dirs()
    except Exception:
        pass

    store = Store()
    runner = Runner(store)
    runner.start()

    Handler.store = store
    Handler.runner = runner

    if not os.path.isdir(SONGS_DIR):
        log("⚠️ 外盘没插：%s 不在了。作品存不进去，出歌会被拒。" % SONGS_DIR)

    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    httpd.daemon_threads = True

    ips = local_ips()
    base = ("http://%s:%d" % (ips[0], PORT)) if ips else "http://127.0.0.1:%d" % PORT
    log("MIR Remote 已开：%s" % base)
    for ip in ips[1:]:
        log("  也可用：http://%s:%d" % (ip, PORT))
    log("配对码：%s（第一次打开网页要填一次；文件在 %s）" % (
        store.pair_code, os.path.join(STATE, "pair_code.txt")))
    log("作品存到：%s" % SONGS_DIR)
    print("\n  手机连同一个 WiFi，打开上面那个地址就行。\n", flush=True)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("收工")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
