import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 谱子的格式

enum ScoreFormat: String {
    case xml
    case abc

    var ext: String { rawValue }
    /// 跟人说话时用**正式名字** —— 用户 2026-10-12 特意说了：
    /// 「那个格式应该叫 MusicXML」，别用 XML 这个简称（后缀是 `.xml` / `.musicxml`，
    /// 但格式的名字只有一个）。界面上凡是**指这个格式**的地方都走它。
    ///
    /// ABC 一律**大写** —— 它是个格式名（跟 MusicXML 并排出现），
    /// 小写的 `abc` 混在中文句子和文件名里不好认（2026-10-13 改的，
    /// 起因是「放哪儿」那个面板的标题）。
    var label: String { self == .xml ? "MusicXML" : "ABC" }

    /// 用在提示与说明里 —— 说清这一种是给谁看的。
    var humanName: String {
        self == .xml ? "MusicXML（Dorico 直接打开）" : "ABC（YuE2 认的记谱文本）"
    }

    /// 判定一份文件是 MusicXML 还是 abc。
    ///
    /// ⚠️ **不能只看 `ext == "xml"`** —— 制谱软件另有一个 **`.musicxml`** 后缀
    ///    （Dorico 默认导出的就是它），只看 xml 会把它当成 abc、方向整个反掉，
    ///    表现是"点一下转格式就报转换失败"。
    ///    2026-10-12 拿用户那份 `… - 01_Lead - 01 Flow 1.musicxml` 实测踩到。
    ///
    /// `.mxl`（打包压缩过的 MusicXML）也归到这一边：它**是** MusicXML，
    /// 只是本机的转换器**还不认**它（真拿它去转会像以前那样报失败）。
    /// 归对边至少不会把一个谱子文件当成 abc 去读。
    static func of(_ url: URL) -> ScoreFormat {
        switch url.pathExtension.lowercased() {
        case "xml", "musicxml", "mxl": return .xml
        default: return .abc
        }
    }
}

// MARK: - 谱子的落地与搬运

/// 「文件」菜单那几条的实际动作。
///
/// 为什么单独一个文件：这些是**纯粹的文件活**（存到哪、重名怎么办、外来的谱子怎么转），
/// 跟界面状态无关。跟菜单声明摆在一起会混成一团。
///
/// 用户 2026-10-12 的原话是「把它生成的音乐保存在一个地方，让我事后进打谱软件继续打磨」
/// —— 所以「导出」的默认目标是**一个固定的、他找得到的地方**（见 `folder`），
/// 而不是埋在 `output/` 的时间戳目录里。
///
/// ⚠️ 整个 enum 标 `@MainActor`：它要问 `BackendClient.locateRoot()`（项目根在哪），
///    而那一层是主线程隔离的。这些活都是按菜单那一下触发的（拷贝、转换），
///    本来就发生在主线程；标上它，调用链才不会一路报隔离错误。
@MainActor
enum ScoreFiles {

    enum Failure: LocalizedError {
        case noScore
        case convertFailed(String)

        var errorDescription: String? {
            switch self {
            case .noScore:
                return "这一首没有谱子（只有 YuE2 出的才带谱子）"
            case .convertFailed(let why):
                return "谱子转换失败：\(why)"
            }
        }
    }

    // MARK: 存到哪儿

    /// 导出的谱子统一落在这儿 —— **「文稿」里的「Composer Step 谱子」**。
    ///
    /// 挑「文稿」是因为它是 Finder 侧边栏里就有的地方，点两下就找到；
    /// 挑中文名是因为它得让使用者一眼认出来是什么。
    ///
    /// `CS_SCORE_DIR` 可以改（自检用 —— 跑自检的沙箱写不了「文稿」）。
    static var folder: URL {
        let env = ProcessInfo.processInfo.environment
        if let custom = env["CS_SCORE_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        // ★ 2026-10-16 改名（Composer Step → My Songwriter）：谱子文件夹跟着改。
        //   **但旧文件夹里已经有他导出去的谱子** —— 新目录还没建、旧的存在时，
        //   就继续用旧的那个：**他找得到自己的谱子**比"名字一致"重要。
        //   （哪天他自己把那个文件夹改成新名字，这里就自动切过去。）
        let renamed = docs.appendingPathComponent("My Songwriter 谱子")
        let legacy = docs.appendingPathComponent("Composer Step 谱子")
        if !FileManager.default.fileExists(atPath: renamed.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
        return renamed
    }

    @discardableResult
    static func ensureFolder() throws -> URL {
        let dir = folder
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 给**人**看的位置 —— 别把一整条 `/Users/jieda/...` 摆到他面前。
    ///
    /// 默认那个文件夹就照人话说（「文稿 / My Songwriter 谱子」——「文稿」在访达
    /// 侧边栏里就有，点两下就到）；只有自定义过位置（`CS_SCORE_DIR`）或者他
    /// 在保存面板里挑去了别处，才给路径，并且把家目录缩成 `~`。
    static func humanLocation(of file: URL? = nil) -> String {
        let env = ProcessInfo.processInfo.environment
        let custom = env["CS_SCORE_DIR"] ?? ""
        let folderPath = folder.path

        if !custom.isEmpty { return shorten(file?.path ?? folderPath) }
        if let file, file.deletingLastPathComponent().path != folderPath {
            return shorten(file.path)
        }
        // 名字现取 —— 旧文件夹还在用的那阵子，这里也要说旧名字（不然他照着找会扑空）。
        return "「文稿 / \(folder.lastPathComponent)」"
    }

    private static func shorten(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: 转换器（在 YuE2 那个项目里）

    /// `abcxml` 的位置。YuE2 装在哪儿它就跟着在哪儿（`YUE2_ROOT` 可覆盖）。
    static var converter: URL {
        let env = ProcessInfo.processInfo.environment
        let root: URL
        if let custom = env["YUE2_ROOT"], !custom.isEmpty {
            root = URL(fileURLWithPath: custom)
        } else {
            root = BackendClient.locateRoot()
                .deletingLastPathComponent()
                .appendingPathComponent("yue2-local")
        }
        return root.appendingPathComponent("abcxml")
    }

    /// XML ↔ ABC。用的是 Wim Vree 那两个老牌脚本（MuseScore 导入 ABC 也用它们）。
    /// 输出与输入**同目录同名**，只换后缀 —— 这是 `abcxml` 自己的规矩。
    @discardableResult
    static func convert(_ file: URL, to format: ScoreFormat) throws -> URL {
        let tool = converter
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw Failure.convertFailed("找不到转换器（\(tool.path)）")
        }
        let process = Process()
        process.executableURL = tool
        process.arguments = [format == .xml ? "to-xml" : "to-abc", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let produced = file.deletingPathExtension().appendingPathExtension(format.ext)
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: produced.path) else {
            // ⚠️ **取最后几行，别把整段输出甩出去。**
            // 转换器一路上会打好些**正常**的话（比如「人声 +1 个八度，动了 279 个音」），
            // 整段贴出来会让真正的原因被这些话盖住 —— 2026-10-13 实测就撞上过：
            // 界面报的是「…人声 +1 个八度，动了 279 个音」，看着像转换器在报怨音区，
            // 真正的原因（那个目录写不进去）反而没露面。
            let lines = (String(data: output, encoding: .utf8) ?? "")
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let tail = lines.suffix(3).joined(separator: "\n")
            throw Failure.convertFailed(tail.isEmpty ? "退出码 \(process.terminationStatus)" : tail)
        }
        return produced
    }

    /// 是不是 MIDI 文件（`.mid` / `.midi`）。
    ///
    /// ⚠️ 别用 `ScoreFormat.of()` 判 —— 它对 MIDI 会落到 `.abc`（默认分支），
    ///    因为它只认识 XML 和 ABC 两种。这里单独判。
    static func isMIDI(_ url: URL) -> Bool {
        ["mid", "midi"].contains(url.pathExtension.lowercased())
    }

    /// MIDI → MusicXML（**实验性**，2026-11-23 用户要的口子）。
    ///
    /// 为什么多一步 MuseScore：MIDI 里没有调号、拍号、声部分配、打击乐映射，
    /// MuseScore 的 MIDI 导入器会把这些**猜**出来；不猜的话转出来的谱子没法读。
    /// 转换器是 `yue2-local/midi2xml`（和 `abcxml` 放在同一个目录）。
    ///
    /// 输出与输入**同目录同名**，只换后缀 —— 与 `convert` 的规矩一致。
    /// MIDI 里没有歌词、连音、力度、表情，转出来不会有（这不是丢东西）。
    /// 真正跑 `midi2xml`。
    ///
    /// ⚠️ 标成 `nonisolated`，好放到后台跑 —— MIDI 转谱要几十秒，
    /// 在主线程 `waitUntilExit` 会让界面像卡死一样（本项目最忌讳"点了没反应"）。
    /// `tool` 由调用方在主线程算好传进来（`converter` 那边要问项目根，是主线程的活）。
    nonisolated static func runMIDI2XML(_ file: URL, tool: URL) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw Failure.convertFailed("找不到转换器（\(tool.path)）")
        }
        let process = Process()
        process.executableURL = tool
        process.arguments = [file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let produced = file.deletingPathExtension().appendingPathExtension("xml")
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: produced.path) else {
            let lines = (String(data: output, encoding: .utf8) ?? "")
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let tail = lines.suffix(3).joined(separator: "\n")
            throw Failure.convertFailed(tail.isEmpty ? "退出码 \(process.terminationStatus)" : tail)
        }
        return produced
    }

    /// 旧项目的 MusicXML → 工作室要的 ABC，**先探八度**（2026-10-25 用户要的：
    /// 「不要直接放上去，做个探针检查一下；还是高八度就改成新机制」）。
    ///
    /// 旧机制导出的 XML 只降了人声、伴奏还是高八度；直接 `to-abc` 会被多升一个八度。
    /// 探针在 `yue2-local/tools/studio_abc.py` 里（按两条声部的音高中位数判），
    /// 判成旧的就把伴奏降回来再转。**不动用户那份 XML**（脚本在临时副本上做）。
    static func studioABCFromXML(_ xml: URL) -> String? {
        let script = converter.deletingLastPathComponent()
            .appendingPathComponent("tools/studio_abc.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, xml.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["ok"] as? Bool) == true,
              let abc = object["abc"] as? String, !abc.isEmpty
        else { return nil }
        return abc
    }

    /// 把转出来的文件**搬到**指定位置。
    ///
    /// 为什么需要这一步：`abcxml` 只会把产物写在**源文件旁边**（它的规矩，
    /// 我们没法叫它直接输出到别处）。所以"让用户指定位置"这件事，
    /// 只能**转完再搬** —— 不能省成"直接输出到目标"。
    ///
    /// 用户 2026-10-13 提的：「xml to abc 在转化之前，可以让用户指定转化的位置」。
    ///
    /// ⚠️ 目标已存在时这里是**先删再搬**：这一步的确认由调用方负责
    ///（保存面板自己会问「是否替换」；自检那条路有 `CS_CONVERT_YES`）。
    @discardableResult
    static func place(_ produced: URL, at destination: URL) throws -> URL {
        if produced.standardizedFileURL == destination.standardizedFileURL { return produced }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: produced, to: destination)
        return destination
    }

    /// 转出来的文件**建议叫什么**（保存面板里那个默认名）。
    static func proposedName(for file: URL, target: ScoreFormat) -> URL {
        let stem = shortStem(file.deletingPathExtension().lastPathComponent)
        return file.deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension(target.ext)
    }

    /// 把一个**太长**的文件名掐短一点，但**不许掐到认不出来**。
    ///
    /// 由头（用户 2026-10-13）：「可能是因为自动命名太长了，所以找不到」——
    /// Dorico 导出分谱的名字是 `曲名 - 声部 - 序号 曲名`：
    ///
    ///     示例歌名 - 01_Vocal Melody - 01 示例歌名.musicxml
    ///     示例歌名 - 02_Ins Melody   - 01 示例歌名.musicxml
    ///     示例歌名 - Full score     - 01 示例歌名.musicxml
    ///
    /// **唯一能区分它们的那段（声部）夹在中间**，头尾都是曲名重复 —— 在文件面板里
    /// 一截断，三个看着一模一样，根本挑不准。
    ///
    /// 规则**只做一件事、而且很保守**：末尾那段若（去掉前导编号后）就是第一段
    /// 曲名的重复，就把它去掉，留下 `曲名 - 声部`。**认不出来就原样返回** ——
    /// 宁可名字长，也不能改错（改错会撞名，撞名会覆盖他的谱子）。
    static func shortStem(_ stem: String) -> String {
        let parts = stem.components(separatedBy: " - ")
        guard parts.count >= 3 else { return stem }     // 少于三段别动（动完只剩一段＝把声部丢了）
        let first = parts[0]
        var tail = parts[parts.count - 1]
        while let c = tail.first, c.isNumber || c == "." || c == "_" || c == " " {
            tail.removeFirst()
        }
        guard !tail.isEmpty else { return stem }
        // 末段与首段相同、或者互相包含 —— 都算"曲名又说了一遍"
        guard tail == first || tail.contains(first) || first.contains(tail) else { return stem }
        let kept = parts.dropLast().joined(separator: " - ")
        return kept.isEmpty ? stem : kept
    }

    /// 那个文件夹里**没有该挑的文件**时，给一句人话提示（返回 nil = 不必说话）。
    ///
    /// 由头（用户 2026-10-13）：「找不到点 ABC 文件」——
    /// 他手上是 Dorico 导出的 MusicXML，却很可能点了右边那个「ABC → MusicXML」：
    /// 那个窗口**只列 `.abc`**，而他的文件夹里一个都没有 ⇒ 一个能点的都没有。
    /// 两个按钮长得像（都是「A → B」），点反了很难自己发现。
    ///
    /// 所以：**他按取消时**，如果那个文件夹里确实没有该挑的那种文件，就在底部说一句
    /// —— 只是一行字，**不弹窗、不打断**；正常取消（文件明明有、他就是不想转了）不会看到。
    static func nothingToPickText(in dir: URL?, source ext: String,
                                  target: ScoreFormat) -> String? {
        guard let dir else { return nil }
        let want: ScoreFormat = (ext == "abc") ? .abc : .xml
        // ⚠️ **按后缀精确比，而且只看文件** —— 别拿 `ScoreFormat.of()` 去判：
        //    它对**没有后缀的东西一律返回 abc**，于是**一个叫 `abc` 的文件夹**
        //    会被当成 abc 谱子 ⇒ 这句话永远说不出口。
        //    （2026-10-13 实测踩到：用户那个文件夹里恰好就有个 `abc` 目录 ——
        //      `CS_CONVERT_NOTE` 那条自检当场把 bug 抓出来了。）
        let exts: Set<String> = (want == .abc) ? ["abc"] : ["xml", "musicxml", "mxl"]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        let hasAny = entries.contains { url in
            guard exts.contains(url.pathExtension.lowercased()) else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
        guard !hasAny else { return nil }

        let sourceName = (want == .abc) ? "ABC" : "MusicXML"
        let button = (target == .xml) ? "ABC → MusicXML" : "MusicXML → ABC"
        return "这个文件夹里没有 \(sourceName) 文件。"
            + "要转的是另一种格式的话，用「\(button)」那个按钮；"
            + "也可以走「文件 → 导入谱子…」，方向它自己认。"
    }

    // MARK: 把歌词贴进谱面

    /// 把歌词贴到一份 MusicXML 上（**就地改**）。
    ///
    /// 用户 2026-10-12 提的：「希望从 ABC 转过来的 MusicXML 也能有歌词」。
    /// Composer Step 自己出的谱子里**没有词** —— YuE2 只写旋律与和弦，
    /// 词一直留在歌词框里（实测那份 `.abc` 的 `w:` 行 0 条、`.xml` 的 `<lyric>` 0 处），
    /// 于是拿进 Dorico 就看不出哪句唱哪里。
    ///
    /// 算法、对齐规则和全部实测数据都在 `scripts/attach_lyrics.py` 的说明里，
    /// 这里只负责把料备齐、把脚本叫起来。
    ///
    /// - Parameters:
    ///   - xml: 要贴的那一份（**会被就地改**，调用方先把产物复制出来）
    ///   - lyrics: 贴哪份词
    ///   - abc: 这份谱子的 ABC 版本 —— **段落（`% verse`）与连音（`-`）要从它读**，
    ///          MusicXML 里没有这些信息
    /// - Returns: 真贴上了才 true（没词、没 abc、脚本不在都返回 false，不报错）
    @discardableResult
    static func attachLyrics(to xml: URL, lyrics: String, abc: URL?) -> Bool {
        let text = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "[Instrumental]", let abc,
              FileManager.default.fileExists(atPath: abc.path),
              FileManager.default.fileExists(atPath: xml.path) else { return false }

        let script = BackendClient.locateRoot()
            .appendingPathComponent("scripts/attach_lyrics.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return false }

        // 歌词走临时文件 —— 它是多行文本，塞不进命令行参数
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cs-lyrics-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? text.write(to: tmp, atomically: true, encoding: .utf8)) != nil else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, abc.path, xml.path, tmp.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return false }
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: 找这一首的谱子

    /// 这一首的谱子（指定格式）。手上没有这一种时，**允许就地从另一种转一份** ——
    /// 比如 ACE-Step 那台只出了 abc，也能给你导一份 XML 出来。
    static func scoreURL(for item: GenerationItem,
                         format: ScoreFormat,
                         allowConvert: Bool = true) throws -> URL {
        // 基准路径跟着**音频**走；只出了谱子（还没唱）就跟着**谱子**走 ——
        // 两种情况都从 item.scoreBase 拿，别在这儿各算一遍（2026-10-12）。
        guard let base = item.scoreBase else { throw Failure.noScore }
        let wanted = base.appendingPathExtension(format.ext)
        if FileManager.default.fileExists(atPath: wanted.path) { return wanted }

        guard allowConvert else { throw Failure.noScore }
        let other: ScoreFormat = (format == .xml) ? .abc : .xml
        let alternate = base.appendingPathExtension(other.ext)
        guard FileManager.default.fileExists(atPath: alternate.path) else { throw Failure.noScore }
        try convert(alternate, to: format)
        guard FileManager.default.fileExists(atPath: wanted.path) else {
            throw Failure.convertFailed("转完没看到 \(wanted.lastPathComponent)")
        }
        return wanted
    }

    /// 这一首有没有谱子可导（哪一种都行）。
    static func hasScore(_ item: GenerationItem) -> Bool {
        guard let base = item.scoreBase else { return false }
        return ["xml", "abc"].contains {
            FileManager.default.fileExists(atPath: base.appendingPathExtension($0).path)
        }
    }

    // MARK: 导出

    /// 存进那个固定文件夹，**不弹窗**。
    ///
    /// ⚠️ 重名**不覆盖**，加 `-2`、`-3`：那个文件夹里的文件，用户很可能已经拖进
    /// Dorico 改过了 —— 覆盖等于把他改的活抹掉。
    static func export(_ item: GenerationItem, as format: ScoreFormat) throws -> URL {
        let source = try scoreURL(for: item, format: format)
        let dir = try ensureFolder()
        let target = uniqueURL(in: dir, stem: fileStem(for: item), ext: format.ext)
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    /// 弹保存面板自己挑地方（按住 Option 点菜单走这条）。默认还落在那个文件夹。
    static func exportWithPanel(_ item: GenerationItem, as format: ScoreFormat) throws -> URL? {
        let source = try scoreURL(for: item, format: format)
        try? ensureFolder()

        let panel = NSSavePanel()
        panel.title = "导出谱子（\(format.label)）"
        panel.message = format.humanName
        panel.nameFieldStringValue = "\(fileStem(for: item)).\(format.ext)"
        panel.directoryURL = folder
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: format.ext) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let target = panel.url else { return nil }
        try? FileManager.default.removeItem(at: target)   // 他自己挑的地方，覆盖就覆盖
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    /// 文件叫什么：`20261012-135010 示例作品`。
    /// 与 `output/` 里的目录名同款 —— 谱子离开软件之后还能一眼对上是哪一首。
    static func fileStem(for item: GenerationItem) -> String {
        let stamp = stampFormatter.string(from: item.createdAt)
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return stamp }
        return "\(stamp) \(FileName.safe(title))"
    }

    private static func uniqueURL(in dir: URL, stem: String, ext: String) -> URL {
        var candidate = dir.appendingPathComponent("\(stem).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(stem)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    // MARK: 导入

    /// 上一次**挑谱子**时待的文件夹 —— 下次就开在那儿。
    ///
    /// 由头（用户 2026-10-24）：导入 MusicXML 的窗口每次都落回
    /// 「My Songwriter 谱子」，而他的谱子常在「下载」或 Dorico 的工程目录里，
    /// 每次都得自己翻过去。挑过一次就记住，跟「转格式」那条各记各的。
    private static let lastScoreFolderKey = "scoreOpenFolder"

    static var lastScoreFolder: URL? {
        get {
            UserDefaults.standard.string(forKey: lastScoreFolderKey)
                .map { URL(fileURLWithPath: $0) }
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: lastScoreFolderKey) }
    }

    static func rememberScoreFolder(_ file: URL) {
        lastScoreFolder = file.deletingLastPathComponent()
    }

    /// 挑一份谱子文件（XML / abc / MIDI）。
    static func pickFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选一份谱子"
        panel.message = "MusicXML（Dorico 导出的）或 abc 都行；MIDI 也行（实验：会先转成 MusicXML）"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types: [UTType] = []
        for ext in ["xml", "musicxml", "abc", "mid", "midi"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        if !types.isEmpty { panel.allowedContentTypes = types }
        // 上次挑过就回上次那儿；第一次才用默认的谱子文件夹。
        panel.directoryURL = lastScoreFolder ?? folder
        return panel.runModal() == .OK ? panel.url : nil
    }

    enum ImportAction {
        case resing          // 照这份谱子重唱一首
        case convertOnly     // 只转格式
        case cancel
    }

    /// 导进来的谱子要干什么 —— **问一句再动手**。
    ///
    /// 用户 2026-10-12 选的「两样都要」：所以不替他决定。
    /// 重唱那一条要说清拿谁的词、谁的风格，别让他点了才知道。
    ///
    /// ★ **2026-10-13 加了"空项目"这一支**：`targetTitle` 为 nil = **左边一手都没选**
    ///   （刚按「新建一首」，或者是新开的一首都没写的状态）。
    ///   旧文案在那个场景里会说「用「**还没选中的曲子**」的词和风格」——
    ///   一句话里摆个占位符，等于什么都没说；而这正是用户说的
    ///   「**尤其是开空项目写新歌的时候**」。
    static func askWhatToDo(fileName: String, targetTitle: String?) -> ImportAction {
        let alert = NSAlert()
        alert.messageText = "这份谱子怎么用？"
        if let targetTitle {
            alert.informativeText = "\(fileName)\n\n"
                + "· **按它重唱**：用「\(targetTitle)」的词和风格，照这份谱子再出一首\n"
                + "· **只转格式**：转成另一种格式，放进「\(targetTitle)」的文件夹"
            alert.addButton(withTitle: "按这份谱子重唱")
        } else {
            alert.informativeText = "\(fileName)\n\n"
                + "· **照它写一首新歌**：把谱子里的拍号、调号、歌词读出来，按它唱\n"
                + "· **只转格式**：转成另一种格式，放在原文件旁边"
            alert.addButton(withTitle: "照这份谱子写新歌")
        }
        alert.addButton(withTitle: "只转格式")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .resing
        case .alertSecondButtonReturn: return .convertOnly
        default:                       return .cancel
        }
    }
}

// MARK: - 菜单里那几条，挂在界面状态上

@MainActor
extension AppViewModel {

    /// 「进入 MIR Studio」（菜单 ⇧⌘Y，2026-10-25 用户要的）：
    /// **有谱就把那份谱带过去**，没谱就只打开页面让他自己导入。
    ///
    /// 为什么要跟「送到 MIR Studio」分开：那个按钮是"只送谱"，没有谱时只能报错；
    /// 而这个入口是"进那间屋子"，空着手也能进。
    func enterScoreStudio() {
        if studioABC() != nil {
            sendToScoreStudio()
            return
        }
        studioMessage = "MIR Studio 打开了；这边没有谱，可以在里面导入 MusicXML。"
        ScoreStudioClient.shared.open { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                self.studioMessage = "打不开 MIR Studio：\(error.localizedDescription)"
            }
        }
    }

    /// 这一首此刻能交给工作室的谱：面板里改过的 ABC → 选中那首目录里的谱。
    /// 两处取法只能有一份 —— `sendToScoreStudio` 与 `enterScoreStudio` 都从这儿拿。
    ///
    /// ★ 2026-10-25 用户要求：「选中一个已经生成的旧项目，点工作室，就把旧项目的
    ///   谱子一起揪出来」。以前只看 `item.scoreBase`（**只认 YuE2 引擎**），
    ///   旧项目/别的引擎就一律当"没谱"。现在按目录里真实存在的文件找，
    ///   不管哪台引擎；只有 `.xml` 的就地转一份 `.abc`。
    func studioABC() -> String? {
        if !ss2RepairedABC.isEmpty { return ss2RepairedABC }
        guard let item = selectedItem else { return nil }

        // 1) 输出目录里同名的 `.abc`
        if let output = item.outputPath {
            let base = URL(fileURLWithPath: output).deletingPathExtension()
            let abc = base.appendingPathExtension("abc")
            if let text = try? String(contentsOf: abc, encoding: .utf8), !text.isEmpty {
                return text
            }
            // 2) 只有 `.xml`：**先探八度再转**（旧项目的伴奏还是高八度，
            //    直接转会被多升一个八度）。探针脚本缺失时才退回老路。
            let xml = base.appendingPathExtension("xml")
            if FileManager.default.fileExists(atPath: xml.path) {
                if let text = ScoreFiles.studioABCFromXML(xml), !text.isEmpty {
                    return text
                }
                if let made = try? ScoreFiles.convert(xml, to: .abc),
                   let text = try? String(contentsOf: made, encoding: .utf8), !text.isEmpty {
                    return text
                }
            }
        }

        // 3) 「先出谱子」那种：手上只有谱、没有音频
        if let score = item.scorePath {
            let url = URL(fileURLWithPath: score)
            if url.pathExtension.lowercased() == "abc",
               let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// 「送到 MIR Studio」：把当前这份谱交给本机 8808 的离线网页工作室，
    /// 在那里点音符改，改完点「重新唱」——用来验证「人修过的谱会不会唱得更准」。
    ///
    /// 取谱顺序：面板里改过的 ABC → 选中那首输出目录里的 .abc。
    func sendToScoreStudio() {
        guard let text = studioABC(), !text.isEmpty else {
            studioMessage = "先选一首有谱子的，或导入一份 MusicXML"
            return
        }
        studioMessage = "正在送到 MIR Studio…"
        ScoreStudioClient.shared.send(
            abc: text,
            style: form.prompt,
            lyrics: form.lyrics,
            seed: form.seed,
            steps: form.steps,
            title: selectedItem?.title ?? ""
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.studioMessage = "已送到 MIR Studio；改完点「重新唱」，会回到这里开一轮新的生成"
            case .failure(let error):
                self.studioMessage = "送不过去：\(error.localizedDescription)"
            }
        }
    }

    var selectedItem: GenerationItem? {
        guard let id = selectedID else { return nil }
        return items.first { $0.id == id }
    }

    /// 选中的这一首有没有谱子可导。
    var canExportScore: Bool {
        guard let item = selectedItem else { return false }
        return ScoreFiles.hasScore(item)
    }

    /// 「导出谱子（XML / abc）」。
    /// 平时**一键存进那个固定文件夹**；**按住 Option 点**则弹保存面板自己挑地方
    ///（用户 2026-10-12 选的「两个都要」）。
    func exportScore(as format: ScoreFormat) {
        guard let item = selectedItem else {
            exportMessage = "先在左边选一首"
            return
        }
        let askWhere = NSEvent.modifierFlags.contains(.option)
        do {
            if askWhere {
                guard let url = try ScoreFiles.exportWithPanel(item, as: format) else { return }
                exportMessage = "谱子已存到 \(ScoreFiles.humanLocation(of: url))"
                    + attachNote(item: item, url: url, format: format)
            } else {
                let url = try ScoreFiles.export(item, as: format)
                exportMessage = "谱子已存到 \(ScoreFiles.humanLocation())"
                    + attachNote(item: item, url: url, format: format)
            }
        } catch {
            exportMessage = error.localizedDescription
        }
    }

    /// 导出的要是 MusicXML，**顺手把歌词贴进那份谱面**（用户 2026-10-12 提的）。
    ///
    /// 为什么不贴在源文件上：源文件是「谱子」那个固定文件夹里的底稿，
    /// 屏幕上显示这是"第几次导出"的产物；**用户手上拿到的这一份才需要带词**。
    ///（`ScoreFiles.export` 本来就是"复制一份出来"，所以在这儿补最合适。）
    ///
    /// ABC 版本就在同一目录（`scoreBase` 换后缀）—— 段落与连音要从它读。
    private func attachNote(item: GenerationItem, url: URL, format: ScoreFormat) -> String {
        guard format == .xml, let base = item.scoreBase else { return "" }
        let done = ScoreFiles.attachLyrics(to: url,
                                           lyrics: item.request.lyrics,
                                           abc: base.appendingPathExtension("abc"))
        return done ? " —— 歌词已贴进谱面" : ""
    }

    /// 「载入一首…」：从写过的曲子里挑一首，把参数填回表单。
    func presentLoadPicker() {
        guard !items.isEmpty else {
            exportMessage = "还没写过曲子 —— 先按「生成」出一首"
            return
        }
        let alert = NSAlert()
        alert.messageText = "载入哪一首？"
        alert.informativeText = "把它的参数填回右边，照着改一版。"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 25),
                                  pullsDown: false)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        for item in items {
            popup.addItem(withTitle: "\(item.title)　\(formatter.string(from: item.createdAt))")
        }
        if let id = selectedID, let index = items.firstIndex(where: { $0.id == id }) {
            popup.selectItem(at: index)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "载入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let index = popup.indexOfSelectedItem
        guard items.indices.contains(index) else { return }
        select(items[index])
    }

    /// 「导入谱子…」：选一份 XML / abc → 问一句要干什么 → 照做。
    ///
    /// 选文件、问一句、干活，拆成三段：前两段要弹面板，自检走不了；
    /// 后两段（`convertImported` / `resing`）不弹面板，所以自检能直接调它们
    ///（菜单那一下我点不动 —— 读菜单要「辅助功能」权限，本机没给）。
    func importScore() {
        guard let file = ScoreFiles.pickFile() else { return }
        // 记住这次在哪儿挑的 —— 下次还开那儿（他不用每次重新翻）。
        ScoreFiles.rememberScoreFolder(file)
        // ★ 实验（2026-11-23 用户要的口子）：选到 MIDI 就先转成 MusicXML，
        //   不进后面的「重唱 / 只转格式」那一步 —— MIDI 没有歌词，重唱无从谈起。
        //   转完只告诉他文件在哪儿，要不要接着用由他再点一次。
        if ScoreFiles.isMIDI(file) {
            convertMIDIToScore(file)
            return
        }
        // 没选中任何一首就传 nil —— 那句话得跟着换成"写新歌"的说法
        // （见 `askWhatToDo`；用户 2026-10-13 要的正是空项目里这一条）。
        switch ScoreFiles.askWhatToDo(fileName: file.lastPathComponent,
                                      targetTitle: selectedItem?.title) {
        case .cancel:      return
        case .convertOnly: convertImported(file)
        case .resing:      resing(with: file)
        }
    }

    /// MIDI → MusicXML（**实验功能**，2026-11-23 用户要的口子）。
    ///
    /// 转完只提示一句，不弹"要干什么" —— MIDI 没有歌词，重唱无从谈起；
    /// 他要是想接着用，再点一次「导入 MusicXML」挑转出来的那份。
    /// 转换放后台（几十秒），界面不卡。
    func convertMIDIToScore(_ file: URL) {
        let tool = ScoreFiles.converter.deletingLastPathComponent()
            .appendingPathComponent("midi2xml")
        exportMessage = "MIDI 转 MusicXML（实验）…谱子大时要几十秒，别急"
        Task {
            do {
                let xml = try await Task.detached(priority: .userInitiated) {
                    try ScoreFiles.runMIDI2XML(file, tool: tool)
                }.value
                await MainActor.run {
                    exportMessage = "转好了：\(xml.lastPathComponent)（实验功能，和 MIDI 放在同一个文件夹）"
                }
            } catch {
                await MainActor.run { exportMessage = error.localizedDescription }
            }
        }
    }

    /// 只转格式：XML ↔ abc（输出与输入同目录同名）。
    func convertImported(_ file: URL) {
        let other: ScoreFormat = (ScoreFormat.of(file) == .xml) ? .abc : .xml
        convert(file, to: other)
    }

    /// **纯粹转格式**那个按钮：挑一个谱子文件 → 在原文件旁边生成另一种格式。
    ///
    /// 用户 2026-10-12 特意交代过：「纯粹转格式，两个格式之间的互转」——
    /// 所以它**不生成、不看当前选中哪一首、不碰列表**。就是文件进、文件出。
    /// 两个方向各一个按钮，`target` 是**要转成**的格式。
    func convertScoreFile(to target: ScoreFormat) {
        let panel = NSOpenPanel()
        panel.title = (target == .xml) ? "挑一个 ABC 文件" : "挑一个 MusicXML 文件"
        panel.message = (target == .xml)
            ? "要转成 MusicXML —— 现在挑那份 ABC"
            : "要转成 ABC —— 现在挑那份 MusicXML（Dorico 导出的分谱，名字中间那段是声部）"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // 只让他看到该看的那种：转成 XML 就只挑 abc，反之亦然
        let wanted = (target == .xml) ? "abc" : "xml"
        if let type = UTType(filenameExtension: wanted) {
            panel.allowedContentTypes = [type]
        }
        // ★ 开在**上次挑过的那个文件夹**里，而不是固定那个「文稿 / Composer Step 谱子」。
        //   由头（用户 2026-10-13）：「自动命名太长了，找不到」—— 他的谱子其实都在
        //   `~/Downloads/Flows from 示例歌名/`，而面板原先每次都开在
        //   `ScoreFiles.folder`（那个文件夹他**根本没有**）⇒ 他得自己翻过去。
        panel.directoryURL = lastOpenFolder ?? ScoreFiles.folder
        guard panel.runModal() == .OK, let file = panel.url else {
            // ★ 他按了取消 —— 但如果那个文件夹里**一个能挑的文件都没有**，
            //   多半是**点错按钮**了（想转成 ABC，却点了「ABC → MusicXML」）。
            //   由头（用户 2026-10-13）：「找不到点 ABC 文件」：他手上是 Dorico 导出的
            //   MusicXML，而那个窗口只列 `.abc` ⇒ 一个能点的都没有。
            //   只是一行字、不弹窗、不打断：点错时才说，正常取消不会看到。
            noteIfNothingToPick(in: panel.directoryURL, source: wanted, target: target)
            return
        }
        lastOpenFolder = file.deletingLastPathComponent()
        convertPicked(file, to: target)
    }

    /// 把「这个文件夹里没有 XX 文件」那句话落到界面上（没什么可说就什么都不做）。
    private func noteIfNothingToPick(in dir: URL?, source ext: String, target: ScoreFormat) {
        if let text = ScoreFiles.nothingToPickText(in: dir, source: ext, target: target) {
            exportMessage = text
        }
    }

    /// 上一次**挑源文件**时待的文件夹 —— 下次就开在那儿。
    ///（跟"上次存到哪儿"分开记：一个是找料，一个是放成品，两件事。）
    private var lastOpenFolder: URL? {
        get {
            UserDefaults.standard.string(forKey: "convertOpenFolder")
                .map { URL(fileURLWithPath: $0) }
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: "convertOpenFolder") }
    }

    /// 「挑完源文件之后」那一半：**问位置 → 转**。
    ///
    /// 单独摘出来是为了**自检能直达它** —— 保存面板是模态的、点不动，
    /// 但"它长什么样"必须能亲眼看一次（本项目的老教训：光看代码看不出界面塌陷）。
    /// 自检入口：`CS_CONVERT_PANEL=<源文件路径>`（见 ContentView 的自检段）。
    func convertPicked(_ file: URL, to target: ScoreFormat) {
        // ★ 转换**之前**问一句「放哪儿」。取消 = 什么都不做
        //   （不给他转出一个没处搁的东西）
        //
        // 默认名字**不再照抄源文件名** —— 先掐掉尾段那个重复的曲名（见 `shortStem`）。
        // 用户说的「自动命名太长了」就是它：`示例歌名 - 01_Vocal Melody - 01 示例歌名`
        // 缩成 `示例歌名 - 01_Vocal Melody`，短一半，而且**声部那段还在**（不会撞名）。
        let proposed = ScoreFiles.proposedName(for: file, target: target)
        guard let destination = askWhereToPut(proposed, target: target) else { return }
        let pickedElsewhere = destination.standardizedFileURL != proposed.standardizedFileURL
        convert(file, to: target, placing: destination, placeAlreadyConfirmed: pickedElsewhere)
    }

    /// 「转出来的文件放哪儿？」—— 默认还是**原文件旁边、同名只换后缀**。
    ///
    /// 默认位置优先用**上一次挑过的文件夹**（macOS 上的常规习惯：你挑过一次，
    /// 它下次就从那儿开始）；没挑过才回到源文件旁边。
    ///
    /// - Returns: 挑好的目标路径（含文件名）；按了取消就是 nil。
    private func askWhereToPut(_ proposed: URL, target: ScoreFormat) -> URL? {
        let env = ProcessInfo.processInfo.environment
        // 自检：位置直接给，不弹面板（`CS_CONVERT_TO=/tmp/xxx.abc`）
        if let forced = env["CS_CONVERT_TO"], !forced.isEmpty {
            return URL(fileURLWithPath: forced)
        }
        let panel = NSSavePanel()
        panel.title = "转出来的 \(target.label) 放哪儿？"
        panel.message = "默认跟原文件放在一起（名字一样，只换后缀）。想放别处，现在挑。"
        panel.nameFieldStringValue = proposed.lastPathComponent
        panel.directoryURL = lastConvertFolder ?? proposed.deletingLastPathComponent()
        if let type = UTType(filenameExtension: target.ext) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        lastConvertFolder = url.deletingLastPathComponent()
        return url
    }

    /// 上一次在「放哪儿」里挑过的文件夹 —— 只记文件夹，不记文件名
    ///（文件名每次都跟着源文件走，记了反而会误导）。
    private var lastConvertFolder: URL? {
        get {
            UserDefaults.standard.string(forKey: "convertFolder")
                .map { URL(fileURLWithPath: $0) }
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: "convertFolder") }
    }

    /// 转一份具体的文件。**不弹面板** —— 自检走的就是这条。
    ///
    /// - Parameters:
    ///   - destination: 转出来的放哪儿。不传就放原文件旁边（老行为）。
    ///   - placeAlreadyConfirmed: 替换确认**是不是已经问过了**（保存面板自己会问
    ///     「是否替换」）—— 问过就别问第二遍。
    func convert(_ file: URL, to target: ScoreFormat, placing destination: URL? = nil,
                 placeAlreadyConfirmed: Bool = false) {
        let produced = file.deletingPathExtension().appendingPathExtension(target.ext)
        let final = destination ?? produced
        let inPlace = final.standardizedFileURL == produced.standardizedFileURL

        // ⚠️ 转换是**覆盖式**的（`abcxml` 的规矩：同目录同名、只换后缀）。
        // 而目标文件很可能是他在 Dorico 里改过的那一份 —— 不能默不作声地抹掉。
        // 只在「真的会被覆盖」的时候问一句，平时不打扰。
        //（放到别处时保存面板已经问过一次，这里不再拦一道）
        let autoYes = ProcessInfo.processInfo.environment["CS_CONVERT_YES"] == "1"
        if inPlace, !placeAlreadyConfirmed, !autoYes,
           FileManager.default.fileExists(atPath: produced.path) {
            let alert = NSAlert()
            alert.messageText = "会覆盖原来那份 \(target.label)"
            alert.informativeText = "\(produced.lastPathComponent) 已经在了。"
                + "\n如果那是你改过的，先按「取消」，把它挪个地方再转。"
            alert.addButton(withTitle: "覆盖它")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        do {
            // 顺序要紧：**先在原位置转、就地贴歌词，最后才搬走**。
            // 反过来（先搬再贴）会让 `attachNoteBeside` 找不到源目录里的 params.json。
            var out = try ScoreFiles.convert(file, to: target)
            let note = attachNoteBeside(file: file, out: out, target: target)
            if !inPlace {
                out = try ScoreFiles.place(out, at: final)
            }
            exportMessage = "转好了：\(out.lastPathComponent)\(whereText(out, source: file))" + note
        } catch {
            exportMessage = error.localizedDescription
            // ★ **失败了必须让他看见。**
            // 由头（2026-10-13）：上面那句提示落在详情区的**最底下** ——
            // 而窗口比内容矮、滚动条停在上面，**他根本看不到**。
            // 于是界面表现成"点了按钮没反应"，他只能自己猜（还猜到"命名太长"上去）。
            // 成功时照旧只放底部那行字（不打扰）；**只在失败时**弹一次。
            let alert = NSAlert()
            alert.messageText = "没能转出来"
            alert.informativeText = error.localizedDescription
                + "\n\n原文件一个字节都没动。这一段可以直接发给我。"
            alert.addButton(withTitle: "知道了")
            alert.runModal()
        }
    }

    /// 一句话说清"转出来的放哪儿了" —— 别把一整条路径摆到他面前。
    private func whereText(_ out: URL, source: URL) -> String {
        let here = source.deletingLastPathComponent().standardizedFileURL
        let there = out.deletingLastPathComponent().standardizedFileURL
        if here == there { return "（跟原文件在同一个文件夹）" }
        return "（放在「\(out.deletingLastPathComponent().lastPathComponent)」里）"
    }

    /// 转成 MusicXML 时，**顺手把歌词贴进转出来的那一份**（用户 2026-10-12 提的）。
    ///
    /// ⚠️ **只认这首自己的 `params.json`**（Composer Step 的产物会把词存在那儿），
    ///    **不回落到歌词框** —— 那两个按钮本来就是"纯粹转格式，不管生成、不看列表"，
    ///    拿框里的词去贴别人家的谱子，只会贴错。
    private func attachNoteBeside(file: URL, out: URL, target: ScoreFormat) -> String {
        guard target == .xml else { return "" }
        let params = file.deletingLastPathComponent().appendingPathComponent("params.json")
        guard let data = try? Data(contentsOf: params),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lyrics = obj["lyrics"] as? String else { return "" }
        let done = ScoreFiles.attachLyrics(to: out, lyrics: lyrics, abc: file)
        return done ? " —— 歌词也贴进谱面了" : ""
    }

    /// 照这份谱子重唱一首：**只把谱子换成导进来的这份**，词与风格用框里现在这份。
    ///
    /// YuE2 那边：给了谱子就照谱子来，不给就自己现想（`cot=full` 的两种走法）。
    ///
    /// ⚠️ **2026-10-12 改了**：原来这里会把词和风格**从"选中那一首"抄回表单**
    ///    （`form.lyrics = item.request.lyrics`）。后果是：用户改了歌词框里的词、
    ///    再导入谱子重唱 —— **他刚改的词被那首的旧词盖掉了**，而且界面上看不出来
    ///    （框里又变回旧词）。手册里写着"换个词再唱就先把歌词改了"，代码却把它盖掉，
    ///    两边还矛盾着。
    ///    ⇒ 现在**只设谱子**，词与风格一律用框里现在这份。
    ///    没改过词的时候行为跟原来**完全一样**（选中某一首时，框里本来就是它的词）。
    ///
    /// ★ **同日再追一条：谱子里带着词就把它读出来用。**
    ///    制谱软件导出的谱子里**本来就写着词**（用户那份 Dorico 分谱里
    ///    `<lyric>` 有 359 个字），而以前导入之后那些词白读 —— 还得人再打一遍。
    ///    现在读出来直接填进歌词框（怎么读见 `ScoreReader.swift`）。
    ///    分寸见 `applyLyricsFromScore`。
    ///
    /// ★★ **2026-10-13 又改一处：不再要求"先在左边选一首"。**
    ///    用户原话：「导入乐谱的时候顺便读一下它的拍号调号歌词音符，
    ///    **不要导入之后还是空 —— 尤其是开空项目写新歌的时候**」。
    ///    原先没有选中就**整条被拒**（只在底部留一句"先在左边选一首"），
    ///    于是**空项目里导入谱子这条路根本走不通**：他只剩"只转格式"一条，
    ///    而那条**一个字都不进表单** ⇒ 导入完界面上还是空的。
    ///    现在分两种：
    ///    · 有选中 → 老行为：立刻照它重唱一首；
    ///    · **没选中（空项目 / 刚按「新建一首」）→ 只把谱子备好、把词填进框、
    ///      把读到的信息摆到界面上，不开跑** —— 让他先看清读进了什么，再按「生成」。
    func resing(with file: URL) {
        engine = .yue2
        form.abcPath = file.path
        // 交给 8001 服务读一遍：手写和弦原样核对、修格式、出条件 JSON。
        // 它是**旁路**：服务没起来或者失败，生成照样能走（原来的路一条没少）。
        analyzeWithSheetSage2(file)

        if let reading = try? ScoreReader.read(file) {
            // ★ 读到的这一份留着给界面用（拍号／调号／速度／音符数／歌词字数）。
            //   以前只往底部的提示行里塞一句 —— 那行在窗口最底下，他看不见。
            scoreReading = reading
            if reading.hasLyrics {
                applyLyricsFromScore(reading, source: file)
            } else {
                exportMessage = "照这份谱子唱 · 谱子里没带词（\(reading.summary)），"
                    + "用的还是框里这份"
                scoreLyricsNote = "这份谱子没带词，用的是你框里这份"
            }
        } else {
            exportMessage = "照这份谱子唱（用歌词框里现在这份词）"
            scoreLyricsNote = "这份谱子读不出歌词，用的是你框里这份"
        }

        // 空项目：**到这儿就停**。谱子备好了、词填上了、信息也摆出来了 ——
        // 按不按「生成」是他的事，不在导入那一刻替他开跑。
        // （上面那些提示会被这一句盖掉没关系：详细信息在谱子那张卡上。）
        guard selectedItem != nil else {
            exportMessage = "谱子读好了，就摆在上面 —— 按「生成」就照它唱"
            return
        }
        generate()
    }

    /// 把谱子里读到的词放进歌词框。
    ///
    /// **不能默默盖掉他刚打的词** —— 2026-10-12 那次翻车正是"代码偷偷把词换了"，
    /// 所以框里已经有词的时候**问一句**。框里空着（或还是 `[Instrumental]`）
    /// 就不用问：没有谁的劳动会被覆盖。
    ///
    /// `CS_SCORE_LYRICS=replace|keep` 是自检用的 —— 弹窗在自检里点不动。
    ///
    /// ★ **2026-10-13 补：这件事得写在明面上。**
    ///   用户原话「把导入乐谱时读到的歌词直接放在歌词栏里，**也可以证明真的读到乐谱内容了**」——
    ///   对：**歌词框里出现他谱子上的词，是最硬的证据**（比卡片上那行读数还硬）。
    ///   ⇒ 每条分支都往 `scoreLyricsNote` 里写一句人话，
    ///   界面那张卡把它摆在**歌词框正上方** —— 框里一变，上面同时说明"这是从谱子里来的"。
    private func applyLyricsFromScore(_ reading: ScoreReading, source: URL) {
        let current = form.lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        let boxEmpty = current.isEmpty || current == "[Instrumental]"

        if let forced = ProcessInfo.processInfo.environment["CS_SCORE_LYRICS"],
           !forced.isEmpty {
            if forced == "keep" {
                exportMessage = "照这份谱子重唱 · 谱子里的词没要（\(reading.summary)）"
                scoreLyricsNote = "这次用的是你框里那份词（谱子只管音）"
            } else {
                form.lyrics = reading.lyricText
                exportMessage = "照这份谱子重唱 · 谱子里的词已填进歌词框（\(reading.summary)）"
                scoreLyricsNote = "谱子里的 \(reading.lyricCount) 个字已经填进下面的歌词框"
            }
            return
        }

        if boxEmpty {
            form.lyrics = reading.lyricText
            exportMessage = "照这份谱子重唱 · 谱子里带着词，已填进歌词框（\(reading.summary)）"
            scoreLyricsNote = "谱子里的 \(reading.lyricCount) 个字已经填进下面的歌词框"
            return
        }

        let alert = NSAlert()
        alert.messageText = "这份谱子里带着歌词"
        alert.informativeText = "\(source.lastPathComponent) 里有 \(reading.lyricCount) 个字。\n\n"
            + "· **用谱子里的词**：歌词框现在这份会被换掉\n"
            + "· **用框里的词**：谱子只管音，词还是现在这份"
        alert.addButton(withTitle: "用谱子里的词")
        alert.addButton(withTitle: "用框里这份词")
        if alert.runModal() == .alertFirstButtonReturn {
            form.lyrics = reading.lyricText
            exportMessage = "照这份谱子重唱 · 词换成谱子里的了（\(reading.summary)）"
            scoreLyricsNote = "词换成谱子里的了（\(reading.lyricCount) 个字）"
        } else {
            exportMessage = "照这份谱子重唱 · 用的还是框里这份词（\(reading.summary)）"
            scoreLyricsNote = "这次用的是你框里那份词（谱子只管音）"
        }
    }
}
