import Foundation
import AppKit
import Combine

/// 界面与 render_adapter.sh 之间的唯一通道。
///
/// 它做四件事：写参数文件、起壳脚本、盯着 progress.json 汇报进度、必要时喊停。
/// 界面里没有任何模型或推理代码 —— 这一层只传话。
@MainActor
final class BackendClient: ObservableObject {

    @Published private(set) var progress = ProgressSnapshot()
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String = ""

    /// 这一趟是几点几分起的 —— 界面拿它算「已经等了 X」。
    ///
    /// 为什么需要它：光有一根进度条，百分比在半分钟里不动，等待的人就会以为
    /// 卡死了。「已经等了」这个数字**每秒都在涨**，它本身就是"还活着"的证据
    /// （2026-10-13 加）。
    @Published private(set) var startedAt: Date?

    /// 运行中的任务完成时回调：参数为输出音频路径、谱子路径（各自可能为 nil）。
    ///
    /// 为什么要两个参数：2026-10-12 加了「先出谱子」——那一档**只有谱子、
    /// 没有音频**。只报一个 output 的话，这一档要么被当成失败，
    /// 要么得拿谱子冒充音频路径（然后播放键点了没反应）。
    var onFinish: ((String?, String?) -> Void)?

    private var process: Process?
    private var pollTask: Task<Void, Never>?
    private var logHandle: FileHandle?
    /// 这一趟的日志文件。脚本一声不响地退出时，失败原因只在这里面，
    /// 得读回来告诉人（2026-10-18 加）。
    private var lastLogURL: URL?

    /// 项目根目录（含 render_adapter.sh 的那一层）。
    let root: URL

    /// 作品放在哪 —— 跟着偏好设置里的「输出文件夹」走；没挑过就是项目里的 `output/`。
    /// 路径只在 `OutputLocation` 里算一次（这里、偏好设置窗口、主窗口都问它要）。
    var outputRoot: URL { OutputLocation.url(projectRoot: root) }

    /// 进度文件的位置 —— **写死在项目里，不跟着「输出文件夹」走**。
    /// 它记的是"这一趟跑到哪儿了"，属于运行时状态、不是作品；
    /// 搁进用户的作品目录只会多一个碍眼的文件。Composer Assistant 将来也读这一个。
    var progressFile: URL { root.appendingPathComponent("output/progress.json") }

    init() {
        root = BackendClient.locateRoot()
    }

    /// 从可执行文件所在位置往上找 `render_adapter.sh`。
    /// 这样不论 .app 放在项目里的哪一层都能找到项目根。
    ///
    /// `nonisolated`：偏好设置窗口也要拿它算「默认放在哪」，而那边不是主线程隔离的
    /// 上下文。它只读文件系统，本来也不需要隔离。
    nonisolated static func locateRoot() -> URL {
        if let env = ProcessInfo.processInfo.environment["ACE_LOCAL_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        // ★ 2026-10-25：打包时把源码根写进 `Contents/Resources/root.txt`。
        //   装在 /Applications 时，往上找六层到不了项目根 —— 以前只能落到
        //   `~/Music/MySongwriter`，于是**双击打开是空列表**。
        //   仍然校验 `render_adapter.sh` 在不在：项目搬走了，这一条自动作废。
        if let resources = Bundle.main.resourceURL {
            let stamp = resources.appendingPathComponent("root.txt")
            if let text = try? String(contentsOf: stamp, encoding: .utf8) {
                let root = URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines))
                if FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("render_adapter.sh").path) {
                    return root
                }
            }
        }
        var dir = Bundle.main.bundleURL.standardizedFileURL
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("render_adapter.sh")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        // 兜底：源码树里没找到（说明 .app 被单独拷贝出去了），就用一个中性默认位置。
        //
        // ⚠️ 这一支是**留给别人的**：别人的机器上没有本项目的源码路径。
        // 找不到 `render_adapter.sh` 时程序会出不了歌 —— 界面上会明说
        // 「设 ACE_LOCAL_ROOT 指到源码目录」，不会静默乱跑。
        return URL(fileURLWithPath: NSString(string: "~/Music/MySongwriter").expandingTildeInPath)
    }

    // MARK: - 启动

    func start(request: GenerationRequest) {
        guard !isRunning else { return }
        lastError = ""

        do {
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
            // 进度文件留在项目里（理由见上面 progressFile 那条），它那个目录也得存在
            try FileManager.default.createDirectory(
                at: progressFile.deletingLastPathComponent(), withIntermediateDirectories: true)

            // 1. 写参数文件
            let stamp = Self.stampFormatter.string(from: Date())
            let runDir = outputRoot.appendingPathComponent(
                Self.folderName(stamp: stamp, title: request.title))
            try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
            let paramsURL = runDir.appendingPathComponent("params.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(request).write(to: paramsURL)

            // 2. 清掉上一轮的进度，免得界面先看到陈旧的 100%
            //
            // 这份"开跑前"的状态**用同一个结构体编码出来**，不再手写那行 JSON ——
            // 手写的话，字段一多（2026-10-13 加了 detail）就必然漏，而读的一方
            // 只会安静地少看到一句话。
            startedAt = Date()
            let fresh = ProgressSnapshot(percent: 0, state: "running", message: "正在启动…",
                                         updated: 0, output: nil,
                                         detail: "先把这一趟交给引擎，马上就有下文")
            progress = fresh
            if let data = try? JSONEncoder().encode(fresh) {
                try? data.write(to: progressFile)
            }

            // 3. 起壳脚本（它自己再起独立子进程跑推理）
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            // 两台引擎，同一套契约（params.json 进、progress.json 出）：
            // 换的只是脚本名，起进程、轮询、停止这些一个字都不用改。
            // 老任务没写 engine 的，一律当 Composer Step。
            // 2026-11-10 起有三台：YuE2、Stable Audio Medium、以及拆掉了但留着后路的 Composer Step。
            let scriptName: String
            switch request.engine {
            case "yue2":        scriptName = "yue2_adapter.sh"
            case "stableaudio": scriptName = "stable_audio_adapter.sh"
            default:            scriptName = "render_adapter.sh"
            }
            let script = root.appendingPathComponent(scriptName).path

            // 脚本真的读得到吗？
            //
            // 系统（macOS 的「文稿文件夹」授权）有时候会把这条路掐掉：文件明明在，
            // 子进程却打不开。掐掉时 bash 只报一句 Operation not permitted 就退出，
            // 界面要是只显示"正在启动…"和涨秒数，人就会以为还在算，其实根本没开始
            // （2026-10-18 用户实际踩到，以为是"跟模型失去联系"）。
            //
            // 先自己看一眼，说不通就当场说清楚 —— 别让它变成一次无声的等待。
            if !FileManager.default.isReadableFile(atPath: script) {
                lastError = "系统没让 灵感路由 读你的项目文件夹。到「系统设置 → 隐私与安全性 → 文件与文件夹」里把 灵感路由 打开，再点一次生成。"
                progress = ProgressSnapshot(percent: 0, state: "failed",
                                            message: "打不开项目文件夹", updated: 0,
                                            output: nil)
                return
            }

            proc.arguments = [
                script,
                "--params", paramsURL.path,
                "--out-dir", runDir.path,
                "--progress", progressFile.path,
            ]
            proc.currentDirectoryURL = root
            proc.environment = Self.cleanEnvironment()

            let logURL = root.appendingPathComponent("logs")
            try? FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: true)
            let logFile = logURL.appendingPathComponent("gui-\(stamp).log")
            lastLogURL = logFile
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
            let handle = try FileHandle(forWritingTo: logFile)
            proc.standardOutput = handle
            proc.standardError = handle
            logHandle = handle

            proc.terminationHandler = { [weak self] finished in
                Task { @MainActor in
                    self?.handleTermination(status: finished.terminationStatus)
                }
            }

            try proc.run()
            process = proc
            isRunning = true
            startPolling()

        } catch {
            lastError = "启动失败：\(error.localizedDescription)"
            progress = ProgressSnapshot(percent: 0, state: "failed", message: lastError, updated: 0, output: nil)
        }
    }

    // MARK: - 停止

    func stop() {
        guard let proc = process, proc.isRunning else { return }
        let pid = proc.processIdentifier
        // 先杀它下面的推理进程（真正吃内存的那个），再杀壳脚本本身
        Self.run("/usr/bin/pkill", ["-TERM", "-P", "\(pid)"])
        proc.terminate()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if proc.isRunning {
                Self.run("/usr/bin/pkill", ["-KILL", "-P", "\(pid)"])
                kill(pid, SIGKILL)
            }
        }
        progress = ProgressSnapshot(percent: progress.percent, state: "idle", message: "已手动停止", updated: 0, output: nil)
    }

    // MARK: - 轮询 progress.json

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // 只在**内容真的变了**的时候赋值。
                // @Published 是无条件发通知的 —— 半秒一次照样推，界面就整个白重画一次。
                // 进度文件一秒里绝大多数时间是一模一样的（文字几秒才换一次），
                // 比一比再推，省下的是整块界面的重建（2026-10-13）。
                if let snap = self.readProgress(), snap != self.progress {
                    self.progress = snap
                }
                if !self.isRunning { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func readProgress() -> ProgressSnapshot? {
        guard let data = try? Data(contentsOf: progressFile) else { return nil }
        return try? JSONDecoder().decode(ProgressSnapshot.self, from: data)
    }

    private func handleTermination(status: Int32) {
        isRunning = false
        pollTask?.cancel()
        try? logHandle?.close()
        logHandle = nil
        process = nil

        if let snap = readProgress() {
            progress = snap
            if snap.state == "done" {
                // 音频、谱子各自可能没有 —— 「先出谱子」那一档只有后者。
                let audio = (snap.output?.isEmpty == false) ? snap.output : nil
                let score = (snap.score?.isEmpty == false) ? snap.score : nil
                if audio != nil || score != nil {
                    onFinish?(audio, score)
                    return
                }
            }
        }
        if status != 0 {
            // 失败原因不一定在 progress.json 里 —— 脚本要是连启动都没做到，
            // 它一个字都不会写，progress 还停在"正在启动…"。这时候真正的
            // 原因只在那份日志里（bash 会写一句）。
            //
            // 以前直接把"正在启动…"当错误显示，人看到的是一句空话加一个
            // 不再涨的秒数，只能猜是不是"跟模型失去联系"
            // （2026-10-18 用户实际踩到）。
            let reported = progress.message
            var message: String
            if reported.isEmpty || reported == "正在启动…" {
                message = "引擎没能启动（退出码 \(status)）"
                if let tail = Self.logTail(lastLogURL) {
                    message += "：" + tail
                }
            } else {
                message = reported
            }
            lastError = message
            progress = ProgressSnapshot(percent: progress.percent, state: "failed", message: message, updated: 0, output: nil)
        }
        onFinish?(nil, nil)
    }

    // MARK: - 工具

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// 日志的最后一行（非空）。启动失败时，原因就这一行。
    private static func logTail(_ url: URL?) -> String? {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > 4096 ? end - 4096 : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
            .split(separator: "\n")
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init)
    }

    /// 输出目录叫什么：`20261011-153045 上课比天大`。
    ///
    /// 时间戳在前、名字在后，两个好处各占一半：
    ///   · **时间戳在前** → 访达里按名字排序就是按时间排序，最新的一直在最上面；
    ///   · **名字在后** → 不用点进去就知道哪首是哪首（2026-10-11 用户提的）。
    ///
    /// 没名字（老任务、或标题是空白）就只用时间戳，不硬凑一个「未命名」上去。
    static func folderName(stamp: String, title: String) -> String {
        let raw = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return stamp }
        return "\(stamp) \(FileName.safe(raw))"
    }

    /// 交给子进程的环境：断掉一切代理，确保不出网。
    private static func cleanEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "all_proxy"] {
            env.removeValue(forKey: key)
        }
        env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        return env
    }

    private static func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: - 清理陈旧状态

    /// 界面刚启动时不可能有任务在跑。此刻如果读到 progress.json 还写着
    /// "running"，那一定是上次没收干净（界面被强退、脚本被 kill -9），
    /// 留着它会让界面显示成「一直在生成」。
    func clearStaleProgressIfNeeded() {
        guard let snap = readProgress(), snap.state == "running" else { return }
        var fixed = snap
        fixed.state = "failed"
        fixed.message = "上次生成没有正常结束（界面被关闭或强制退出）"
        // 上一趟那句「通常一两分钟」别留在失败信息底下 —— 它说的是那次，
        // 摆在这儿会像在解释这次为什么失败。
        fixed.detail = nil
        if let data = try? JSONEncoder().encode(fixed) {
            try? data.write(to: progressFile)
        }
    }

    // MARK: - 载入历史

    /// 扫一遍输出目录，把以前生成过的曲子重新列出来。
    /// 每个任务一个子目录，里面有 params.json（当初填的参数）和 wav（成品）。
    /// 没有这一步的话，关掉软件重开，界面就空了 —— 曲子还在，但看不见也导不出。
    func loadHistory() -> [GenerationItem] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: outputRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [GenerationItem] = []
        for dir in entries {
            let values = try? dir.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
            guard values?.isDirectory ?? false else { continue }

            let paramsURL = dir.appendingPathComponent("params.json")
            guard let data = try? Data(contentsOf: paramsURL),
                  let request = try? JSONDecoder().decode(GenerationRequest.self, from: data)
            else { continue }

            let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            // ACE-Step 出 wav，YuE2 出 flac —— **两种都得认**。
            // 只认 wav 的话，YuE2 那几首重开界面就会从列表里消失
            //（音频和谱子其实都还躺在盘上）。2026-10-12 加 YuE2 时一起改的。
            let audio = contents.first(where: {
                let ext = $0.pathExtension.lowercased()
                return ext == "wav" || ext == "flac"
            })
            // 「先出谱子」按过、还没按「生成」的那几条：盘上只有谱子、没有音频。
            // 不认它们的话，重开界面那一条就凭空消失了 ——
            // 而它正是你打算接着"照它唱"的那一份（2026-10-12 一起加的）。
            let score = contents.first(where: {
                ["abc", "xml"].contains($0.pathExtension.lowercased())
            })
            guard audio != nil || score != nil else { continue }

            var item = GenerationItem(
                title: AppViewModel.title(for: request),
                request: request,
                outputPath: audio?.path,
                scorePath: audio == nil ? score?.path : nil,
                state: audio != nil ? "done" : "score"
            )
            // 目录名里带着时间戳就信它；认不出来的（更早的目录，名字是
            // lesson / showcase 那种）**问文件系统要创建时间**。
            //
            // ★ 2026-10-11 踩到：这里原先什么都不做，item 就留着构造时的
            //   `Date()` —— 于是**每个认不出名字的旧目录都自称「刚刚生成的」**，
            //   按时间倒序一排，它们全都挤到**最新那条前面**去了。
            //   用户看到的后果是：刚生成完的那首不在最上面。
            if let date = Self.parseStamp(dir.lastPathComponent) {
                item.createdAt = date
            } else if let created = values?.creationDate {
                item.createdAt = created
            }
            found.append(item)
        }
        // 时间一样时用名字兜底，顺序才是稳定的（旧目录的几个创建时间可能撞在一起）
        return found.sorted {
            $0.createdAt == $1.createdAt ? $0.title < $1.title : $0.createdAt > $1.createdAt
        }
    }

    private static func parseStamp(_ name: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        // 目录名大概是「20261011-153045 上课比天大」这种，时间戳只有前面 15 个字符，
        // 多出来的名字会让解析直接失败，所以先截出来。
        // 更老的目录（lesson / showcase 之类）截出来也解析不了，返回 nil ——
        // 调用方用「当前时间」兜底，不编造日期。
        return f.date(from: String(name.prefix(15)))
    }
}
