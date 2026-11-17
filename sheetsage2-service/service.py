#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SheetSage2 semantic service -- fixed port 8001, localhost only.

Copyright (c) 2026 Jie Da / Inspiration-Assistant
SheetSage2 x YuE2 Integration - local, non-commercial research use only.
Weights: SheetSage2 / YuE2 / MERT-v2 (CC BY-NC 4.0, m-a-p). No cloud upload.

WHY THIS SHAPE
--------------
The real SheetSage2 checkpoint is an *audio -> lead-sheet* model.  It has no
MusicXML reader and cannot repair ABC.  Flow-B therefore runs on a
deterministic, standard-library score reader (ss2core) that only recognises
what a human wrote.  The audio encoder stays behind a lazy, one-shot child
process and is never resident while the service is idle.

Routes
------
GET  /health          -> friendly + machine status (no traceback)
POST /analyze_score   -> Flow A/B/C score semantics (fast, no model)
POST /transcribe      -> Flow-C audio -> ABC (lazy child process, needs weights)
POST /unload_audio    -> report/force audio-encoder release
"""

from __future__ import annotations

import base64
import json
import logging
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import traceback
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import ss2core as core  # noqa: E402

# ★ 2026-11-15：launchd 拉起来的进程只有 /usr/bin:/bin:/usr/sbin:/sbin，
#   看不到 Homebrew 的 ffmpeg —— 表现是能转谱的文件也报
#   "ffmpeg is required to decode audio."（创作台第一次接就撞上）。
#   给 PATH 补上常见安装位置；转谱的子进程（yue2 transcribe）也吃这个 PATH。
for _extra in ("/opt/homebrew/bin", "/usr/local/bin"):
    if os.path.isdir(_extra) and _extra not in os.environ.get("PATH", "").split(":"):
        os.environ["PATH"] = (os.environ.get("PATH") or "/usr/bin:/bin") + ":" + _extra

SERVICE_NAME = "sheetsage2-semantic"
VERSION = core.SERVICE_VERSION
BAR_LIMIT = core.BAR_GUARD_LIMIT

BASE = Path(os.environ.get("SS2_BASE", str(Path.home() / "inspiration-assistant"))).expanduser()
CACHE = Path(os.environ.get("SS2_CACHE", str(BASE / "abc-cache"))).expanduser()
LOGS = Path(os.environ.get("SS2_LOGS", str(BASE / "logs"))).expanduser()
MODELS = Path(os.environ.get("SS2_MODELS", str(BASE / "models"))).expanduser()
PORT = int(os.environ.get("SS2_PORT", "8001"))
BIND = os.environ.get("SS2_BIND", "127.0.0.1")
MAX_BODY = 32 * 1024 * 1024
STARTED = time.time()

for directory in (CACHE, LOGS):
    directory.mkdir(parents=True, exist_ok=True)


def _find_yue2() -> Path | None:
    candidates = []
    if os.environ.get("SS2_YUE2_BIN"):
        candidates.append(Path(os.environ["SS2_YUE2_BIN"]))
    if os.environ.get("SS2_WORKSPACE"):
        candidates.append(Path(os.environ["SS2_WORKSPACE"]) / "yue2-local" / "yue2")
    candidates += [
        Path.home() / "Documents/deepseek-harness/default-workspace/yue2-local/yue2",
        HERE.parents[1] / "yue2-local" / "yue2" if len(HERE.parents) > 1 else None,
    ]
    for candidate in candidates:
        if candidate and candidate.exists():
            return candidate
    return None


YUE2_BIN = _find_yue2()


def _find_audiocpp() -> Path | None:
    """audio.cpp 的 Mac 预编译版（2026-10-24 起用它转谱，不再依赖 HF 权重）。"""
    candidates = []
    if os.environ.get("SS2_AUDIOCPP_CLI"):
        candidates.append(Path(os.environ["SS2_AUDIOCPP_CLI"]))
    workspace = Path(os.environ.get(
        "SS2_WORKSPACE",
        str(Path.home() / "Documents/deepseek-harness/default-workspace")))
    candidates.append(workspace / "audiocpp-bin" / "audiocpp_cli")
    for candidate in candidates:
        if candidate and candidate.exists():
            return candidate
    return None


def _find_sheetsage2_gguf() -> Path | None:
    candidates = []
    if os.environ.get("SS2_SHEETSAGE2_GGUF"):
        candidates.append(Path(os.environ["SS2_SHEETSAGE2_GGUF"]))
    workspace = Path(os.environ.get(
        "SS2_WORKSPACE",
        str(Path.home() / "Documents/deepseek-harness/default-workspace")))
    candidates.append(workspace / "audio.cpp" / "models" / "SheetSage2" / "sheetsage2-orig.gguf")
    for candidate in candidates:
        if candidate and candidate.exists():
            return candidate
    return None


AUDIOCPP_CLI = _find_audiocpp()
SHEETSAGE2_GGUF = _find_sheetsage2_gguf()


class ApiError(Exception):
    def __init__(self, code: str, human: str, http: int = 400):
        super().__init__(human)
        self.code = code
        self.human = human
        self.http = http


# --------------------------------------------------------------------------
# logging: JSON lines, no tracebacks in HTTP responses
# --------------------------------------------------------------------------

LOGGER = logging.getLogger(SERVICE_NAME)
LOGGER.setLevel(logging.INFO)
_handler = logging.FileHandler(LOGS / "service.log", encoding="utf-8")
_handler.setFormatter(logging.Formatter("%(message)s"))
LOGGER.addHandler(_handler)


def log_event(**fields) -> None:
    fields.setdefault("ts", datetime.now(timezone.utc).isoformat())
    try:
        LOGGER.info(json.dumps(fields, ensure_ascii=False))
    except Exception:
        pass


# --------------------------------------------------------------------------
# memory + model presence (lazy-load bookkeeping lives here)
# --------------------------------------------------------------------------

def rss_mb() -> float:
    try:
        import resource
        value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        # macOS reports bytes, Linux kilobytes
        return round(value / (1024 * 1024), 1) if sys.platform == "darwin" else round(value / 1024, 1)
    except Exception:
        return -1.0


def hf_model_present(name: str) -> bool:
    """Look for a Hugging Face cache snapshot without importing anything."""
    candidates = [
        MODELS / "hf-cache" / ("models--" + name.replace("/", "--")),
        HERE.parents[1] / "yue2-local/mlx-Yue/models/hf-cache" / ("models--" + name.replace("/", "--"))
        if len(HERE.parents) > 1 else None,
    ]
    for candidate in candidates:
        if candidate and candidate.exists():
            snapshots = list(candidate.glob("snapshots/*"))
            if any(any(s.iterdir()) for s in snapshots if s.is_dir()):
                return True
    return False


_audio_state = {
    "state": "unloaded",     # unloaded | running | failed
    "job": None,
    "last_error": None,
    "last_finished": None,
}
_audio_lock = threading.Lock()


def audio_encoder_status() -> dict:
    return {
        "state": _audio_state["state"],
        "resident_in_service": False,
        "note": "audio encoder runs in a one-shot child process (Flow-C only)",
        "job": _audio_state["job"],
        "last_error": _audio_state["last_error"],
        "last_finished": _audio_state["last_finished"],
    }


# --------------------------------------------------------------------------
# artefact writing
# --------------------------------------------------------------------------

def _write(path: Path, text: str) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def persist_result(result: dict, flow: str) -> dict:
    run_id = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
    run_dir = CACHE / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    outputs = result.get("outputs", {})
    artifacts = {}
    if "repaired_abc" in outputs:
        path = run_dir / "repaired.abc"
        _write(path, outputs["repaired_abc"])
        artifacts["repaired_abc"] = str(path)
    if "melody_abc" in outputs:
        path = run_dir / "melody.abc"
        _write(path, outputs["melody_abc"])
        artifacts["melody_abc"] = str(path)
    if "structured_condition_json" in outputs:
        path = run_dir / "condition.json"
        _write(path, json.dumps(outputs["structured_condition_json"],
                                ensure_ascii=False, indent=2) + "\n")
        artifacts["condition_json"] = str(path)
    manifest = core.stamp_json({
        "run_id": run_id,
        "flow": flow,
        "created": datetime.now(timezone.utc).isoformat(),
        "artifacts": artifacts,
        "guarantees": result.get("guarantees", {}),
        "bar_count": result.get("bar_count"),
    })
    path = run_dir / "manifest.json"
    _write(path, json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    artifacts["manifest"] = str(path)
    result["artifacts"] = artifacts
    result["run_id"] = run_id
    return result


# --------------------------------------------------------------------------
# payload handling
# --------------------------------------------------------------------------

def _local_path(raw: str, label: str) -> Path:
    """Resolve a path that the launchd service is allowed to read.

    macOS TCC blocks a background launchd job from reading ~/Documents
    (measured 2026-10-24: a 24 KB request stalled for 177 s).  The app must
    therefore hand files over as base64, or stage them inside
    ~/inspiration-assistant first.  Rejecting early is kinder than hanging.
    """
    p = Path(raw).expanduser()
    try:
        resolved = p.resolve()
    except Exception:
        raise ApiError("bad_path", "That path could not be resolved.")
    base = BASE.resolve()
    inside = resolved == base or str(resolved).startswith(str(base) + os.sep)
    if not inside and not os.environ.get("SS2_ALLOW_EXTERNAL_PATHS"):
        raise ApiError(
            "path_outside_base",
            "Send the %s as base64, or copy it into ~/inspiration-assistant first "
            "(the background service cannot read protected folders)." % label)
    if not resolved.is_file():
        raise ApiError("missing_file", "I could not find that %s file." % label)
    return resolved


def read_score_payload(payload: dict) -> tuple[bytes | None, str, str | None]:
    """Return (musicxml_bytes, abc_text, vocal_part) from a request payload."""
    musicxml = None
    abc = payload.get("abc_text") or ""
    path = payload.get("musicxml_path")
    b64 = payload.get("musicxml_base64")
    if b64:
        try:
            musicxml = base64.b64decode(b64, validate=True)
        except Exception:
            raise ApiError("bad_base64", "The score upload was not valid base64.")
    elif path:
        p = _local_path(path, "score")
        if p.stat().st_size > MAX_BODY:
            raise ApiError("score_too_large", "That score file is too large.", 413)
        musicxml = p.read_bytes()
    if musicxml is not None:
        if not musicxml.lstrip().startswith(b"<"):
            raise ApiError("not_xml", "That file does not look like MusicXML.")
        if b"score-timewise" in musicxml[:4000]:
            raise ApiError("timewise_score",
                           "This is a timewise score; please export partwise MusicXML.")
    if not abc and payload.get("abc_path"):
        abc = _local_path(payload["abc_path"], "ABC").read_text(encoding="utf-8")
    if not abc and musicxml is None:
        raise ApiError("empty_request", "Send musicxml/base64 and/or abc text.")
    if len(abc) > 2 * 1024 * 1024:
        raise ApiError("abc_too_long", "That ABC is too long for the editor.", 413)
    return musicxml, abc, payload.get("vocal_part")


def analyze(flow: str, payload: dict) -> dict:
    musicxml, abc, vocal_part = read_score_payload(payload)

    if flow == "B":
        if musicxml is None:
            raise ApiError("flow_b_needs_musicxml",
                           "Flow-B reads the human score first; send the MusicXML.")
        if not abc:
            # No ABC supplied: derive one from the score is outside this
            # service's contract (xml2abc lives in the UI layer).  Return the
            # condition JSON only and say so plainly.
            doc = core.parse_musicxml(musicxml, source_sha256=core.sha256_bytes(musicxml),
                                      vocal_part=vocal_part)
            core.bar_guard(doc.bar_count)
            result = core.stamp_json({
                "flow": "B",
                "status": "condition_only",
                "bar_count": doc.bar_count,
                "outputs": {"structured_condition_json": doc.to_condition_json()},
                "diagnostics": {"warnings": doc.diagnostics},
                "guarantees": {"chords_verbatim": True, "notes_injected": 0,
                               "ai_chord_inference": False, "abc_repaired": False},
            })
        else:
            result = core.analyze_flow_b(musicxml, abc, vocal_part)
    elif flow == "A":
        result = core.analyze_flow_a(abc, musicxml)
    elif flow == "C":
        result = core.analyze_flow_c(abc, payload.get("source_audio_sha256", ""))
    else:
        raise ApiError("bad_flow", "Flow must be A, B or C.")

    bar_count = result.get("bar_count", 0)
    if bar_count and bar_count > LIMIT_MSG_BARS:
        raise ApiError("too_many_bars",
                       "This score has %d bars; the guard is %d. Split it first."
                       % (bar_count, LIMIT_MSG_BARS), 413)
    result = persist_result(result, flow)
    return result


LIMIT_MSG_BARS = BAR_LIMIT


# --------------------------------------------------------------------------
# Flow-C: run the audio encoder in a one-shot child process
# --------------------------------------------------------------------------

def transcribe(payload: dict) -> dict:
    if YUE2_BIN is None:
        raise ApiError("yue2_missing", "The YuE2/SheetSage2 runtime is not installed.", 501)
    audio = payload.get("audio_path")
    if not audio:
        raise ApiError("missing_audio", "Choose a reference audio file first.")
    audio_path = _local_path(audio, "audio")
    if not hf_model_present("m-a-p/SheetSage2") or not hf_model_present("m-a-p/MERT-v2-FullSong"):
        raise ApiError(
            "weights_missing",
            "The audio-transcription weights are not installed yet. "
            "Flow-A and Flow-B still work; run fetch_weights.sh to enable audio cover.",
            501)
    if not shutil.which("ffmpeg"):
        raise ApiError("ffmpeg_missing", "ffmpeg is required to decode audio.", 501)

    task = payload.get("task", "melody-full")
    if task not in ("full", "melody-full", "melody-vocal"):
        raise ApiError("bad_task", "task must be full, melody-full or melody-vocal.")

    with _audio_lock:
        if _audio_state["state"] == "running":
            raise ApiError("busy", "Audio transcription is already running.", 409)
        run_id = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
        out_dir = CACHE / ("transcribe-" + run_id)
        command = [str(YUE2_BIN), "transcribe", str(audio_path),
                   "--output", str(out_dir),
                   "--model", "m-a-p/SheetSage2",
                   "--base-model", "m-a-p/MERT-v2-FullSong",
                   "--cache-dir", str(MODELS / "hf-cache"),
                   "--task", task, "--offline", "--quiet"]
        _audio_state.update(state="running", job=out_dir.name, last_error=None)
        log_event(event="transcribe_start", command=" ".join(command))
        started = time.time()
        try:
            proc = subprocess.run(command, capture_output=True, text=True, timeout=3600)
        except subprocess.TimeoutExpired:
            _audio_state.update(state="failed", last_error="timeout")
            raise ApiError("transcribe_timeout", "Audio transcription timed out.", 504)
        finally:
            pass

        score_path = out_dir / "score.abc"
        if proc.returncode != 0 or not score_path.is_file():
            message = (proc.stderr or "").strip().splitlines()
            tail = message[-1] if message else "no detail"
            _audio_state.update(state="failed", last_error=tail,
                                last_finished=datetime.now(timezone.utc).isoformat())
            log_event(event="transcribe_failed", rc=proc.returncode, tail=tail,
                      seconds=round(time.time() - started, 1))
            # the child is gone: the encoder memory is already released
            _audio_state["state"] = "failed"
            raise ApiError("transcribe_failed",
                           "The audio transcriber could not finish this file.", 502)

        abc = score_path.read_text(encoding="utf-8")
        _audio_state.update(state="unloaded", last_finished=datetime.now(timezone.utc).isoformat())
        log_event(event="transcribe_ok", seconds=round(time.time() - started, 1),
                  out=str(out_dir))
    result = core.analyze_flow_c(abc, payload.get("source_audio_sha256", ""))
    result["transcription"] = {"output_dir": str(out_dir), "task": task,
                               "audio_encoder": audio_encoder_status()}
    result = persist_result(result, "C")
    return result


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "SheetSage2Semantic/" + VERSION
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        # keep stderr quiet; structured log is written by log_event
        return

    def _send(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        if length > MAX_BODY:
            raise ApiError("body_too_large", "Request body is too large.", 413)
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except Exception:
            raise ApiError("bad_json", "Request body must be JSON.")
        if not isinstance(data, dict):
            raise ApiError("bad_json", "Request body must be a JSON object.")
        return data

    def _handle(self, action) -> None:
        started = time.time()
        route = self.path.split("?")[0]
        try:
            payload = self._read_json() if self.command == "POST" else {}
            result = action(payload)
            self._send(200, result)
            log_event(event="request", route=route, ok=True,
                      ms=round((time.time() - started) * 1000, 1))
        except ApiError as error:
            self._send(error.http, {
                "ok": False,
                "error": {"code": error.code, "human": error.human},
                "status_text": error.human,
            })
            log_event(event="request", route=route, ok=False, code=error.code,
                      ms=round((time.time() - started) * 1000, 1))
        except ValueError as error:
            human = str(error)
            self._send(413 if "guard" in human else 422, {
                "ok": False,
                "error": {"code": "invalid_score", "human": human},
                "status_text": human,
            })
            log_event(event="request", route=route, ok=False, code="invalid_score")
        except Exception:
            log_event(event="crash", route=route, trace=traceback.format_exc())
            self._send(500, {
                "ok": False,
                "error": {"code": "internal", "human": "Something went wrong while reading the score."},
                "status_text": "Processing failed",
            })

    def do_GET(self):
        if self.path.split("?")[0] == "/health":
            self._send(200, health())
        elif self.path.split("?")[0] == "/":
            self._send(200, {"service": SERVICE_NAME, "version": VERSION,
                             "routes": ["/health", "/analyze_score", "/transcribe"]})
        else:
            self._send(404, {"ok": False, "error": {"code": "not_found", "human": "No such route."}})

    def do_POST(self):
        route = self.path.split("?")[0]
        if route == "/analyze_score":
            def action(payload):
                return analyze(payload.get("flow", "B"), payload)
            self._handle(action)
        elif route == "/transcribe":
            self._handle(transcribe)
        elif route == "/unload_audio":
            with _audio_lock:
                _audio_state.update(state="unloaded", job=None)
            self._send(200, {"ok": True, "audio_encoder": audio_encoder_status()})
        else:
            self._send(404, {"ok": False, "error": {"code": "not_found", "human": "No such route."}})


def health() -> dict:
    models = {
        "sheetsage2": hf_model_present("m-a-p/SheetSage2"),
        "mert2_fullsong": hf_model_present("m-a-p/MERT-v2-FullSong"),
    }
    score_ready = True  # deterministic score reader is always available
    return {
        "status": "ok",
        "service": SERVICE_NAME,
        "version": VERSION,
        "port": PORT,
        "bind": BIND,
        "mode": "score_only" if not any(models.values()) else "score+audio_ready",
        "score_reader": "ready" if score_ready else "unavailable",
        "audio_encoder": audio_encoder_status(),
        "models_present": models,
        "runtime": {"yue2_bin": str(YUE2_BIN) if YUE2_BIN else None,
                    "python": sys.version.split()[0]},
        "memory": {"rss_peak_mb": rss_mb(),
                   "idle_target_mb": 1500},
        "guards": {"bar_limit": BAR_LIMIT, "body_limit_mb": MAX_BODY // (1024 * 1024)},
        "cache_dir": str(CACHE),
        "models_dir": str(MODELS),
        "uptime_s": round(time.time() - STARTED, 1),
        "human_status": "Ready (score only)" if not any(models.values()) else "Ready",
    }


def main() -> int:
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    server.daemon_threads = True
    log_event(event="start", port=PORT, bind=BIND, pid=os.getpid(),
              cache=str(CACHE), models=str(MODELS))
    print(json.dumps({"service": SERVICE_NAME, "port": PORT, "bind": BIND,
                      "cache": str(CACHE)}, ensure_ascii=False), flush=True)

    def stop(signum, frame):
        log_event(event="stop", signal=signum)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        server.serve_forever(poll_interval=0.3)
    finally:
        server.server_close()
        log_event(event="exit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
