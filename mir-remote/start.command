#!/bin/bash
# 双击就开始：起 MIR Remote 服务，窗口关掉就停。
cd "$(dirname "$0")" || exit 1

PORT="${MIR_PORT:-7871}"

# 已经开着了吗？（重复双击两次会撞端口，一句人话比一串报错强）
if /usr/bin/nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  # 别写死 en0 —— 这台机器的局域网地址在 en1，en0 没有 IPv4。
  IP=""
  for NIC in en0 en1 en2 en3 en4 en5; do
    A=$(/sbin/ifconfig "$NIC" 2>/dev/null | /usr/bin/awk '/inet /{print $2; exit}')
    case "$A" in ""|127.*|169.254.*) ;; *) IP="$A"; break;; esac
  done
  echo "MIR Remote 已经开着了。"
  echo
  echo "  手机上打开：http://${IP:-127.0.0.1}:${PORT}"
  echo "  配对码在：$(pwd)/state/pair_code.txt"
  echo
  echo "（这个窗口可以直接关掉，服务还在别处跑）"
  exit 0
fi

echo "MIR Remote —— 手机上遥控这台电脑出一首歌。"
echo "（这个窗口别关；关了服务就停）"
echo
exec /usr/bin/python3 server.py
