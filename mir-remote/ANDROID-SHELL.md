# 手机端壳方案（2026-11-17 · MIR Remote 做的，可复制到创作台）

> 这份是「把一个本机网页变成手机上能用的 App」的完整做法。
> MIR Remote 是第一个走通它的；创作台（casting-studio）将来要做手机端，照这个抄。

## 一句话

**网页是本体，壳只是门。** 壳只做三件事：找对电脑的地址、接住下载、连不上说人话。

## 四件东西

| 件 | 是什么 | 在 MIR Remote 里的位置 |
|---|---|---|
| ① 本机服务 | 已有的网页后端（HTTP，监听 0.0.0.0） | `server.py`（7871） |
| ② 安卓壳 | 一个 Activity：WebView 全屏 + 地址探测 + 下载监听 | `app/src/.../MainActivity.java` |
| ③ 下载页 + 二维码 | `/app` 一页：下载按钮 + 二维码 + 装法提示 | `server.py` 的 `/app` 路由 |
| ④ 配对 | 6 位码 → token，页面 localStorage 记住 | `/v1/pair` + `index.html` |

## 壳的关键做法（照抄即可）

1. **地址候选表**：先试上次成功的地址，再试「出门地址（Tailscale）」，最后「家里地址」。
   后台线程逐个 `GET /v1/info`（2.5 秒超时），哪个返回 200 就加载哪个。
2. **连不上**：不甩报错，给人话 + 「再试一次」「换一个地址」两个按钮；换地址弹输入框。
3. **下载**：`web.setDownloadListener` → `DownloadManager`（落到手机下载目录）。
4. **WebView 设置**：JS、DOM storage、`usesCleartextTraffic`（http 必需）、
   `mediaPlaybackRequiresUserGesture(false)`（`<audio>` 要能播）。
5. **返回键**：先 `web.canGoBack()`，没有才退出。
6. **打包**：不用 Gradle，aapt2 → javac → d8 → zipalign → apksigner。
   工具链借 `voicecasterrecorder/tools/`（安卓 SDK + JDK + 签名），`build.sh` 自己建链接。
7. **图标**：用项目自己的图标缩成 5 个密度（mdpi 48 / hdpi 72 / xhdpi 96 / xxhdpi 144 / xxxhdpi 192）。

## 下载页 + 二维码

- `/app` 页面：一个下载按钮 + 二维码 + 「未知来源」「微信里打不开就点右上角在浏览器打开」。
- 二维码内容 = **局域网地址 + `/app`**（手机在家里 WiFi 扫码才通）；
  出门那条地址在 App 里自动试，二维码只做一套。
- 二维码用 Swift + CoreImage 生成（`state/qrgen.swift`），不依赖第三方库、不联网，
  生成完用 `qrread` 解码核对一遍。

## 踩过的坑（都在 MIR Remote 里踩到过）

1. **http 下 `navigator.clipboard` 不可用**（浏览器只认 https/localhost）——「复制」按钮
   点了没反应。兜底 `execCommand('copy')`，再不行弹一个**能长按复制**的框。
2. **`*.png` / `*.xml` 的 .gitignore 会误伤壳 App 的资源**（图标、AndroidManifest、
   strings/styles）——要单独 `!` 放行，否则别人 clone 下来编不了。
3. **`<audio>` 要 Range**（iOS 尤其不播不支持 Range 的链接），文件接口按 206 分段返回。
4. **微信扫 http 链接能开，但微信里点下载常常没反应**——页面上明写「在浏览器打开」。
5. **iOS 不做 App**（用户 2026-11-17 定）：分享链接发到 iOS 微信，点开就能听/下。
6. **别把地址写死**：服务只认地址不认路 —— Tailscale / 局域网 / 穿透地址都能用。
7. **配对码只有 6 位**：要限速（每 IP 每分钟 8 次）。

## 搬到创作台（casting-studio）要改什么

- **地址**：创作台服务是 **7870**，壳里 `CANDIDATES` 换掉；探活接口换成创作台自己的。
- **页面**：创作台已有网页面板（左栏四板块），手机端壳直接套那个页面；
  手机上主要看「出图 / 听成品 / 下载」，按钮要放大、一手能点。
- **配对**：创作台现在没有配对 —— 照 `mir-remote/server.py` 的 `/v1/pair` 抄一个
  （6 位码 + Bearer token + localStorage），否则手机端等于把服务裸奔在局域网。
- **下载**：作品在 `/Volumes/REBIRTH/...`，下载走创作台的文件接口（要 Range）。
- **二维码 / 下载页**：直接复用 `/app` 的模板。

## 一句话判据

**壳永远不做业务**：壳只负责「找路、接下载、说人话」。业务全在网页里，
所以改功能只改网页，壳几年都不用动。
