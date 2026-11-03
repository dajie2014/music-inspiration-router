#!/usr/bin/env python3
"""把人声轨清空，旋律搬到器乐轨 —— 让 YuE2 只能出伴奏。

为什么需要：
  YuE2 的 `--instrumental` 是空的，`[Instrumental]` 在适配器里也只是
  归一成空歌词；不给词它照样会哼。唯一验证有效的办法是改谱：
    · 人声轨（Vocal）清成休止，只留和弦符号；
    · 原来的旋律整条搬到器乐轨（Ins）；
    · 和弦必须留在 Vocal —— YuE2 的 ABC 方言规定 chord symbols 只能在那儿。

用法：
  python3 strip_vocal.py <score.abc>        # 原地改，另存一份 .with-vocal.abc
"""

import re
import sys
from pathlib import Path


def strip_vocal(text: str) -> str:
    lines = text.split("\n")
    kidx = next((i for i, l in enumerate(lines) if l.startswith("K:")), None)
    if kidx is None:
        raise ValueError("谱里没有 K: 行，格式不对")
    head, rest = lines[:kidx + 1], lines[kidx + 1:]

    blocks, cur = [], None
    for ln in rest:
        if re.match(r"^V:\s*\S+\s*$", ln):
            cur = (ln.split(":", 1)[1].strip(), [])
            blocks.append(cur)
        elif cur is not None:
            cur[1].append(ln)

    def bars(body):
        txt = " ".join(x.strip() for x in body if x.strip())
        return [b for b in txt.split("|") if b.strip()]

    out, i, paired = list(head), 0, 0
    while i < len(blocks):
        if i + 1 < len(blocks) and blocks[i][0] == "Vocal" and blocks[i + 1][0] == "Ins":
            vocal, ins = [], []
            for b in bars(blocks[i][1]):
                chords = "".join(re.findall(r'"[^"]*"', b))
                vocal.append(chords + "z16")
                ins.append(re.sub(r'"[^"]*"', '', b) or "z16")
            out += ["V: Vocal", "|".join(vocal) + "|",
                    "V: Ins", "|".join(ins) + "|"]
            paired += 1
            i += 2
        else:
            out += [f"V: {blocks[i][0]}"] + blocks[i][1]
            i += 1

    if paired == 0:
        raise ValueError("没找到 Vocal/Ins 配对声部，谱子不是预期的两轨格式")
    return "\n".join(out).rstrip("\n") + "\n"


def main():
    if len(sys.argv) < 2:
        print("用法: strip_vocal.py <score.abc>", file=sys.stderr)
        return 2
    p = Path(sys.argv[1])
    if not p.is_file():
        print(f"找不到谱子: {p}", file=sys.stderr)
        return 2
    original = p.read_text(encoding="utf-8")
    fixed = strip_vocal(original)
    (p.parent / (p.stem + ".with-vocal.abc")).write_text(original, encoding="utf-8")
    p.write_text(fixed, encoding="utf-8")
    n = fixed.count("V: Ins")
    print(f"人声轨已清空，旋律搬到器乐轨（{n} 段）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
