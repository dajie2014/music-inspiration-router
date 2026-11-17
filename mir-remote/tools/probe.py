#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MIR Remote 自检器 —— 打一遍协议，逐项打勾。

给两种人用：
  1. 我自己：改完服务，跑一遍就知道还通不通。
  2. 学生：照着一页纸协议做了个 Windows 版，跑一遍就知道合不合格，不用来问。

用法：
    python3 tools/probe.py http://192.168.31.99:7871 --code 123456
    python3 tools/probe.py http://192.168.31.99:7871 --code 123456 --full
    python3 tools/probe.py http://100.110.118.100:7871 --code 123456 --full --engine stableaudio

    --code    配对码（第一次要；已经配对过的服务可以用 --token 直接给）
    --full    真的跑一首最短的歌（会占几分钟本机算力）；不加只验协议
    --engine  用哪台引擎（默认挑第一台能出「最短」的）

退出码：0 = 全过；1 = 有一项没过。
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.request

OK, BAD, SKIP = "✅", "❌", "·"

_results = []


def check(name, ok, note=""):
    _results.append((name, ok, note))
    print("  %s %s%s" % (OK if ok else BAD, name, ("  — " + note) if note else ""))
    return ok


def request(base, path, method="GET", body=None, token=None, raw=False):
    url = base.rstrip("/") + path
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            payload = r.read()
            if raw:
                return r.status, payload, dict(r.headers)
            return r.status, json.loads(payload.decode("utf-8")), dict(r.headers)
    except urllib.error.HTTPError as e:
        try:
            j = json.loads(e.read().decode("utf-8"))
        except Exception:
            j = {}
        return e.code, j, dict(e.headers)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base")
    ap.add_argument("--code", default="")
    ap.add_argument("--token", default="")
    ap.add_argument("--full", action="store_true")
    ap.add_argument("--engine", default="")
    ap.add_argument("--seconds", type=int, default=15)
    args = ap.parse_args()

    base = args.base.rstrip("/")
    print("\nMIR Remote 自检 → %s\n" % base)

    # ── 0. 起得来吗 ──
    st, info, _ = request(base, "/healthz")
    if not check("服务能打开（/healthz）", st == 200, "状态 %s" % st if st != 200 else ""):
        return finish()

    # ── 1. 它自己说能干什么 ──
    st, info, _ = request(base, "/v1/info")
    ok = st == 200 and info.get("v") == 1 and isinstance(info.get("engines"), list)
    check("GET /v1/info 说得清自己", ok, "" if ok else "状态 %s" % st)
    if not ok:
        return finish()
    print("      名字：%s  平台：%s" % (info.get("name", "?"), info.get("platform", "?")))

    engines = [e for e in info.get("engines", []) if e.get("available", True)]
    if not check("至少有一台引擎可用", len(engines) > 0,
                 "这台机器上没装引擎，能配对但出不了歌" if not engines else
                 "、".join(e.get("id", "?") for e in engines)):
        return finish()

    for e in info.get("engines", []):
        outs = ", ".join(e.get("outputs") or [])
        bad = "  ⚠️ 没标 local" if not e.get("local") else ""
        print("      · %-12s %s  [%s]%s" % (e.get("id"), e.get("title", ""), outs, bad))
        check("引擎 %s 诚实标了 local" % e.get("id"), bool(e.get("local")),
              "算力必须在本机，偷偷调云端不接受")

    # ── 2. 配对 ──
    token = args.token
    if not token:
        if not args.code:
            print("  %s 没给 --code，跳过配对（可以用 --token 直接带一个）" % SKIP)
        else:
            st, j, _ = request(base, "/v1/pair", "POST", {"code": args.code, "name": "自检器"})
            token = j.get("token", "") if isinstance(j, dict) else ""
            check("POST /v1/pair 换到 token", st == 200 and bool(token),
                  "" if token else (j.get("message") or "状态 %s" % st))
    else:
        check("用现成的 token", True)

    if not token:
        return finish()

    # 错码要被挡住（这是门槛，不能形同虚设）
    st, j, _ = request(base, "/v1/pair", "POST", {"code": "000000", "name": "x"})
    check("错配对码被拒", st in (403, 429), "状态 %s" % st)

    st, j, _ = request(base, "/v1/jobs", "POST", {"engine": "nope"})
    check("不带 token 的请求被拒", st == 401, "状态 %s" % st)

    st, j, _ = request(base, "/v1/jobs", "POST", {"engine": "nope"}, token)
    check("不认识的引擎被拒", st == 400, "状态 %s" % st)

    # ── 3. 排一首 ──
    eng = args.engine
    if not eng:
        # 挑一台能最短出结果的：纯音乐那台能指定时长
        for cand in ("stableaudio", "heartmula", "acestep", "yue2"):
            if any(e.get("id") == cand for e in engines):
                eng = cand
                break
    e = next((x for x in engines if x.get("id") == eng), None)
    if not e:
        check("找到引擎 %s" % eng, False, "它没说自己有这台")
        return finish()

    body = {"engine": eng, "style": "钢琴 慢 安静", "lyrics": "自检这一首\n只为看看路通不通"}
    if e.get("params", {}).get("duration"):
        body["duration"] = args.seconds
    st, j, _ = request(base, "/v1/jobs", "POST", body, token)
    jid = (j or {}).get("id") or ((j or {}).get("job") or {}).get("id")
    check("POST /v1/jobs 收下了", st in (200, 201) and bool(jid),
          "" if jid else ((j or {}).get("message") or "状态 %s" % st))
    if not jid:
        return finish()
    print("      任务号：%s（引擎 %s）" % (jid, eng))

    if not args.full:
        st, j2, _ = request(base, "/v1/jobs/%s/cancel" % jid, "POST", {}, token)
        check("POST /v1/jobs/<id>/cancel 能停", st == 200, "状态 %s" % st)
        print("\n  （没加 --full，只验协议；加 --full 会真跑一首）")
        return finish()

    # ── 4. 看进度 ──
    print("\n  等它出来（最多等 20 分钟）…")
    deadline = time.time() + 1200
    last = ""
    job = {}
    while time.time() < deadline:
        st, job, _ = request(base, "/v1/jobs/%s" % jid, token=token)
        if st != 200:
            check("GET /v1/jobs/<id> 能读", False, "状态 %s" % st)
            return finish()
        pct = job.get("percent", 0)
        msg = job.get("message", "")
        if msg != last:
            print("      %3d%%  %s" % (pct, msg))
            last = msg
        if job.get("state") in ("done", "failed", "cancelled"):
            break
        time.sleep(2)

    check("这一首出完了", job.get("state") == "done",
          "状态 %s / %s" % (job.get("state"), job.get("message", "")))
    if job.get("state") != "done":
        return finish()

    outputs = job.get("outputs") or []
    check("它交回了成品清单", len(outputs) > 0, "%d 个文件" % len(outputs))
    kinds = set(f.get("kind") for f in outputs)
    print("      成品：%s" % ", ".join(sorted(kinds)))

    # ── 5. 拿文件 ──
    for f in outputs[:6]:
        url = f.get("url") or ""
        if not url:
            check("文件 %s 给了下载地址" % f.get("name"), False)
            continue
        st, body_bytes, hdr = request(base, url, token=token, raw=True)
        ok = st == 200 and len(body_bytes) > 1024
        check("下载 %s" % f.get("name"), ok, "%d 字节" % len(body_bytes))

    # ── 6. 分享页（不用 token） ──
    st, body_bytes, _ = request(base, "/s/%s" % jid, raw=True)
    check("分享页不用 token 就能开", st == 200 and b"<audio" in body_bytes,
          "状态 %s" % st)

    # ── 7. 作品库 ──
    st, songs, _ = request(base, "/v1/songs", token=token)
    got = isinstance(songs, dict) and any(s.get("id") == jid for s in songs.get("songs", []))
    check("作品库里有这一首", got, "" if got else "状态 %s" % st)
    leaked = any("dir" in s for s in (songs.get("songs") or [])) if isinstance(songs, dict) else False
    check("作品库不露本机路径", not leaked)

    return finish()


def finish():
    bad = [r for r in _results if not r[1]]
    print("\n" + "─" * 46)
    if bad:
        print("没过的 %d 项：" % len(bad))
        for name, _, note in bad:
            print("  · %s%s" % (name, ("  — " + note) if note else ""))
        print("─" * 46 + "\n")
        return 1
    print("全过（%d 项）✓\n" % len(_results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
