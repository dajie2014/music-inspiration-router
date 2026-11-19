#!/bin/bash
# 双击就开始：起 MIR Remote 服务。起来之后这个窗口可以关掉，服务留在后台。
# 电脑重启过 = 服务没了 = 手机连不上，再双击这里一次。
cd "$(dirname "$0")" || exit 1

PORT="${MIR_PORT:-7871}"
TAILSCALE=/usr/local/bin/tailscale

# 局域网地址：别写死 en0 —— 这台机器的局域网地址在 en1。
lan_ip() {
  for NIC in en0 en1 en2 en3 en4 en5; do
    A=$(/sbin/ifconfig "$NIC" 2>/dev/null | /usr/bin/awk '/inet /{print $2; exit}')
    case "$A" in ""|127.*|169.254.*) ;; *) echo "$A"; return;; esac
  done
}

ts_ip() {
  [ -x "$TAILSCALE" ] && "$TAILSCALE" ip -4 2>/dev/null | head -1
}

show_address() {
  echo
  echo "  在家里（同一个 WiFi）：http://$(lan_ip):${PORT}"
  T=$(ts_ip)
  if [ -n "$T" ]; then
    echo "  在外面（Tailscale）：  http://${T}:${PORT}"
  fi
  echo "  配对码：$(cat state/pair_code.txt 2>/dev/null || echo '（见 state/pair_code.txt）')"
  echo
}

# 已经开着了吗？（重复双击两次会撞端口，一句人话比一串报错强）
if /usr/bin/nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  echo "MIR Remote 已经开着了。"
  show_address
  echo "（这个窗口可以直接关掉，服务还在后台跑）"
  exit 0
fi

echo "MIR Remote —— 手机上遥控这台电脑出一首歌。"
/usr/bin/nohup /usr/bin/python3 server.py > state/boot.log 2>&1 < /dev/null &
echo $! > state/service.pid

# 等它真的听起来，再报地址；起不来就照实说
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 0.5
  /usr/bin/nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
done

if /usr/bin/nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  echo "MIR Remote 已开。"
  show_address
  echo "（这个窗口可以直接关掉，服务还在后台跑）"
  echo "  日志：$(pwd)/state/boot.log"
else
  echo "没起来。日志最后几行："
  tail -20 state/boot.log 2>/dev/null
  exit 1
fi
