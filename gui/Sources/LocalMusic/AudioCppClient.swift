import AVFoundation
import Foundation

/// audio.cpp（Mac 预编译版）的客户端 —— 只管「找到它、跑一次、把结果拿回来」。
///
/// 背景：灵感路由（MIR）原来自带一套 SheetSage2（Python + MLX，2.6 GB 权重）。
/// 2026-10-24 那套撤了，换成 `audiocpp`：同一件事，**60 秒的歌 25 秒出结果**，
/// 读的还是一份 GGUF（2.7 GB）。MuScriptor 更轻，412 MB，5 秒出六轨 MIDI。
///
/// **不下载、不自带权重。** 程序和模型都是人自己的东西，放在人自己的盘上。
/// 这里只做三件事：去哪儿找、跑一次、找不到时说清楚缺什么。
///
/// ⚠️ 为什么是 `Process` 而不是把模型塞进 Swift：那套推理是 C++/Metal，
///    重新实现没有意义。这个文件只是一层薄壳，**失败了也不能影响原来的生成**。
enum AudioCppClient {

    // MARK: - 配置入口

    /// 用户可以在偏好设置里指一次，之后一直用它。
    /// 键名前缀跟项目别处一致（`cs.` = Composer Step）。
    static let cliDefaultsKey = "cs.audiocpp.cli"
    static let modelsDefaultsKey = "cs.audiocpp.models"

    /// 算一个谱子要多久：4 分钟的歌约 27 秒（实测）。给足十分钟，
    /// 因为首次加载要把 2.7 GB 从盘上读进来 —— 外盘冷的时候确实慢。
    private static let timeout: TimeInterval = 600

    // MARK: - 找到程序

    /// 候选位置，按「越具体越优先」排。
    ///
    /// 最后一个候选是本机工作区的默认位置 —— 它**只在开发机上生效**，
    /// 别人的机器上不存在，找不到就会一直往下走到 `/opt/homebrew/bin`。
    /// 这就是发到 GitHub 时该有的样子：默认值可以是我这台机器的，
    /// 但**别人一改就能用**（偏好设置里填路径）。
    private static var cliCandidates: [URL] {
        var list: [URL] = []
        if let custom = UserDefaults.standard.string(forKey: cliDefaultsKey),
           !custom.isEmpty {
            list.append(URL(fileURLWithPath: custom))
        }
        if let env = ProcessInfo.processInfo.environment["CS_AUDIOCPP_CLI"], !env.isEmpty {
            list.append(URL(fileURLWithPath: env))
        }
        // 跟 app 放在一起（有人喜欢把整包装进同一个文件夹）
        if let res = Bundle.main.resourceURL {
            list.append(res.appendingPathComponent("audiocpp/audiocpp_cli"))
            list.append(res.appendingPathComponent("audiocpp_cli"))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        list.append(home.appendingPathComponent("audiocpp/audiocpp_cli"))
        list.append(URL(fileURLWithPath: "/opt/homebrew/bin/audiocpp_cli"))
        list.append(URL(fileURLWithPath: "/usr/local/bin/audiocpp_cli"))
        // 放哪都行 —— 设 `CS_AUDIOCPP_DIR` 指到那个目录即可（不必写死路径）
        if let dir = ProcessInfo.processInfo.environment["CS_AUDIOCPP_DIR"], !dir.isEmpty {
            list.append(URL(fileURLWithPath: NSString(string: dir).expandingTildeInPath)
                .appendingPathComponent("audiocpp_cli"))
        }
        return list
    }

    static func locateCLI() -> URL? {
        let fm = FileManager.default
        for url in cliCandidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    // MARK: - 找到模型

    /// 模型目录的候选。先看用户指的那个，再看「程序边上」的几种摆法。
    private static func modelDirs(near cli: URL) -> [URL] {
        var list: [URL] = []
        if let custom = UserDefaults.standard.string(forKey: modelsDefaultsKey),
           !custom.isEmpty {
            list.append(URL(fileURLWithPath: custom))
        }
        let dir = cli.deletingLastPathComponent()
        // audiocpp-bin/ 和 audio.cpp/ 并排（本机就是这种摆法）
        list.append(dir.deletingLastPathComponent().appendingPathComponent("audio.cpp/models"))
        list.append(dir.appendingPathComponent("models"))
        list.append(dir.deletingLastPathComponent().appendingPathComponent("models"))
        let home = FileManager.default.homeDirectoryForCurrentUser
        list.append(home.appendingPathComponent("audiocpp/models"))
        return list
    }

    /// 在模型目录里找一个族的 `.gguf`（会往下钻一层：`models/SheetSage2/*.gguf`）。
    private static func findModel(_ family: String, near cli: URL) -> URL? {
        let fm = FileManager.default
        for base in modelDirs(near: cli) {
            let direct = base.appendingPathComponent(family)
            if let hit = firstGGUF(in: direct, fm) { return hit }
            for entry in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            where entry.lastPathComponent.lowercased().hasPrefix(family.lowercased()) {
                if let hit = firstGGUF(in: entry, fm) { return hit }
            }
        }
        return nil
    }

    private static func firstGGUF(in dir: URL, _ fm: FileManager) -> URL? {
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        // 优先非分片的那一份（本机叫 `sheetsage2-orig.gguf`）
        let ggufs = files.filter { $0.pathExtension.lowercased() == "gguf" }
        return ggufs.first { !$0.lastPathComponent.contains("-0000") } ?? ggufs.first
    }

    /// 找**目录型**模型（htdemucs 是 `manifest.json` + 子目录，Qwen3-ASR 是一堆 json）。
    /// `marker` 用来确认"这个目录真的是那个模型"，不是同名的空壳。
    private static func findModelDir(_ name: String, marker: String, near cli: URL) -> URL? {
        let fm = FileManager.default
        for base in modelDirs(near: cli) {
            let dir = base.appendingPathComponent(name)
            if fm.fileExists(atPath: dir.appendingPathComponent(marker).path) { return dir }
        }
        return nil
    }

    // MARK: - 能不能用

    struct Status {
        var cli: URL?
        var sheetSage2: URL?
        var muscriptor: URL?
        /// 拆人声（htdemucs）与认歌词（Qwen3-ASR）——都是**目录**，不是单个 gguf。
        var htdemucs: URL?
        var qwen3Asr: URL?
        /// 德语专用：CrisperWhisper（单文件 gguf）。它逐字转写、不乱编，
        /// 但要求 16 kHz 输入，而且**只该给德语用**（中文英文用 Qwen3 更快更稳）。
        var crisperwhisper: URL?
        /// 强制对齐器：给歌词每个字打时间（Qwen3-ForcedAligner）。
        var forcedAligner: URL?

        var canTranscribeToScore: Bool { cli != nil && sheetSage2 != nil }
        var canTranscribeToMIDI: Bool { cli != nil && muscriptor != nil }
        var canTranscribeLyrics: Bool { cli != nil && htdemucs != nil && qwen3Asr != nil }
        var canTranscribeGerman: Bool { canTranscribeLyrics && crisperwhisper != nil }

        /// 一句人话，直接摆在按钮底下。
        var human: String {
            if cli == nil {
                return "没找到 audio.cpp 的程序（audiocpp_cli）。装上之后在偏好设置里指一下路径。"
            }
            if sheetSage2 == nil && muscriptor == nil && htdemucs == nil {
                return "找到程序了，但没找到 SheetSage2、MuScriptor 或 htdemucs 的模型文件。"
            }
            var bits: [String] = []
            if sheetSage2 != nil { bits.append("出谱") }
            if muscriptor != nil { bits.append("出 MIDI") }
            if canTranscribeLyrics { bits.append(canTranscribeGerman ? "扒歌词（含德语）" : "扒歌词") }
            return "音频转谱已就绪（\(bits.joined(separator: " / "))）"
        }
    }

    static func status() -> Status {
        let cli = locateCLI()
        guard let cli else { return Status() }
        return Status(cli: cli,
                      sheetSage2: findModel("SheetSage2", near: cli),
                      muscriptor: findModel("MuScriptor", near: cli),
                      htdemucs: findModelDir("htdemucs", marker: "manifest.json", near: cli),
                      qwen3Asr: findModelDir("Qwen3-ASR-0.6B", marker: "config.json", near: cli),
                      crisperwhisper: findModel("CrisperWhisper", near: cli),
                      forcedAligner: findModelDir("Qwen3-ForcedAligner-0.6B",
                                                  marker: "config.json", near: cli))
    }

    // MARK: - 干活

    enum Failure: LocalizedError {
        case notInstalled(String)
        case needsConversion(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let why):    return why
            case .needsConversion(let why): return "这段音频转不了：\(why)"
            case .failed(let why):          return "识谱没成功：\(why)"
            }
        }
    }

    /// 音频 → ABC 草谱。返回 ABC 文本。
    ///
    /// 产物先落在 `output` 给的路径上；调用方拿到文本后可以再交给
    /// 8001 服务规范化（那句「旧服务负责把草稿理干净」）。
    static func transcribeToScore(audio: URL, output: URL) async throws -> String {
        let status = status()
        guard let cli = status.cli, let model = status.sheetSage2 else {
            throw Failure.notInstalled(status.human)
        }
        let prepared = try prepareAudio(audio)
        // 只删**自己转出来的**临时文件；原文件是用户的，一个字都不能动
        defer { if prepared.temporary { try? FileManager.default.removeItem(at: prepared.url) } }

        let result = try await run(cli, [
            "--task", "midi",
            "--family", "sheetsage2",
            "--model", model.path,
            "--backend", "metal",
            "--audio", prepared.url.path,
            "--text-out", output.path
        ])
        guard result.code == 0, let text = try? String(contentsOf: output, encoding: .utf8),
              !text.isEmpty else {
            throw Failure.failed("没写出谱子（退出码 \(result.code)）。\(result.tail)")
        }
        return text
    }

    /// 把听出来的原始 ABC 整理成 YuE2 认的双行谱（Vocal + Ins）。
    ///
    /// 2026-10-26 实验：旋律进 Vocal，和弦根音进 Ins。
    /// 脚本和谱面工作室共用一份：`scripts/abc_two_voices.py`。
    static func buildTwoVoices(from abc: URL, to out: URL) -> Bool {
        let script = BackendClient.locateRoot().appendingPathComponent("scripts/abc_two_voices.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script.path, abc.path, out.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
            && FileManager.default.fileExists(atPath: out.path)
    }

    /// 音频 → MIDI（按乐器分轨：人声 / 吉他 / 贝斯 / 鼓 / 钢琴……）。
    ///
    /// `instruments` 空 = 让它自己判断（默认，也是平时的用法）；
    /// 非空 = **只出这几样** —— 2026-10-29 加的「改改乐器」走这条。
    /// 传的是 `MuScriptorInstrument.key`，落到 `--request-option instruments=`。
    ///
    /// 返回值是**它实际写进 MIDI 的乐器**（英文 key，去重、保持出现顺序）。
    /// 界面拿它给勾选清单做预选 —— 以文件里真有的为准，别拿我们的猜测当事实。
    @discardableResult
    static func transcribeToMIDI(audio: URL,
                                 output: URL,
                                 instruments: [String] = [],
                                 eventsOut: URL? = nil) async throws -> [String] {
        let status = status()
        guard let cli = status.cli, let model = status.muscriptor else {
            throw Failure.notInstalled(status.human)
        }
        let prepared = try prepareAudio(audio)
        // 同上：原文件不能删
        defer { if prepared.temporary { try? FileManager.default.removeItem(at: prepared.url) } }

        var args = [
            "--task", "midi",
            "--family", "muscriptor",
            "--model", model.path,
            "--backend", "metal",
            "--audio", prepared.url.path,
            "--out", output.path
        ]
        if !instruments.isEmpty {
            args.append("--request-option")
            args.append("instruments=" + instruments.joined(separator: ","))
        }
        if let eventsOut {
            args.append("--text-out")
            args.append(eventsOut.path)
        }

        let result = try await run(cli, args)
        guard result.code == 0, FileManager.default.fileExists(atPath: output.path) else {
            throw Failure.failed("没写出 MIDI（退出码 \(result.code)）。\(result.tail)")
        }
        guard let eventsOut, let data = try? Data(contentsOf: eventsOut) else { return [] }
        return instrumentsUsed(in: data)
    }

    /// 从事件 JSON 里挑出用过哪些乐器。
    ///
    /// 顶层可能是数组（本机 CLI 就是这样），也可能包一层 —— 两种都认。
    /// 只看 `type == "start"` 的事件，按 `instrument` 去重、保留首次出现的顺序。
    private static func instrumentsUsed(in json: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: json) else { return [] }
        let events: [[String: Any]]
        if let list = object as? [[String: Any]] {
            events = list
        } else if let dict = object as? [String: Any],
                  let list = dict["events"] as? [[String: Any]] {
            events = list
        } else {
            return []
        }
        var seen: Set<String> = []
        var ordered: [String] = []
        for event in events where (event["type"] as? String) == "start" {
            guard let key = event["instrument"] as? String, !key.isEmpty else { continue }
            if seen.insert(key).inserted { ordered.append(key) }
        }
        return ordered
    }

    // MARK: - 扒歌词（拆人声 + 识别）

    /// 一首歌 → 歌词。先拆人声，再认字；**按语言自动分工**：
    ///
    ///   ① 一律先用 Qwen3-ASR 认一遍（快，中文英文都够用）；
    ///   ② 认出来看着像德语 → 换成 CrisperWhisper 重认一遍。
    ///      原因是实测：同样一段 Gedda 唱的施特劳斯，Qwen3 会把听不清的地方
    ///      **编成通顺的德语**（“Love,” 这种英文词都插进来了），
    ///      而 CrisperWhisper 给碎片、还标犹豫音 —— 后者不好看但诚实。
    ///   ③ 其它语言用第 ① 步的结果。
    ///
    /// 2026-10-27 实测：3 分半的歌，拆人声约 40 秒、Qwen3 认字约 16 秒、
    /// Whisper 重认约 30 秒（9 分钟的曲子 Whisper 约 70 秒）。
    static func transcribeLyrics(audio: URL, outDir: URL) async throws -> String {
        let status = status()
        guard let cli = status.cli, let sep = status.htdemucs, let asr = status.qwen3Asr else {
            throw Failure.notInstalled(status.human)
        }
        let prepared = try prepareAudio44k(audio)
        // 同上：只删自己转出来的那份
        defer { if prepared.temporary { try? FileManager.default.removeItem(at: prepared.url) } }

        let stems = outDir.appendingPathComponent("人声分离")
        try? FileManager.default.createDirectory(at: stems, withIntermediateDirectories: true)

        let sepResult = try await run(cli, [
            "--task", "sep",
            "--family", "htdemucs",
            "--model", sep.path,
            "--backend", "metal",
            "--audio", prepared.url.path,
            "--out-dir", stems.path
        ])
        let vocals = stems.appendingPathComponent("vocals.wav")
        guard sepResult.code == 0,
              FileManager.default.fileExists(atPath: vocals.path) else {
            throw Failure.failed("拆人声没成功（退出码 \(sepResult.code)）。\(sepResult.tail)")
        }

        // ① 先用快的那个认一遍
        let quickLog = try await runText(cli, [
            "--task", "asr",
            "--family", "qwen3_asr",
            "--model", asr.path,
            "--backend", "metal",
            "--audio", vocals.path
        ])
        var text = extractText(from: quickLog)
        guard !text.isEmpty else {
            throw Failure.failed("认不出字来。换一首人声更清楚的再试。")
        }

        // ② 看着像德语 → 换 Whisper 重认
        if !shouldStayWithQwen(text), let whisper = status.crisperwhisper {
            let prepared16 = try prepareAudio16k(vocals)
            defer { if prepared16.temporary { try? FileManager.default.removeItem(at: prepared16.url) } }
            let log = try await runText(cli, [
                "--task", "asr",
                "--family", "crisperwhisper",
                "--model", whisper.path,
                "--backend", "metal",
                "--audio", prepared16.url.path
            ])
            let verbatim = tidyVerbatim(extractText(from: log))
            if !verbatim.isEmpty { text = verbatim }
        }

        let out = outDir.appendingPathComponent("歌词.txt")
        try? text.write(to: out, atomically: true, encoding: .utf8)

        // ③ 顺手给每个字打上时间。对齐器一次只吃 30 秒，所以按 25 秒分段。
        _ = await autoSegmentAlign(vocals: vocals, outDir: outDir)
        return text
    }

    /// 一个字的起止（秒）。
    struct AlignedWord: Codable {
        let word: String
        let start: Double
        let end: Double
    }

    /// 按「呼吸」找句子边界：算人声轨的电平，安静下来的地方就是一句的尽头。
    ///
    /// 为什么不用谱子里的休止：谱上的休止是写出来的，歌手的呼吸才是真发生的。
    /// 2026-10-27 实测（AI 生成的一首 72 秒歌）：静音检测给出四段，
    /// 和四句词一一对上，时间也全对；同期拿谱子切，切在「山岗溪 / 水慢慢」这种字中间。
    ///
    /// 所以：**音频说哪儿停，就哪儿停。**
    static func silenceSegments(audio: URL, thresholdDB: Double = -35,
                                minSilence: Double = 0.35,
                                mergeGap: Double = 0.8) -> [(Double, Double)] {
        guard let f = try? AVAudioFile(forReading: audio) else { return [] }
        let format = f.processingFormat
        let sr = format.sampleRate
        let total = AVAudioFrameCount(f.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else { return [] }
        guard (try? f.read(into: buf)) != nil, let data = buf.floatChannelData else { return [] }

        let channels = Int(format.channelCount)
        let frames = Int(buf.frameLength)
        let hop = 1024
        let threshold = pow(10.0, thresholdDB / 20.0)

        // 每 hop 帧算一个 RMS，得到一个"有声/无声"序列
        var marks: [(Double, Bool)] = []
        var i = 0
        while i < frames {
            let n = min(hop, frames - i)
            var sum = 0.0
            for c in 0..<channels {
                let p = data[c]
                for k in 0..<n { let v = Double(p[i + k]); sum += v * v }
            }
            let rms = sqrt(sum / Double(n * channels))
            marks.append((Double(i) / sr, rms > threshold))
            i += hop
        }

        // 合成有声段
        var voiced: [(Double, Double)] = []
        var start: Double? = nil
        for (time, loud) in marks {
            if loud, start == nil { start = time }
            if !loud, let s = start {
                if time - s > minSilence { voiced.append((s, time)) }
                start = nil
            }
        }
        if let s = start, Double(frames) / sr - s > minSilence {
            voiced.append((s, Double(frames) / sr))
        }

        // 短的间隙（换气）不算句界，合并
        var merged: [(Double, Double)] = []
        for seg in voiced {
            if let last = merged.last, seg.0 - last.1 < mergeGap {
                merged[merged.count - 1] = (last.0, seg.1)
            } else {
                merged.append(seg)
            }
        }
        return merged
    }

    /// 按句对齐：词按行/标点切句，音频按静音切段，一句对一段。
    ///
    /// 这一步**不跑识别**（词是你给的），所以快：一首 72 秒的歌只花十几秒。
    /// 段和句数目不一致时，按顺序把多出来的句子并到最近的一段里 —— 宁可靠后，
    /// 也不硬拆。
    static func alignBySentence(text: String, vocals: URL, outDir: URL) async -> [AlignedWord] {
        let st = status()
        guard let cli = st.cli, let aligner = st.forcedAligner else { return [] }
        let lang = alignLanguage(text) ?? "zh"

        // 切句：先按换行，再按中文句读
        var lines = text.split(whereSeparator: { $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.count <= 1 {
            lines = text.split(whereSeparator: { "。！？!?；;".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        let segs = silenceSegments(audio: vocals)
        guard !segs.isEmpty, !lines.isEmpty else { return [] }

        // 段与句配对
        var pairs: [((Double, Double), String)] = []
        if segs.count == lines.count {
            pairs = Array(zip(segs, lines))
        } else {
            let n = min(segs.count, lines.count)
            for i in 0..<n { pairs.append((segs[i], lines[i])) }
            if lines.count > segs.count, let last = segs.last {
                pairs[pairs.count - 1] = (last, lines[(segs.count - 1)...].joined())
            }
        }

        var words: [AlignedWord] = []
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sent-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let src = try? AVAudioFile(forReading: vocals) else { return [] }

        for (seg, line) in pairs {
            guard src.framePosition != 0 || seg.0 < 0.01 || true else { continue }
            src.framePosition = AVAudioFramePosition(seg.0 * src.processingFormat.sampleRate)
            let count = AVAudioFrameCount((seg.1 - seg.0) * src.processingFormat.sampleRate)
            guard let piece = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: count),
                  (try? src.read(into: piece, frameCount: count)) != nil else { continue }
            if let out = try? AVAudioFile(forWriting: tmp, settings: src.processingFormat.settings) {
                try? out.write(from: piece)
            }
            let log = (try? await runText(cli, [
                "--task", "align", "--family", "qwen3_forced_aligner",
                "--model", aligner.path, "--backend", "metal",
                "--audio", tmp.path, "--text", line, "--language", lang
            ])) ?? ""
            guard let l = log.split(separator: "\n").first(where: { $0.hasPrefix("word_timestamps=") }) else { continue }
            let payload = String(l.dropFirst("word_timestamps=".count))
            struct Raw: Decodable { let start_sample: Int; let end_sample: Int; let word: String }
            guard let d = payload.data(using: .utf8),
                  let raw = try? JSONDecoder().decode([Raw].self, from: d) else { continue }
            let rate = src.processingFormat.sampleRate
            words += raw.map { AlignedWord(word: $0.word,
                                           start: Double($0.start_sample) / rate + seg.0,
                                           end: Double($0.end_sample) / rate + seg.0) }
        }

        guard !words.isEmpty else { return [] }
        if let enc = try? JSONEncoder().encode(words), let s = String(data: enc, encoding: .utf8) {
            try? s.write(to: outDir.appendingPathComponent("歌词对齐.json"),
                         atomically: true, encoding: .utf8)
        }
        let linesOut = words.map { String(format: "%7.2f  %@", $0.start, $0.word) }
        try? linesOut.joined(separator: "\n").write(to: outDir.appendingPathComponent("歌词时间.txt"),
                                                    atomically: true, encoding: .utf8)
        return words
    }

    /// 自动分段对齐：把干声按 25 秒切开，每段自己认字、再对时间，最后拼起来。
    ///
    /// 为什么要切：Qwen3 的对齐器一次只吃三十秒，
    /// 整首会直接报 `audio encoder token count exceeds max_source_positions`。
    /// 分段还有个好处 —— 一段里错了，不会把后面整片带歪。
    static func autoSegmentAlign(vocals: URL, outDir: URL) async -> [AlignedWord] {
        let st = status()
        guard let cli = st.cli, let asr = st.qwen3Asr, let aligner = st.forcedAligner else { return [] }
        guard let inFile = try? AVAudioFile(forReading: vocals) else { return [] }
        let format = inFile.processingFormat
        let segSeconds = 25.0
        let segFrames = AVAudioFrameCount(segSeconds * format.sampleRate)
        guard let segBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: segFrames) else { return [] }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("align-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var words: [AlignedWord] = []
        var offset = 0.0
        var index = 0
        while inFile.framePosition < inFile.length {
            segBuf.frameLength = 0
            do { try inFile.read(into: segBuf, frameCount: segFrames) } catch { break }
            if segBuf.frameLength == 0 { break }

            let segURL = tmp.appendingPathComponent("seg\(index).wav")
            if let out = try? AVAudioFile(forWriting: segURL, settings: format.settings) {
                try? out.write(from: segBuf)
            }
            index += 1
            let segDuration = Double(segBuf.frameLength) / format.sampleRate

            // 这一段自己认字
            let asrLog = (try? await runText(cli, [
                "--task", "asr", "--family", "qwen3_asr",
                "--model", asr.path, "--backend", "metal",
                "--audio", segURL.path
            ])) ?? ""
            let segText = extractText(from: asrLog)
            if !segText.isEmpty, let lang = alignLanguage(segText) {
                let alignLog = (try? await runText(cli, [
                    "--task", "align", "--family", "qwen3_forced_aligner",
                    "--model", aligner.path, "--backend", "metal",
                    "--audio", segURL.path, "--text", segText, "--language", lang
                ])) ?? ""
                if let line = alignLog.split(separator: "\n").first(where: { $0.hasPrefix("word_timestamps=") }) {
                    let payload = String(line.dropFirst("word_timestamps=".count))
                    struct Raw: Decodable { let start_sample: Int; let end_sample: Int; let word: String }
                    if let data = payload.data(using: .utf8),
                       let raw = try? JSONDecoder().decode([Raw].self, from: data) {
                        let sr = format.sampleRate
                        words += raw.map { AlignedWord(word: $0.word,
                                                       start: Double($0.start_sample) / sr + offset,
                                                       end: Double($0.end_sample) / sr + offset) }
                    }
                }
            }
            offset += segDuration
        }

        guard !words.isEmpty else { return [] }
        if let encoded = try? JSONEncoder().encode(words),
           let jsonText = String(data: encoded, encoding: .utf8) {
            try? jsonText.write(to: outDir.appendingPathComponent("歌词对齐.json"),
                                atomically: true, encoding: .utf8)
        }
        let lines = words.map { String(format: "%7.2f  %@", $0.start, $0.word) }
        try? lines.joined(separator: "\n").write(to: outDir.appendingPathComponent("歌词时间.txt"),
                                                atomically: true, encoding: .utf8)
        return words
    }

    /// 歌词 → 每字时间。跑 Qwen3-ForcedAligner，结果写 `歌词对齐.json` / `歌词时间.txt`。
    ///
    /// 只对能判定的语言做（中/英/俄）；别的语言对齐器不认，直接跳过，不报错。
    static func alignWords(text: String, vocals: URL, outDir: URL) async -> [AlignedWord] {
        let st = status()
        guard let cli = st.cli, let aligner = st.forcedAligner,
              let lang = alignLanguage(text) else { return [] }
        let log = (try? await runText(cli, [
            "--task", "align",
            "--family", "qwen3_forced_aligner",
            "--model", aligner.path,
            "--backend", "metal",
            "--audio", vocals.path,
            "--text", text,
            "--language", lang
        ])) ?? ""
        guard let line = log.split(separator: "\n").first(where: { $0.hasPrefix("word_timestamps=") }) else {
            return []
        }
        let payload = String(line.dropFirst("word_timestamps=".count))
        struct Raw: Decodable {
            let start_sample: Int
            let end_sample: Int
            let word: String
        }
        guard let data = payload.data(using: .utf8),
              let raw = try? JSONDecoder().decode([Raw].self, from: data) else { return [] }
        let sr = 44100.0
        let words = raw.map { AlignedWord(word: $0.word,
                                          start: Double($0.start_sample) / sr,
                                          end: Double($0.end_sample) / sr) }

        // 写两份：JSON（给程序用）、文本（给人看）
        if let encoded = try? JSONEncoder().encode(words),
           let jsonText = String(data: encoded, encoding: .utf8) {
            try? jsonText.write(to: outDir.appendingPathComponent("歌词对齐.json"),
                                atomically: true, encoding: .utf8)
        }
        let lines = words.map { String(format: "%7.2f  %@", $0.start, $0.word) }
        try? lines.joined(separator: "\n").write(to: outDir.appendingPathComponent("歌词时间.txt"),
                                                atomically: true, encoding: .utf8)
        return words
    }

    /// 对齐器只认几门语言，这里按文字特征给一个。
    static func alignLanguage(_ text: String) -> String? {
        let total = text.filter { !$0.isWhitespace }.count
        guard total > 0 else { return nil }
        let han = text.filter { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }.count
        if Double(han) / Double(total) > 0.2 { return "zh" }
        let cyr = text.filter { "абвгдеёжзийклмнопрстуфхцчшщъыьэюя".contains($0) }.count
        if Double(cyr) / Double(total) > 0.2 { return "ru" }
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let en = Set(["the", "and", "to", "of", "a", "in", "you", "that", "it", "is",
                      "was", "for", "on", "with", "as", "at", "by", "from", "or", "an",
                      "be", "this", "have", "not", "are", "but", "they", "we", "i", "my"])
        if !words.isEmpty, Double(words.filter { en.contains($0) }.count) / Double(words.count) > 0.12 {
            return "en"
        }
        return nil
    }

    /// 从 CLI 的整份日志里抠出 `text_output=` 那一段（可能是多行）。
    private static func extractText(from log: String) -> String {
        var text = ""
        var collecting = false
        for raw in log.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("text_output=") {
                text += line.dropFirst("text_output=".count)
                collecting = true
            } else if collecting,
                      !line.hasPrefix("family="), !line.hasPrefix("task="),
                      !line.hasPrefix("mode="), !line.hasPrefix("ggml"),
                      !line.hasPrefix("audio_out") {
                text += line
            } else if line.isEmpty {
                collecting = false
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 判断"这段话留在 Qwen3 就行，还是要换 Whisper 重认"。
    ///
    /// 2026-10-27 一首一首试出来的分工（不是照语言表推的）：
    ///   · 中文、英文 → Qwen3（英文那首《People》只错几个同音词）
    ///   · 俄语 → Qwen3（格林卡《我记得那美妙的一瞬》，六七成；Whisper 只吐 [UM]）
    ///   · 挪威/丹麦/瑞典语 → Whisper（格里格《En Drøm》首句只错一个词）
    ///   · 德语 → Whisper（施特劳斯《小夜曲》，碎片但诚实）
    ///   · 西班牙语 → Whisper（Turina 那首，整句都对；Qwen3 却跑成意大利语+法语）
    ///
    /// 所以规则很简单：**只认中文、英文、俄语留在 Qwen3，其余一律交给 Whisper。**
    /// 宁可多跑一遍（约半分钟），也不要让 Qwen3 用相近的语言硬猜。
    static func shouldStayWithQwen(_ text: String) -> Bool {
        let total = text.filter { !$0.isWhitespace && !$0.isPunctuation }.count
        guard total > 20 else { return true }

        // 中文
        let han = text.filter { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }.count
        if Double(han) / Double(total) > 0.2 { return true }

        // 俄语（西里尔）
        let cyr = text.filter { "абвгдеёжзийклмнопрстуфхцчшщъыьэюя".contains($0) }.count
        if Double(cyr) / Double(total) > 0.2 { return true }

        // 英文：高频虚词命中率
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !words.isEmpty else { return true }
        let en = Set(["the", "and", "to", "of", "a", "in", "you", "that", "it", "is",
                      "was", "for", "on", "with", "as", "at", "by", "from", "or", "an",
                      "be", "this", "have", "not", "are", "but", "they", "we", "i", "my"])
        let hits = words.filter { en.contains($0) }.count
        return Double(hits) / Double(words.count) > 0.12
    }

    /// CrisperWhisper 是"逐字"模式：全小写、带 `[UM] [UH]` 这类犹豫音。
    /// 去掉标记、按句子把首字母提起来，读起来才像歌词。
    static func tidyVerbatim(_ text: String) -> String {
        var s = text
        for mark in ["[UM]", "[UH]", "[um]", "[uh]", "[UM.]", "[UH.]"] {
            s = s.replacingOccurrences(of: mark, with: "")
        }
        s = s.replacingOccurrences(of: "  ", with: " ")
        var out = ""
        var upperNext = true
        for ch in s {
            if upperNext, ch.isLetter {
                out.append(Character(ch.uppercased()))
                upperNext = false
            } else {
                out.append(ch)
                if ".!?".contains(ch) { upperNext = true }
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 音频先统一成 48k 立体声 wav

    /// 用系统自带的 AVFoundation 转，不依赖 ffmpeg。
    ///
    /// 为什么非要转：这两个模型的入口要的是 wav 数据，而用户手里可能是
    /// mp3 / m4a / flac。让 AVFoundation 读、写成 wav，比要求人先装 ffmpeg 干净。
    ///
    /// ⚠️⚠️ **返回值里的 `temporary` 一定要看**：叫它的人跑完会删掉临时文件，
    /// 而"已经是 wav"这一支**用的是原文件**。2026-10-24 就因为这个删过用户的音频 ——
    /// 清理时把源文件当临时文件删了（实测丢了两个 10-16 的实验产物）。
    /// 所以这里明确告诉调用方"这个能删、那个不能删"。
    private static func prepareAudio(_ source: URL) throws -> (url: URL, temporary: Bool) {
        // 已经是 wav 就原样用，省掉一次转码 —— **但绝不能删**
        if source.pathExtension.lowercased() == "wav" { return (source, false) }

        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiocpp-in-\(UUID().uuidString).wav")
        do {
            let inFile = try AVAudioFile(forReading: source)
            let format = inFile.processingFormat
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(inFile.length)) else {
                throw Failure.needsConversion("这份音频读不进内存")
            }
            try inFile.read(into: buffer)

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let outFile = try AVAudioFile(forWriting: target, settings: settings)
            try outFile.write(from: buffer)
            return (target, true)
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.needsConversion(error.localizedDescription)
        }
    }

    /// 专给「拆人声」用的转码：**固定 44.1 kHz / 立体声 / 16 bit**。
    ///
    /// htdemucs 的入口就是 44.1k（它训练时的采样率），喂 48k 要么报错、
    /// 要么悄悄重采样后出怪声。所以这里不复用 prepareAudio —— 那个保原采样率。
    ///
    /// 写法说明（两次踩坑换来的）：
    ///   ① 分块循环 + 每次 new 一个 converter 回调，第二轮起输出是 0 帧 ——
    ///      AVAudioConverter 会把 endOfStream 记住，后面对同一个实例就不干活了。
    ///   ② 所以改成一口气读进内存、转一次。3 分钟的歌约 150 MB 内存，可以接受。
    private static func prepareAudio44k(_ source: URL) throws -> (url: URL, temporary: Bool) {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrics-in-\(UUID().uuidString).wav")
        do {
            let inFile = try AVAudioFile(forReading: source)
            let inFormat = inFile.processingFormat
            guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2),
                  let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
                throw Failure.needsConversion("这份音频转不了 44.1k")
            }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let outFile = try AVAudioFile(forWriting: target, settings: settings)

            let frames = AVAudioFrameCount(inFile.length)
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else {
                throw Failure.needsConversion("这份音频太大，读不进内存")
            }
            try inFile.read(into: inBuf)

            let ratio = 44100.0 / inFormat.sampleRate
            let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 8192
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else {
                throw Failure.needsConversion("这份音频太大，转不了")
            }
            var convError: NSError?
            var supplied = false
            converter.convert(to: outBuf, error: &convError) { _, status in
                if supplied {
                    status.pointee = .endOfStream
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return inBuf
            }
            if let convError { throw Failure.needsConversion(convError.localizedDescription) }
            try outFile.write(from: outBuf)
            return (target, true)
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.needsConversion(error.localizedDescription)
        }
    }

    /// 给 CrisperWhisper 用的 16 kHz 单声道转码（它自己不做重采样）。
    private static func prepareAudio16k(_ source: URL) throws -> (url: URL, temporary: Bool) {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrics-16k-\(UUID().uuidString).wav")
        do {
            let inFile = try AVAudioFile(forReading: source)
            let inFormat = inFile.processingFormat
            guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
                  let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
                throw Failure.needsConversion("这份音频转不了 16k")
            }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let outFile = try AVAudioFile(forWriting: target, settings: settings)
            let frames = AVAudioFrameCount(inFile.length)
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else {
                throw Failure.needsConversion("这份音频太大，读不进内存")
            }
            try inFile.read(into: inBuf)
            let ratio = 16000.0 / inFormat.sampleRate
            let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 8192
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else {
                throw Failure.needsConversion("这份音频太大，转不了")
            }
            var convError: NSError?
            var supplied = false
            converter.convert(to: outBuf, error: &convError) { _, st in
                if supplied { st.pointee = .endOfStream; return nil }
                supplied = true
                st.pointee = .haveData
                return inBuf
            }
            if let convError { throw Failure.needsConversion(convError.localizedDescription) }
            try outFile.write(from: outBuf)
            return (target, true)
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.needsConversion(error.localizedDescription)
        }
    }

    // MARK: - 跑一条命令

    struct RunResult {
        var code: Int32
        /// 日志最后几行。**失败时必须带上** —— 否则界面上只剩「退出码 1」，
        /// 人不知道是音频没找到、还是模型没读到（2026-10-24 真踩到过：
        /// 测试音频被删了，界面却说"没写出 MIDI"）。
        var tail: String
    }

    /// 跑一次，等它结束。输出**不往内存里收**（那几个模型会打几百 KB 的 JSON），
    /// 一律丢进临时文件 —— 收进 Pipe 又不读，进程会卡死在那儿。
    private static func run(_ cli: URL, _ args: [String]) async throws -> RunResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = cli
            process.arguments = args

            let logURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("audiocpp-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try? FileHandle(forWritingTo: logURL)
            process.standardOutput = log ?? FileHandle.nullDevice
            process.standardError = log ?? FileHandle.nullDevice

            // 两处都可能 resume：正常结束、超时 terminate。用锁保证只 resume 一次。
            let lock = NSLock()
            var finished = false
            func finish(_ result: Result<RunResult, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                try? log?.close()
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            process.terminationHandler = { proc in
                finish(.success(RunResult(code: proc.terminationStatus,
                                          tail: logTail(logURL))))
            }

            do {
                try process.run()
            } catch {
                finish(.failure(Failure.failed("程序起不来：\(error.localizedDescription)")))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                    finish(.success(RunResult(code: -1,
                                              tail: "十分钟还没跑完，已经把它停了。")))
                }
            }
        }
    }

    /// 跑一次，把**整份输出**带回来（只为认歌词：结果在 stdout 的 text_output 里）。
    private static func runText(_ cli: URL, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = cli
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let lock = NSLock()
            var finished = false
            var data = Data()

            func finish(_ result: Result<String, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                switch result {
                case .success(let text): continuation.resume(returning: text)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            process.terminationHandler = { _ in
                data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                finish(.success(String(data: data, encoding: .utf8) ?? ""))
            }
            do { try process.run() } catch {
                finish(.failure(Failure.failed("程序起不来：\(error.localizedDescription)")))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                    finish(.success(""))
                }
            }
        }
    }

    /// 取日志最后三行（去掉空行）。读不到就返回空串，不抛错。
    private static func logTail(_ url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(3).joined(separator: " / ")
    }
}
