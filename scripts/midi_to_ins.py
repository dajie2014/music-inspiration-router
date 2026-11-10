#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把一份 MIDI 压成 YuE2 原生 ABC 的「伴奏声部」（Ins 轨），人声留空。

为什么要有它（2026-11-08）
--------------------------
实验已经量过：只改 Ins 轨，成品就跟着变，而且**只在 Ins 写音符的小节变**
（同输入两次逐字节相同 ⇒ 引擎可复现，差异不可能是随机）。
所以「拿自己的 MIDI 当伴奏骨架」这条路是通的 —— 缺的只是一个入口。

规矩（跟 native_abc.py 一条都不能松）
------------------------------------
· X:1 / 空 T: / M: / L:1/16 / Q: / 两行 V: **一字不差**；
· 两声明的小节数、小节网格必须一样；
· 时值只收 1,2,3,4,6,8,12,16,24,32,48（L: 单位），长的拆开；
· 每行 1–4 小节，音乐行以 | 收尾。

把人声那条留空（整小节休止）—— 用户 2026-11-08：「这个功能最大作用在伴奏上，
可以不管声乐」。要人声就另给一份谱，或者在这份上补 Vocal 行。

用法
----
    midi_to_ins.py <源.mid> <输出.abc> [--track N] [--start-seconds S]
                   [--bars 16] [--bpm 120] [--voice top|bottom] [--skip-drums]
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from push_to_live import parse_midi          # 复用项目里现成的纯标准库解析器

STEP_SEMI = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
SHARP_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
SUPPORTED_DURATIONS = (48, 32, 24, 16, 12, 8, 6, 4, 3, 2, 1)
UNITS = 4                                    # 一个四分音符 = 4 个 L:1/16 单位
CELLS_PER_BEAT = UNITS

VOICE_LINES = ['V: Vocal clef=treble name="Vocal Melody" snm="Vocal"',
               'V: Ins clef=treble name="Ins Melody" snm="Inst."']


def abc_lengths(units):
    """总时值（L: 单位）拆成它收的几段 —— 长的优先。"""
    units = max(1, int(units))
    parts, left = [], units
    while left > 0:
        for size in SUPPORTED_DURATIONS:
            if size <= left:
                parts.append(size)
                left -= size
                break
        else:
            parts.append(1)
            left -= 1
    return parts


def abc_pitch(midi):
    """MIDI 音高 → (ABC 字母, 需要的临时记号)。C 大调：黑键都写临时记号。"""
    pc = midi % 12
    octave = midi // 12 - 1
    name = SHARP_NAMES[pc]
    letter, acc = name[0], name[1:]
    if octave >= 5:
        body = letter.lower() + "'" * (octave - 5)
    else:
        body = letter.upper() + "," * (4 - octave)
    accidental = "^" if acc == "#" else ""
    return body, accidental


def render_note(midi, units, accidental):
    body, _ = abc_pitch(midi)
    parts = abc_lengths(units)
    return "-".join(accidental + body + ("" if s == 1 else str(s)) for s in parts)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("midi")
    ap.add_argument("out")
    ap.add_argument("--track", type=int, default=None, help="用第几轨（0 起）；不给就挑音符最多的非鼓轨")
    ap.add_argument("--start-seconds", type=float, default=None,
                    help="从第几秒起截；不给就自动从这条轨第一个音开始（拆轨 MIDI 前面常是空的）")
    ap.add_argument("--bars", type=int, default=16)
    ap.add_argument("--beats", type=int, default=4)
    ap.add_argument("--bpm", type=float, default=120.0)
    ap.add_argument("--voice", choices=("top", "bottom"), default="top",
                    help="同一时刻好几个音时留哪个：top 最高音（默认）/ bottom 最低音")
    ap.add_argument("--skip-drums", action="store_true", default=True)
    ap.add_argument("--thin", type=int, default=1,
                    help="每 N 个 1/16 格只留第一个有声的（N=4 就是每拍一个音，压掉琶音的密度）")
    ap.add_argument("--octave", type=int, default=0,
                    help="整体升/降八度：+1 升一个八度，-1 降一个八度")
    args = ap.parse_args(argv)

    tracks = parse_midi(args.midi)
    if not tracks:
        sys.stderr.write("这份 MIDI 里没有音符。\n")
        return 2
    if args.track is not None:
        if args.track >= len(tracks):
            sys.stderr.write("只有 %d 条有音符的轨（0–%d）。\n" % (len(tracks), len(tracks)-1))
            return 2
        name, notes = tracks[args.track]
    else:
        # 自���挑：先按轨名把鼓剔掉（MIDI 的鼓轨音符最多，不剔就永远是它），
        # 再挑音符最多的那条。名字认不出来就全都留着。
        candidates = [t for t in tracks
                      if not re.search(r"drum|perc|打击|鼓", t[0] or "", re.I)]
        if not candidates:
            candidates = tracks
        name, notes = max(candidates, key=lambda t: len(t[1]))
    if not notes:
        sys.stderr.write("这条轨上一个音都没有。\n")
        return 2

    seconds_per_beat = 60.0 / args.bpm
    # 没指定起点就自动从这条轨第一个音开始 —— 拆轨出来的 MIDI 常常前面一大段是空的
    # （那份「道貌岸然」的钢琴轨要到 170 秒才有第一个音，不从这儿起就是一条空线）。
    if args.start_seconds is None:
        args.start_seconds = max(0.0, notes[0][1] * seconds_per_beat) if notes else 0.0
    bars = args.bars
    cells_per_bar = args.beats * CELLS_PER_BEAT
    start_beat = args.start_seconds / seconds_per_beat
    end_beat = start_beat + bars * args.beats

    # 只留这一段
    seg = [(p, s, d) for (p, s, d, v) in notes if s + d > start_beat and s < end_beat]

    # 摊到 1/16 网格：每格存一个 midi（同时响的取最高或最低）
    total_cells = bars * cells_per_bar
    grid = [None] * total_cells
    for pitch, onset, dur in seg:
        first = int(round((onset - start_beat) * CELLS_PER_BEAT))
        last = int(round((onset + dur - start_beat) * CELLS_PER_BEAT))
        first = max(0, min(total_cells - 1, first))
        last = max(first + 1, min(total_cells, last))
        for c in range(first, last):
            cur = grid[c]
            if cur is None:
                grid[c] = pitch
            elif args.voice == "top" and pitch > cur:
                grid[c] = pitch
            elif args.voice == "bottom" and pitch < cur:
                grid[c] = pitch

    # 抽稀：每 N 格一块，块里只留第一个有声的（其余当休止）
    if args.thin > 1:
        for blk in range(0, total_cells, args.thin):
            live = [i for i in range(blk, min(blk + args.thin, total_cells))
                    if grid[i] is not None]
            if not live:
                continue
            for i in live[1:]:
                grid[i] = None
        # 负数八度/正数八度整体挪
    if args.octave:
        for i, c in enumerate(grid):
            if c is not None:
                grid[i] = max(0, min(127, c + 12*args.octave))

    # 每小节写成一串
    ins_bars = []
    for b in range(bars):
        chunk = grid[b*cells_per_bar:(b+1)*cells_per_bar]
        out = []
        i = 0
        while i < len(chunk):
            if chunk[i] is None:
                j = i
                while j < len(chunk) and chunk[j] is None:
                    j += 1
                out.append("".join("z" + ("" if s == 1 else str(s))
                                   for s in abc_lengths(j - i)))
                i = j
            else:
                midi = chunk[i]
                j = i
                while j < len(chunk) and chunk[j] == midi:
                    j += 1
                body, acc = abc_pitch(midi)
                out.append(render_note(midi, j - i, acc))
                i = j
        ins_bars.append("".join(out) + "|")

    lines = ["X:1", "T:", "M:%d/4" % args.beats, "L:1/16",
             "Q:1/4=%d" % int(round(args.bpm))]
    lines += VOICE_LINES
    lines.append("K:C")
    vocal_bar = "z%d|" % cells_per_bar
    for group in range(0, bars, 4):
        take = min(4, bars - group)
        lines.append("V: Vocal")
        lines.append("".join([vocal_bar] * take))
        lines.append("V: Ins")
        lines.append("".join(ins_bars[group:group+take]))

    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    filled = sum(1 for c in grid if c is not None)
    print("用了轨「%s」：%d 个音，%d 小节，%d 个格子有声（%.0f%%）"
          % (name, len(seg), bars, filled, 100.0*filled/total_cells))
    return 0


if __name__ == "__main__":
    sys.exit(main())
