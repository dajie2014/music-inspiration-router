#!/usr/bin/env python3
"""ACE-Step 1.5 XL Turbo（本机 mlx-serve）出歌 —— 给 ace_mlx_adapter.sh 用。

契约与 MIR 里另外几台一致：读 params.json，写 progress.json，把 wav 摆进
--out-dir。只多做一件：progress 里带上 output（音频绝对路径），界面靠它把
这一首接进列表。

退出码：0 成功 / 2 参数错 / 5 生成失败 / 6 超时 / 7 环境不对
"""
import argparse
import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

ENDPOINT = "http://127.0.0.1:11234/v1/audio/music-generations"
MODEL = "ACE-Step-1.5-XL-Turbo-MLX-Serve-8bit"
MIN_SEC, MAX_SEC = 10, 600


def write_progress(path, percent, state, message, detail="", output=None):
    payload = {
        "percent": int(max(0, min(100, percent))),
        "state": state,
        "message": message,
        "detail": detail,
        "updated": int(time.time()),
    }
    if output:
        payload["output"] = output
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
    os.replace(tmp, path)


def die(msg, code=2):
    sys.stderr.write("[ace_mlx] %s\n" % msg)
    raise SystemExit(code)


def safe_title(raw, fallback):
    name = (raw or "").strip() or fallback
    name = re.sub(r"[\\/:*?\"<>|\n\r\t]", " ", name).strip()
    name = re.sub(r"\s+", " ", name)
    return name[:60] or "未命名"


def build_body(p):
    prompt = (p.get("prompt") or "").strip()
    if not prompt:
        die("风格描述是空的，没法生成。")
    try:
        dur = float(p.get("duration") or 60)
    except (TypeError, ValueError):
        dur = 60.0
    dur = max(MIN_SEC, min(MAX_SEC, dur))

    lyrics = (p.get("lyrics") or "").strip()
    # ⚠️ 必须发**整数**：服务端把 duration_seconds 当整数解析，发 40.0 会被
    #    静默忽略、退回默认 60 秒（2026-11-19 实测，fl=40.0 出 60 秒，不报错）。
    body = {"model": MODEL, "prompt": prompt, "duration_seconds": int(round(dur))}

    # 二选一：纯器乐，或者带词。两个都给会被服务端拒（它明说了）。
    if lyrics in ("", "[Instrumental]", "[instrumental]"):
        body["instrumental"] = True
    else:
        body["lyrics"] = lyrics

    bpm = p.get("bpm")
    try:
        bpm = int(float(bpm))
        if 30 <= bpm <= 300:
            body["bpm"] = bpm
    except (TypeError, ValueError):
        pass

    keyscale = (p.get("keyscale") or "").strip()
    if keyscale:
        body["keyscale"] = keyscale

    ts = (p.get("timesignature") or "").strip()
    if ts:
        body["timesignature"] = ts

    # 语言：界面和遥控器默认都传 "unknown"，这里必须替它判断 ——
    # 空着的话服务端按英文唱，中文歌词会走样。
    language = (p.get("language") or "").strip().lower()
    if language in ("", "unknown", "auto"):
        # 假名 / 谚文先判：日文歌词里也有汉字，先看汉字会全判成中文。
        if re.search(r"[\u3040-\u30ff]", lyrics):
            language = "ja"
        elif re.search(r"[\uac00-\ud7af]", lyrics):
            language = "ko"
        elif re.search(r"[\u4e00-\u9fff]", lyrics):
            language = "zh"
        else:
            language = ""
    elif language == "zh-cn":
        language = "zh"
    if language:
        body["vocal_language"] = language

    seed = p.get("seed")
    try:
        seed = int(seed)
    except (TypeError, ValueError):
        seed = -1
    if seed >= 0:
        body["seed"] = seed

    mode = (p.get("mode") or "generate").strip()
    src = (p.get("src_audio") or "").strip()
    ref = (p.get("ref_audio") or "").strip()
    if mode == "repaint" and src and os.path.isfile(src):
        body["task"] = "cover"
        body["src_audio"] = base64.b64encode(open(src, "rb").read()).decode()
        try:
            body["cover_strength"] = float(p.get("cover_strength") or 0.5)
        except (TypeError, ValueError):
            body["cover_strength"] = 0.5
    elif ref and os.path.isfile(ref):
        body["ref_audio"] = base64.b64encode(open(ref, "rb").read()).decode()

    return body, dur, lyrics


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--params", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--progress", required=True)
    ap.add_argument("--port", type=int, default=11234)
    args = ap.parse_args()

    try:
        p = json.load(open(args.params, encoding="utf-8"))
    except Exception as exc:
        write_progress(args.progress, 0, "failed", "参数文件读不了", str(exc))
        die("参数文件不是合法 JSON：%s" % exc)

    body, dur, lyrics = build_body(p)
    if lyrics in ("", "[Instrumental]", "[instrumental]"):
        fallback = prompt_first(p)
    else:
        fallback = (lyrics.splitlines() or [prompt_first(p)])[0]
    title = safe_title(p.get("title"), fallback)
    out_path = os.path.join(args.out_dir, title + ".wav")
    timeout_s = int(dur * 3 + 180)

    write_progress(args.progress, 1, "running", "正在准备…",
                   "先把这一趟交给本机的 ACE-Step，它 8 步就能出结果")

    url = "http://127.0.0.1:%d/v1/audio/music-generations" % args.port
    req = urllib.request.Request(
        url,
        data=json.dumps(dict(body, stream=True)).encode(),
        headers={"Content-Type": "application/json"},
    )

    wav = None
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            ctype = resp.headers.get("Content-Type", "")
            if "event-stream" not in ctype:
                # 万一服务端回的是整块 WAV，也照样收下
                wav = resp.read()
            else:
                for raw in resp:
                    line = raw.strip()
                    if not line.startswith(b"data:"):
                        continue
                    chunk = line[5:].strip()
                    if chunk == b"[DONE]":
                        break
                    try:
                        ev = json.loads(chunk)
                    except Exception:
                        continue
                    typ = ev.get("type")
                    if typ == "error":
                        raise RuntimeError(ev.get("message") or str(ev))
                    if typ == "complete":
                        wav = base64.b64decode(ev.get("data", ""))
                        break
                    if typ == "progress":
                        stage = ev.get("stage") or ""
                        step = int(ev.get("step") or 0)
                        total = max(1, int(ev.get("total") or 1))
                        if stage == "encode":
                            pct = 2 + 13 * step / total
                            msg, det = "正在读懂你的描述和歌词…", "马上就开始写"
                        elif stage == "diffuse":
                            pct = 15 + 70 * (step + 1) / total
                            msg = "正在写（第 %d/%d 步）" % (step + 1, total)
                            det = "8 步走完就是成品，中途不用管"
                        else:
                            pct = 85 + 12 * step / total
                            msg, det = "正在把写好的变成声音…", "这一步最吃内存，别开别的吃内存的程序"
                        write_progress(args.progress, pct, "running", msg, det)
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            detail = exc.read().decode("utf-8", "replace")[:300]
        except Exception:
            pass
        write_progress(args.progress, 0, "failed", "这一趟被服务拒了", detail)
        die("HTTP %s：%s" % (exc.code, detail), 5)
    except Exception as exc:
        # 超时和断连都走这里
        write_progress(args.progress, 0, "failed", "这一趟没成",
                       "原因：%s" % exc)
        die("请求失败：%s" % exc, 6 if "timed out" in str(exc) else 5)

    if not wav or len(wav) <= 44:
        write_progress(args.progress, 0, "failed", "服务没给出音频",
                       "它说完成了，但回来的东西不是一段声音")
        die("空的音频响应", 5)

    os.makedirs(args.out_dir, exist_ok=True)
    with open(out_path, "wb") as fh:
        fh.write(wav)

    write_progress(args.progress, 100, "done", "出好了",
                   "一共 %.0f 秒，写进 %s" % (time.time() - t0, os.path.basename(out_path)),
                   output=out_path)
    print("[ace_mlx] 音频：%s" % out_path)


def prompt_first(p):
    return (p.get("prompt") or "未命名").strip()[:20]


if __name__ == "__main__":
    main()
