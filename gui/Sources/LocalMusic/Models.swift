import Foundation
import SwiftUI

/// 一次生成任务的全部输入。字段名与 render_adapter.sh 读的参数 JSON 一致，
/// Composer Assistant 将来调用同一个脚本时也用这套字段。
struct GenerationRequest: Codable, Equatable {
    var prompt: String = ""
    var lyrics: String = "[Instrumental]"
    var mode: String = "generate"          // generate | repaint | reference
    var duration: Double = 60
    var bpm: Int? = nil
    var keyscale: String = ""
    var steps: Int = 8
    /// 种子。**默认 42**（用户 2026-10-20 定的：照谱唱实验里 42 这一版
    /// 从第一个字就接住了；-1 = 每回随机，容易"进错门"）。
    /// 同 seed 输出逐字节相同，所以这个默认值也让结果**可复现**。
    var seed: Int = 42
    var thinking: Bool = false
    var language: String = "unknown"
    var refAudio: String = ""
    var srcAudio: String = ""
    var repaintStart: Int = 0
    var repaintEnd: Int = -1
    var coverStrength: Double = 0.5
    /// 用哪台引擎出这一首：`acestep` = Composer Step 自己，`yue2` = YuE2。
    ///
    /// 界面拿它选后端脚本（`render_adapter.sh` / `yue2_adapter.sh`）——
    /// 两条脚本是同一套契约（params.json 进、progress.json 出），
    /// 所以这一层只换一个名字，其余流程一个字都不用动。
    ///
    /// 2026-10-12 加。老任务没有这个字段，解码时按 `acestep` 兜底。
    var engine: String = "acestep"
    /// 这一首叫什么。**只用来命名文件**（目录名和 wav 名都取它）。
    ///
    /// 为什么要单独存一份而不是让脚本自己从歌词算：命名的规则只想有一处。
    /// 界面按「歌词首行 → 风格描述」算出名字，顺手写进 params.json；
    /// 脚本拿到什么就用什么。老任务没这个字段，脚本会退回用风格描述。
    var title: String = ""
    /// 外面拿进来的一份谱子（ABC 或 MusicXML）的**绝对路径** —— 意思是「照这份谱子来」。
    ///
    /// 用途：YuE2 那条路默认自己现想一份谱子；给它这一份，它就按你的谱子出歌。
    /// 于是「YuE2 出谱 → 进 Dorico 改 → 送回 YuE2 重唱」这条来回才闭合
    ///（2026-10-12 用户提的：导进来接着打磨）。
    /// ACE-Step 那条路不认这个字段，传进去它也不看。
    var abcPath: String = ""
    /// 「契约版」的谱（2026-11-08）：一份**已经是 YuE2 原生写法**的 ABC 的绝对路径。
    ///
    /// 为什么跟 `abcPath` 分开：`abcPath` 那条路会过 `prepare_score.py`，而它只取人声那条
    /// part、把器乐行写成整小节休止 —— 等于把「契约版」要的那条线抹掉。
    /// 这个字段走的是**谱一个字节都不动**的通道（`yue2_adapter.sh` 里的 `contract_abc`）。
    ///
    /// 用户 2026-11-08 给这个功能的定义：「并不是干预伴奏，而是给器乐版本定旋律。」
    var contractABC: String = ""
    /// 挂一份社区 LoRA（`.safetensors`）。空串 = 不挂。
    ///
    /// 它改的是**唱法 / 音色**（上游 README 的原话是 Custom Style/Artist LoRA），
    /// **不是咬字** —— 挂了也不会让"字唱得准"变好，那是模型本身的事。
    /// mlx-Yue 从 2026-10-13 那版起支持。
    var loraPath: String = ""
    /// LoRA 强度：1.0 = 原样，越小越接近没有挂的样子。
    var loraScale: Double = 1.0
    /// 这一趟**只要谱子、不唱** —— 界面上的「先出谱子」。
    ///
    /// 只对 YuE2 有意义：让它只跑"写谱"那一步（约 40 秒），产物是一份
    /// .abc（外加给 Dorico 的 .xml），**没有音频**。出了之后那份谱子会被顶到
    /// 「这次照它唱」的位置，再按「生成」就照它唱
    ///（2026-10-12 用户提的：YuE2 能先出乐谱、再出歌）。
    var planOnly: Bool = false

    enum CodingKeys: String, CodingKey {
        case prompt, lyrics, mode, duration, bpm, keyscale, steps, seed, thinking, language
        case title, engine
        case refAudio = "ref_audio"
        case srcAudio = "src_audio"
        case repaintStart = "repaint_start"
        case repaintEnd = "repaint_end"
        case coverStrength = "cover_strength"
        case abcPath = "abc_path"
        case contractABC = "contract_abc"
        case planOnly = "plan_only"
        case loraPath = "lora_path"
        case loraScale = "lora_scale"
    }
}

/// 手写解码：老任务留下的 params.json 往往缺几个字段，
/// 而属性上的默认值**救不了解码**（Swift 合成的 init(from:) 遇到缺字段就整体失败）。
/// 2026-10-11 实际踩到：历史列表因此全是空的。
///
/// ⚠️ 必须写在 extension 里：一旦 struct 本体里有自定义 init，
///    Swift 就不再合成那个带默认值的成员构造器，`GenerationRequest()` 会直接编译不过。
extension GenerationRequest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        lyrics = try c.decodeIfPresent(String.self, forKey: .lyrics) ?? "[Instrumental]"
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "generate"
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 60
        bpm = try c.decodeIfPresent(Int.self, forKey: .bpm)
        keyscale = try c.decodeIfPresent(String.self, forKey: .keyscale) ?? ""
        steps = try c.decodeIfPresent(Int.self, forKey: .steps) ?? 8
        seed = try c.decodeIfPresent(Int.self, forKey: .seed) ?? 42
        thinking = try c.decodeIfPresent(Bool.self, forKey: .thinking) ?? false
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "unknown"
        refAudio = try c.decodeIfPresent(String.self, forKey: .refAudio) ?? ""
        srcAudio = try c.decodeIfPresent(String.self, forKey: .srcAudio) ?? ""
        repaintStart = try c.decodeIfPresent(Int.self, forKey: .repaintStart) ?? 0
        repaintEnd = try c.decodeIfPresent(Int.self, forKey: .repaintEnd) ?? -1
        coverStrength = try c.decodeIfPresent(Double.self, forKey: .coverStrength) ?? 0.5
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? "acestep"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        abcPath = try c.decodeIfPresent(String.self, forKey: .abcPath) ?? ""
        contractABC = try c.decodeIfPresent(String.self, forKey: .contractABC) ?? ""
        planOnly = try c.decodeIfPresent(Bool.self, forKey: .planOnly) ?? false
        loraPath = try c.decodeIfPresent(String.self, forKey: .loraPath) ?? ""
        loraScale = try c.decodeIfPresent(Double.self, forKey: .loraScale) ?? 1.0
    }
}

/// 用哪台引擎。两台都是本机跑、都不出网，区别在「出什么」和「要等多久」。
///
/// 2026-10-12 加（用户提的：把 YuE2 也塞进这个界面，省得去折腾终端）。
/// 两台引擎共用同一套参数面板 —— 风格、歌词、质量档两边都要，
/// 只有「时长 / BPM / 调号 / 模式」是 ACE-Step 独有的，YuE2 那边不显示。
///
/// ★ 2026-10-16：**用户把本机那台「Composer Step」模型拆了**（他买了 ACE Studio，
///   不需要本地这一套；拆掉省出 10 GB）。所以下拉里只剩 YuE2。
///   `.aceStep` 这个 case **故意留着** —— ① 能读回旧记录的参数；② 哪天真想装回来，
///   在这儿少改一处。权重怎么装回来写在 `render_adapter.sh` 的报错里和 README 里。
enum EngineKind: String, CaseIterable, Identifiable {
    case aceStep = "Composer Step"
    case yue2 = "YuE2"
    /// Stable Audio 3 Medium（2026-11-10 接的第二台）：出的是**没人唱的音乐**。
    /// 它的模型和「Crafting Caster」共用同一份（`/Users/jieda/AI-Studio`），
    /// 这边只负责递参数、等结果，不另装一套。
    case stableAudio = "Stable Audio Medium"
    /// HeartMuLa 3B（2026-11-10 接的第三台）：**会唱词，不出谱子**。
    /// 用户听完定的调子：旋律稳、人声「特别干净」；伴奏不够打，拿出去拆开精修。
    /// ⇒ 它是**人声/词草稿机**。
    /// ⚠️ 风格只认英文标签（中文标签基本不生效，实测过）；歌词写多长、歌就有多长。
    case heartMuLa = "HeartMuLa"

    /// 下拉里真正列出来的（Composer Step 那台拆了，不列）。
    static var selectable: [EngineKind] { [.yue2, .stableAudio, .heartMuLa] }

    var id: String { rawValue }
    var apiValue: String {
        switch self {
        case .aceStep:    return "acestep"
        case .yue2:       return "yue2"
        case .stableAudio: return "stableaudio"
        case .heartMuLa:  return "heartmula"
        }
    }

    /// 下拉里那行字要能一眼看出区别，所以带上「出什么」。
    var label: String {
        switch self {
        case .aceStep:    return "Composer Step · 一段音乐"
        case .yue2:       return "YuE2 · 一首带人声的歌 + 谱子"
        case .stableAudio: return "Stable Audio Medium · 配乐/氛围，不唱词"
        case .heartMuLa:  return "HeartMuLa · 一首带人声的歌（无谱）"
        }
    }

    var hint: String {
        switch self {
        case .aceStep:    return "几秒到一分钟就出。适合快速试一个想法。"
        case .yue2:       return "会唱出来，还给一份能拿去 Dorico 改的谱子。没插电源不给跑。"
        case .stableAudio: return "几十秒出一段配乐，最长六分多钟。只出音乐，不唱词，也没有谱子。"
        case .heartMuLa:  return "旋律稳、人声干净，但它风格只认英文标签，伴奏是草稿。一首约四分钟。"
        }
    }

    /// 这一台用不用得上时长/BPM/调号/模式这些格子。
    var usesACEStepParameters: Bool { self == .aceStep }

    /// 这一台要不要歌词框。Stable Audio 没有人声，框摆着只会让人以为没生效。
    var usesLyrics: Bool { self != .stableAudio }

    /// 这一台会不会顺手给一份谱子。
    var producesScore: Bool { self == .yue2 }

    /// 这一台要不要「时长（秒）」这一格。
    /// HeartMuLa 也要：它那个是**上限**（歌词唱完就收尾），留着才有法控制。
    var usesDuration: Bool { self == .aceStep || self == .stableAudio || self == .heartMuLa }

    /// 时长上限：Stable Audio 官方模型最长 380 秒；另外两台按老规矩夹到 300。
    var maxSeconds: Double { self == .stableAudio ? 380 : 300 }
}

/// 三档快捷质量（对应扩散步数）。turbo 模型 8 步就够用。
enum QualityTier: String, CaseIterable, Identifiable {
    case low = "低"
    case medium = "中"
    case high = "高"

    var id: String { rawValue }
    var steps: Int {
        switch self {
        case .low: return 8
        case .medium: return 16
        case .high: return 32
        }
    }
}

/// YuE2 的两档（对应声学合成的步数）。实测：8 步一首约 4 分半、32 步约 10 分钟。
struct Yue2Tier: Identifiable, Hashable {
    let id: Int
    let name: String
    let steps: Int
    let detail: String

    static let fast = Yue2Tier(id: 8, name: "快", steps: 8, detail: "四分半出一首")
    static let standard = Yue2Tier(id: 32, name: "标准", steps: 32, detail: "十分钟，更细")
    static let all: [Yue2Tier] = [.fast, .standard]
}

/// 导出的两种格式。脚本按扩展名决定怎么转，界面只负责给路径。
enum ExportFormat: String, CaseIterable, Identifiable {
    case mp3 = "MP3"
    case wav = "WAV"

    var id: String { rawValue }
    var ext: String { self == .mp3 ? "mp3" : "wav" }
    var detail: String { self == .mp3 ? "320 kbps，体积小，便于分享" : "原始无损，和生成结果一模一样" }
}

/// 生成模式。Repaint 会重写旋律；丰富织体建议用参考音频 + 生成模式。
enum GenerationMode: String, CaseIterable, Identifiable {
    case generate = "生成"
    case repaint = "重绘"
    case reference = "参考音频"

    var id: String { rawValue }
    var apiValue: String {
        switch self {
        case .generate: return "generate"
        case .repaint: return "repaint"
        case .reference: return "reference"
        }
    }
    var hint: String {
        switch self {
        case .generate: return "整首新写。词曲都按你填的来。"
        case .repaint: return "只重画其中一段，需要选源音频和时间范围。"
        case .reference: return "按参考音频的织体与音色来写，风格跟着它走。"
        }
    }
}

/// progress.json 的镜像。percent / state 是规格书要求的两个字段。
///
/// `Equatable` 是给轮询用的：**内容没变就不往界面上推**（见 BackendClient.startPolling）。
/// 少了它，每半秒都会白推一次 → 整个界面白重画一次（2026-10-13 加）。
struct ProgressSnapshot: Codable, Equatable {
    var percent: Int = 0
    var state: String = "idle"          // idle | running | done | failed
    var message: String = ""
    var updated: Int = 0
    var output: String? = nil
    /// 「只出谱子」那一档的产物（那份 .abc 的绝对路径）。
    ///
    /// 单独一个字段，而不是拿 output 冒充 —— 这一档**没有音频**，
    /// 混用会让界面把一条没有声音的条目当成"能播的歌"。
    /// 老版本的 progress.json 没这个字段，缺失就是 nil（2026-10-12 加）。
    var score: String? = nil
    /// 这一步的**补充说明**（第二行小字）：大概要等多久、为什么慢。
    ///
    /// `message` 回答"现在在干什么"，这一行回答"还要等多久/为什么"——
    /// 「装引擎」这种事光说"在装"没用，得说"头一次开最慢，通常一两分钟"，
    /// 不然等待的人只会觉得卡死了。老进度文件没这个字段，缺失就是 nil（2026-10-13 加）。
    var detail: String? = nil
}

/// 左侧列表里的一条记录。
struct GenerationItem: Identifiable, Equatable {
    let id = UUID()
    var title: String                   // 列表上显示的一行摘要
    var request: GenerationRequest
    var outputPath: String? = nil
    /// 只出了谱子、还没唱的那一档：谱子文件的绝对路径。
    ///（2026-10-12 加「先出谱子」时一起加的）
    var scorePath: String? = nil
    var state: String = "idle"
    var createdAt: Date = Date()

    var isFinished: Bool { state == "done" && outputPath != nil }

    /// 谱子已经出来了、但还没唱（「先出谱子」按完之后的样子）。
    var isScoreOnly: Bool { state == "score" && scorePath != nil }

    /// 用的是不是 YuE2 —— 列表和播放条上要据此显示「谱子」那个入口。
    var isYue2: Bool { request.engine == "yue2" }

    /// 谱子的**基准路径**（不带后缀）：有音频就随音频的名字，
    /// 只出了谱子就随谱子的名字。两者同名同目录，是脚本摆出来的规矩。
    var scoreBase: URL? {
        guard isYue2, let base = outputPath ?? scorePath else { return nil }
        return URL(fileURLWithPath: base).deletingPathExtension()
    }

    /// 这一首的谱子（.xml 优先 —— 用户拿它进 Dorico）。找不到就返回 nil。
    var scoreURL: URL? {
        guard let base = scoreBase else { return nil }
        for ext in ["xml", "abc"] {
            let candidate = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// 这一首的 MIDI（「上传音频」拆轨的产物）。找不到就返回 nil。
    ///
    /// 三种放法都认：与音频同名的 `.mid`、拆轨固定的 `拆轨.mid`、
    /// 以及目录里唯一的那一份 `.mid`。**只在这一首自己的目录里找** ——
    /// 别人的 MIDI 不能混进来。
    var midiURL: URL? {
        guard let path = outputPath else { return nil }
        let out = URL(fileURLWithPath: path)
        let folder = out.deletingLastPathComponent()
        let sameName = out.deletingPathExtension().appendingPathExtension("mid")
        if FileManager.default.fileExists(atPath: sameName.path) { return sameName }
        let split = folder.appendingPathComponent("拆轨.mid")
        if FileManager.default.fileExists(atPath: split.path) { return split }
        if let all = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) {
            let mids = all.filter { $0.pathExtension.lowercased() == "mid" }
            if mids.count == 1 { return mids[0] }
        }
        return nil
    }
}

/// 调色板 —— 固定一套深色（对着 ACE Studio 那个面板的样子做）。
enum Palette {
    static let accent = Color(red: 0.16, green: 0.47, blue: 1.0)
    static let windowBG = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let sidebar = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let card = Color(red: 0.14, green: 0.14, blue: 0.15)
    static let field = Color(red: 0.17, green: 0.17, blue: 0.18)
    static let fieldHover = Color(red: 0.21, green: 0.21, blue: 0.23)
    static let stroke = Color.white.opacity(0.12)
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.55)
}
