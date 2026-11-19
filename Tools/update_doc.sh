#!/usr/bin/env bash
# 重新生成《My Songwriter 使用手册》的 DOCX 与 PDF，一次出齐。
#
#   正文    docs/使用手册.md        面向用户，**带界面实拍图**
#   图      docs/images/           正文里写 ![说明](images/xx.jpg)
#   产出    My-Songwriter-使用手册.docx / .pdf（都放在项目根）
#
# 日后改手册：改 md → 需要新图就把图按序号放进 docs/images/ → 跑本脚本。
# **少一张图这里会报错**，不会"内容都在、就是没图"地静默过去。
#
# 这套流程是从 composer-assistant 的 Tools/update_doc.sh 简化来的
# （那边一次出三份文档，这边只有一份）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="/Users/jieda/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3"
NODE="/Applications/DeepSeek Harness.app/Contents/Resources/runtime/primary-runtime/dependencies/node/bin/node"
LO_CLI="/Applications/DeepSeek Harness.app/Contents/Resources/app.asar.unpacked/dsh/node_modules/@deepseek-ai/libreoffice-kit/lib/cli.js"
CHECK="/Applications/DeepSeek Harness.app/Contents/Resources/runtime/office-skills/scripts/check_office.py"

NAME="使用手册"
DOCX="${ROOT}/灵感路由-${NAME}.docx"
PDF="${ROOT}/灵感路由-${NAME}.pdf"
MINIMG=7                    # 6 张界面实拍 + 1 张整页封面，少一张就是出错

# ⚠️ 变量一律写 `${VAR}` —— macOS 自带的是 bash 3.2，
#    `$NAME》` 这种"变量名后面紧跟中文"会被它当成变量名的一部分，
#    直接报 `NAME》: unbound variable`。（2026-10-11 在这行上踩过一次，
#    而本项目 README 的坑表里早就记着这一条了。）
cd "$ROOT"
mkdir -p build/doc

echo "==> [0/4] 排封面"
# 封面用欢迎界面的截图（用户 2026-10-18 定的）。版本号从 CHANGELOG 顶上取，
# 不在封面里另写一个 —— 否则两边迟早对不上。
#
# ★ 2026-11-19：封面底部**不再印「日期 · 版本号」**（`--no-foot`）。
#   用户 10-27 已经定过「封面上不要写版本号最好」、连日期也去掉；
#   但这条没落到本脚本里，于是每版又印上一次，而且日期一直停在 10 月。
#   版本号该出现的地方是：程序「关于 / 版本历史」、CHANGELOG 第一行。
VER="$(grep -m1 -E '^## [0-9]+\.[0-9]+\.[0-9]+' CHANGELOG.md | sed -E 's/^## ([0-9.]+).*/\1/')"
"$PY" Tools/make_cover.py docs/images/07-第一次打开.png docs/images/00-封面.png --version "$VER" --no-foot

echo "==> [1/4] 生成 DOCX"
"$PY" Tools/make_article_docx.py docs/使用手册.md "$DOCX"

echo "==> [2/4] 检查《${NAME}》"
# ★ 2026-10-18：DSH 更新后 `office-skills/scripts/check_office.py` 不在了。
#   它只是"多一道外部检查"，不是这个脚本的核心；缺了就明说跳过，
#   不要让整条流水线断在这里（下面的表格/星号/图自查照做）。
if [ -f "$CHECK" ]; then
  "$PY" "$CHECK" "$DOCX" --out "build/doc/check-${NAME}.json" >/dev/null
  echo "    结构检查通过"
else
  echo "    （没有 check_office.py，跳过外部结构检查）"
fi

"$PY" - "$DOCX" "$MINIMG" <<'PYEOF'
import sys
from docx import Document

path, minimg = sys.argv[1], int(sys.argv[2])
d = Document(path)

# 表格不许溢出页面：溢出的话打印和转 PDF 都会被切掉右边
sec = d.sections[0]
usable = (sec.page_width - sec.left_margin - sec.right_margin) / 360000
bad = []
for i, t in enumerate(d.tables, 1):
    total = sum((c.width or 0) for c in t.rows[0].cells) / 360000
    if total > usable + 0.05:
        bad.append(f"表{i} {total:.2f}cm > {usable:.2f}cm")
if bad:
    print("    ✗ 表格溢出：" + "；".join(bad)); raise SystemExit(1)
print(f"    {len(d.tables)} 个表格都在 {usable:.2f}cm 内")

# 字面 ** = 排版函数没认出粗体，星号会直接印在纸上
bad = [p.text[:60] for p in d.paragraphs if "**" in p.text]
for t in d.tables:
    for r in t.rows:
        for c in r.cells:
            if "**" in c.text:
                bad.append(c.text[:60])
if bad:
    print("    ✗ 文档里有字面 ** —— 排版函数没认出来：")
    for b in bad[:5]:
        print("      " + b)
    raise SystemExit(1)
print("    无字面 markdown 记号")

# 图：既数张数，也看有没有"（图缺失：…）"那行 ——
# 早先踩过：图没找到，文档只比无图版大十几个字节，内容都在、就是少一块。
missing = [p.text for p in d.paragraphs if p.text.startswith("（图缺失：")]
if missing:
    print("    ✗ 有图没找到：" + "；".join(missing)); raise SystemExit(1)
n = len(d.inline_shapes)
if n < minimg:
    print(f"    ✗ 只嵌了 {n} 张图，少于要求的 {minimg} 张"); raise SystemExit(1)
print(f"    {n} 张图全嵌进去了（要求 ≥{minimg}）")
PYEOF

echo "==> [3/4] 转 PDF"
rm -f "$PDF"
"$NODE" "$LO_CLI" convert --input "$DOCX" --output "$PDF" >/dev/null
[ -f "$PDF" ] || { echo "    ✗ PDF 未生成"; exit 1; }
echo "    → $(stat -f%z "$PDF") 字节"

echo "==> [4/4] 确认 PDF 不是白页、且图真的在 PDF 里"
# ★ docx 有图 ≠ PDF 有图，中间还隔着一次转换，所以这儿再数一遍。
# Readme：LibreOffice 的 render 子命令在本机会出空白页，改用系统自带的 sips。
"$PY" - "$PDF" "$MINIMG" <<'PYEOF'
import os
import re
import subprocess
import sys

pdf, min_img = sys.argv[1], int(sys.argv[2])
blob = open(pdf, "rb").read()
n = len(re.findall(rb"/Subtype\s*/Image", blob))
pages = len(re.findall(rb"/Type\s*/Page[^s]", blob))
png = "build/doc/p1.png"
subprocess.run(["sips", "-s", "format", "png", pdf, "--out", png],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
size = os.path.getsize(png) if os.path.exists(png) else 0
if n < min_img:
    print(f"    ✗ PDF 里只有 {n} 张图，少于 {min_img} 张"); raise SystemExit(1)
flag = "✓" if size >= 10000 else "!! 首页渲染偏小，可能是空白页"
print(f"    {pages} 页 / 图 {n} 张 / 首页渲染 {size} 字节 {flag}")
PYEOF

echo
echo "==> 完成：$(basename "$DOCX") / $(basename "$PDF")"
