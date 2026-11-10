import Foundation
import AppKit

/// 「送到 MIR Studio」：把当前这份谱交给本机 8808 的离线网页工作室。
///
/// 用户 2026-10-24 要的：生成好的谱子、或导入来做 cover 的 MusicXML，
/// 一键送过去 —— 在网页里点音符改，再让他重唱，看看准不准。
///
/// 工作室本体在 `default-workspace/mi-studio`：
/// 零依赖本地服务器，只监听 127.0.0.1。没在跑就顺手拉起来。
@MainActor
final class ScoreStudioClient {
    static let shared = ScoreStudioClient()

    private let port: UInt16 = 8808

    /// 打开工作室页面 —— **固定用 Chrome**，不碰系统默认浏览器。
    ///
    /// 用户 2026-11-10 提的：「在进入 MIR Studio 的时候强制使用 Chrome，
    /// 不要使用其他的浏览器 —— 因为我的日常生活当中的确是需要 Safari 变成默认浏览器。」
    /// 另外 studio 的 MIDI 键盘那一栏本来就只有 Chrome 认（Safari 不支持 Web MIDI）。
    ///
    /// 找不到 Chrome 时才退回默认浏览器 —— 能打开总比打不开强，但**不假装成功**。
    private static func openInChrome(_ page: URL) {
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        guard FileManager.default.fileExists(atPath: chrome.path) else {
            NSWorkspace.shared.open(page)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([page], withApplicationAt: chrome, configuration: config) { _, error in
            guard error != nil else { return }
            // Chrome 明明在、却没开成（极少见）—— 退回默认浏览器，别静默留个空。
            DispatchQueue.main.async { NSWorkspace.shared.open(page) }
        }
    }

    /// 谱面工作室（现在叫 **MIR Studio**）是**可选组件**（另一个项目的本地网页服务）。
    ///
    /// 位置不写死：`CS_STUDIO_DIR` 指到哪就用哪；否则按顺序找
    /// **工作区里的 `mi-studio`**（现在的实际位置）→ `~/Music/mi-studio` →
    /// **旧名 `yue2-studio` 的两处**（2026-10-25 改名前的位置，留着兜底：
    /// 谁只搬了程序没搬目录，也不至于打不开）。
    ///
    /// ⚠️ 2026-10-25 踩到：以前只认 `~/Music/yue2-studio`，而项目其实在
    /// `default-workspace/` ⇒ 点「进入 MIR Studio」时服务器起在
    /// 一个不存在的目录里，页面打不开。现在按 `server.mjs` 是否存在来认。
    private var studioDir: URL {
        let env = ProcessInfo.processInfo.environment["CS_STUDIO_DIR"] ?? ""
        if !env.isEmpty {
            return URL(fileURLWithPath: NSString(string: env).expandingTildeInPath)
        }
        let fm = FileManager.default
        let workspace = BackendClient.locateRoot().deletingLastPathComponent()
        let home = fm.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        candidates.append(workspace.appendingPathComponent("mi-studio"))
        candidates.append(home.appendingPathComponent("Music/mi-studio"))
        candidates.append(workspace.appendingPathComponent("yue2-studio"))
        candidates.append(home.appendingPathComponent("Music/yue2-studio"))
        for url in candidates
        where fm.fileExists(atPath: url.appendingPathComponent("server.mjs").path) {
            return url
        }
        return candidates[0]
    }

    /// node 的位置同样可配：`CS_NODE` 优先，否则试常见的两个安装位置。
    private var nodePath: URL {
        let env = ProcessInfo.processInfo.environment["CS_NODE"] ?? ""
        if !env.isEmpty {
            return URL(fileURLWithPath: NSString(string: env).expandingTildeInPath)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return home.appendingPathComponent(".dsh/dsh-runtimes/dsh-primary-runtime/dependencies/node/bin/node")
    }

    /// 自检用：把三个路径原样报出来（`CS_STUDIO_DIR_PROBE=1`）。
    /// 不打开浏览器、不碰服务 —— 只回答"我打算在哪儿起它"。
    func probePaths() -> String {
        let dir = studioDir
        return "dir=\(dir.path) node=\(nodePath.path) "
            + "server=\(dir.appendingPathComponent("server.mjs").path)"
    }

    /// 把一份 ABC 谱送过去并打开浏览器。
    /// - completion: 成功时给的是打开的那页 URL；失败给的是人话错误。
    func send(abc: String, style: String, lyrics: String, seed: Int, steps: Int,
              title: String, completion: @escaping (Result<URL, Error>) -> Void) {
        writeOutputRoot()
        if isPortOpen() {
            post(abc: abc, style: style, lyrics: lyrics, seed: seed, steps: steps,
                 title: title, completion: completion)
        } else {
            launchServer()
            // 起服务器要一两秒；起来之后再发。起不来就报错，别假装成功。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                self.post(abc: abc, style: style, lyrics: lyrics, seed: seed, steps: steps,
                          title: title, completion: completion)
            }
        }
    }

    /// 只把工作室**打开**（手上没谱的时候用）。
    ///
    /// 2026-10-25 用户要的：「在有乐谱的情况下，点进入 studio 就带出那份乐谱」——
    /// 反过来，**没有谱**时也不该点不动：打开一个空页面，让他自己导入 XML。
    /// 服务器没跑就顺手拉起来；起不来如实报（别假装打开了）。
    func open(completion: @escaping (Result<URL, Error>) -> Void) {
        writeOutputRoot()
        guard let page = URL(string: "http://127.0.0.1:\(port)/") else {
            completion(.failure(NSError(domain: "studio", code: 0)))
            return
        }
        if isPortOpen() {
            Self.openInChrome(page)
            completion(.success(page))
            return
        }
        launchServer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else { return }
            if self.isPortOpen() {
                Self.openInChrome(page)
                completion(.success(page))
            } else {
                completion(.failure(NSError(
                    domain: "studio", code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                                "MIR Studio 没起来（日志在 /tmp/mi-studio.log）"])))
            }
        }
    }

    // MARK: - 私有

    /// 告诉工作室：「最近的作品」该看哪个文件夹（2026-10-25）。
    ///
    /// 用户把输出文件夹改到别处时，工作室不该还去翻项目里的 `output/`。
    /// 往工作室目录写一个纯文本小文件（`.output-root`），服务器优先读它。
    ///
    /// 写不成就拉倒 —— 工作室会退回默认的 `output/`，**不能因为这一步把门堵上**。
    private func writeOutputRoot() {
        let target = studioDir.appendingPathComponent(".output-root")
        let root = OutputLocation.url(projectRoot: BackendClient.locateRoot())
        try? root.path.write(to: target, atomically: true, encoding: .utf8)
    }

    /// 自检用（`CS_STUDIO_ROOT_PROBE=1`）：**真写一次** `.output-root`，
    /// 再把写进去的内容读回来 —— 「我写了一份」和「它真落地了」是两件事。
    func probeWriteRoot() -> String {
        writeOutputRoot()
        let target = studioDir.appendingPathComponent(".output-root")
        let text = (try? String(contentsOf: target, encoding: .utf8)) ?? "(没写进去)"
        return "target=\(target.path) content=\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private func post(abc: String, style: String, lyrics: String, seed: Int, steps: Int,
                      title: String, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let api = URL(string: "http://127.0.0.1:\(port)/api/load") else {
            completion(.failure(NSError(domain: "studio", code: 0)))
            return
        }
        var request = URLRequest(url: api)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "abc": abc,
            "style": style,
            "lyrics": lyrics,
            "seed": seed,
            "steps": steps,
            "title": title,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = obj["id"] as? String,
                      let page = URL(string: "http://127.0.0.1:\(self.port)/?session=\(id)") else {
                    completion(.failure(NSError(domain: "studio", code: 1,
                                                userInfo: [NSLocalizedDescriptionKey: "MIR Studio 没有回话"])))
                    return
                }
                Self.openInChrome(page)
                completion(.success(page))
            }
        }.resume()
    }

    private func launchServer() {
        // nohup + &：服务器要活过这次点击，不能因为 app 退出就断。
        let escapedDir = studioDir.path.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedNode = nodePath.path.replacingOccurrences(of: "\"", with: "\\\"")
        let command = "cd \"\(escapedDir)\" && nohup \"\(escapedNode)\" server.mjs >> /tmp/mi-studio.log 2>&1 &"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try? process.run()
    }

    /// 用一次 TCP 连接判断 8808 是否已经在听。
    private func isPortOpen() -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }
}
