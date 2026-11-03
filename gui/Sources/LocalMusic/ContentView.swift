import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import Combine

// MARK: - 界面状态

@MainActor
final class AppViewModel: ObservableObject {

    @Published var items: [GenerationItem] = []
    /// LoRA 正在转格式（转的时候按钮上不写字，免得以为没反应）。
    @Published var loraBusy = false
    @Published var selectedID: UUID?
    @Published var form = GenerationRequest()
    @Published var mode: GenerationMode = .generate
    @Published var tier: QualityTier = .low
    /// 这一首用哪台引擎出。两台共用这一个表单，只有「出什么、等多久」不一样。
    /// ★ 2026-10-16：本机那台 Composer Step 模型拆了，所以默认落在 YuE2。
    @Published var engine: EngineKind = .yue2
    /// YuE2 只有两档 —— 实测过的就是 8 步（四分半）和 32 步（十分钟）。
    @Published var yue2Tier: Yue2Tier = .fast
    /// 打开「纯器乐」前先把词存这儿，关掉时原样还回去（2026-11-02 加）
    @Published var lyricsBeforeInstrumental: String = ""
    @Published var playingID: UUID?
    @Published var exportMessage: String = ""
    @Published var exporting: Bool = false
    /// 「送进 ACE Studio」那一条的状态。
    ///
    /// **单独一个字符串，不跟 `exportMessage` 合用** —— 两件事会同时发生
    ///（导出到「下载」的时候顺手送一趟 ACE），挤同一行必然互相冲掉。
    @Published var transferMessage: String = ""
    /// 上一条消息是成功还是失败（决定那行字是绿的还是红的）。
    /// `nil` ＝ 还没送过，显示的是说明而不是结果。
    @Published var transferOK: Bool? = nil
    @Published var transferring: Bool = false
    /// 「连 Live」那一条的状态。界面上的按钮照着它变。
    @Published var liveState: LiveLinkState = .notRunning
    /// 连 Live 的一句话说明（成功／为什么没成）。空串就什么都不显示。
    @Published var liveMessage: String = ""
    /// 正在等 Live 连上（按钮按下之后那几秒）。
    @Published var linkingLive: Bool = false
    /// 最近一次**读进来**的那份谱子（拍号／调号／速度／音符数／歌词…，见 `ScoreReader`）。
    ///
    /// 用户 2026-10-13 要的：「导入乐谱的时候顺便读一下它的拍号调号歌词音符，
    /// **不要导入之后还是空**」。以前读出来的东西只往**底部那行提示**里塞一句，
    /// 而那一行在窗口最底下、窗口又比内容矮 ⇒ 他根本看不见，
    /// "导入完了"在他眼里就等于**什么都没发生**。
    /// 现在留在状态里，由界面上那张「这次照这份谱子唱」的卡摆出来。
    @Published var scoreReading: ScoreReading?
    /// 谱子里的词**去向**的一句话（"已填进下面的歌词框"／"用的是你框里这份词"…）。
    ///
    /// 用户 2026-10-13 又追一句：「把导入乐谱时读到的歌词直接放在歌词栏里，
    /// **也可以证明真的读到乐谱内容了**」——
    /// 歌词框里出现他谱子上的词，就是最硬的证据；这一句把它写在明面上，
    /// 由那张卡摆在**歌词框正上方**（框里一变，上面同时说明这是从谱子里来的）。
    /// 空串 ＝ 这次没从谱子拿词，卡片就不多说这一句。
    @Published var scoreLyricsNote: String = ""
    /// 自检用：出了谱子之后**自动接着按「生成」**照它唱。
    /// 正常使用永远是 false —— 按不按「生成」是用户的事，不是我的事。
    @Published var autoSingAfterScore: Bool = false
    /// 侧栏那个「MusicXML → 简谱」的独立页面。
    /// 它不碰生成流程 —— 用户 2026-10-19 明确说「和那个模型没有关系」。
    @Published var showJianpu: Bool = false

    // MARK: - 8001 语义服务（SheetSage2 × YuE2）

    /// 状态栏那一句人话（"正在整理乐谱…"之类）。空串就不显示。
    @Published var ss2Status: String = ""
    /// 和弦核对的一句话 —— Flow-B 的「手写和弦没被动过」就靠它说给用户听。
    @Published var ss2Summary: String = ""
    /// 交给谱面面板的那份 ABC（带版权头；和弦原样保留）。
    @Published var ss2RepairedABC: String = ""
    /// 「送到 MIR Studio」那一行状态。空串就不显示。
    @Published var studioMessage: String = ""
    /// 送进 YuE2 的那份（已剥和弦）。只用于展示，不直接生效。
    @Published var ss2MelodyABC: String = ""
    /// 结构化条件 JSON 的原文，面板里可以展开看。
    @Published var ss2ConditionJSON: String = ""
    /// 谱面面板开没开。
    @Published var ss2ShowsPanel: Bool = false
    /// 服务正在忙（按钮按下去到回来之间）。
    @Published var ss2Busy: Bool = false
    /// 谱面面板里的移调 / 音域。**目前只记在界面上，还没接进引擎** ——
    /// 面板里会写清楚，不假装生效（2026-10-24）。
    @Published var ss2Transpose: Int = 0
    @Published var ss2VocalRange: String = ""

    // MARK: - 照谱奏 · 音频拆谱（2026-10-24）

    /// 「照谱奏」正在忙（读谱 + 渲染）。渲染本身很快（几秒），慢的是读谱和落盘。
    @Published var playBusy: Bool = false
    /// 照谱奏这条路的一句话：成了报摘要，没成报原因。
    @Published var playStatus: String = ""
    /// 上一条奏出来的 wav（给「在访达里看看」用）。
    @Published var playOutput: URL?
    /// 音频拆谱正在忙。
    @Published var transcribeBusy: Bool = false
    /// 音频拆谱的一句话（拆出几条轨、存到哪儿）。
    @Published var transcribeStatus: String = ""

    // MARK: - 改改乐器（2026-10-29）

    /// 上一次拆 MIDI 用的源音频 —— 「改改乐器」重跑要用它（换过文件夹就找不回来了）。
    private var lastMIDIAudio: URL?
    /// 上一次拆出来的 MIDI 落在哪儿。有它，界面上才摆那一行入口。
    @Published var lastMIDIURL: URL?
    /// 上一次 MIDI 里**真有的**乐器（英文 key）—— 勾选清单拿它预选。
    @Published var lastMIDIInstruments: [String] = []
    /// 「改改乐器」小窗开没开。
    @Published var showsInstrumentPicker: Bool = false
    /// 小窗里勾了哪些（空 = 不点名，让它自己判断）。
    @Published var pickedInstruments: Set<String> = []
    /// 重拆正在跑。
    @Published var retranscribeBusy: Bool = false

    /// 「扒歌词」正在忙（拆人声 + 认字）。
    @Published var lyricsBusy: Bool = false
    /// 「扒歌词」的一句话：认出来多少字、存到哪儿。
    @Published var lyricsStatus: String = ""
    /// 最近一次扒歌词留下的人声轨和输出文件夹 —— 「重新对齐」要用。
    private var lastVocals: URL?
    private var lastLyricsFolder: URL?
    /// 重新对齐正在忙。
    @Published var alignBusy: Bool = false
    /// 重新对齐的一句话。
    @Published var alignStatus: String = ""

    let client = BackendClient()
    /// 试听用的播放器。它可以把声音**指定**送到偏好设置里选的那块声卡。
    let player = DevicePlayer()

    /// 正在生成的是哪一条。用它（而不是"当前选中的"）来收结果 ——
    /// 否则生成期间用户点到别的条目，结果就会写错地方。
    private var runningID: UUID?

    init() {
        let player = self.player
        player.onFinish = { [weak self] in
            self?.playingID = nil
        }
        client.onFinish = { [weak self] output, score in
            guard let self else { return }
            guard let target = self.runningID ?? self.selectedID else { return }
            if let idx = self.items.firstIndex(where: { $0.id == target }) {
                self.items[idx].outputPath = output
                self.items[idx].scorePath = score
                if output != nil {
                    self.items[idx].state = "done"
                } else if score != nil {
                    // 「先出谱子」那一档：谱子出来了、还没唱。
                    self.items[idx].state = "score"
                } else {
                    self.items[idx].state = "failed"
                }
                // ★ 出了谱子就把它**顶到"这次照它唱"的位置**——紧接着按「生成」
                //   就照这一份唱（用户 2026-10-12 要的：先出乐谱，再出歌）。
                //   这也是为什么出谱子那一刻要把表单里的 abcPath 清掉：
                //   否则 YuE2 会拿**上一份**旧谱来"写"新谱，等于没写。
                if output == nil, let score {
                    self.form.abcPath = score
                    // 读数备忘录跟着作废：这一份是刚写出来的新谱，还没人读过它。
                    // 不清的话，卡片上会用**上一份**的拍号调号冒充它。
                    // （`scoreLyricsNote` 要一起清 —— 这两样永远同生共死。）
                    self.scoreReading = nil
                    self.scoreLyricsNote = ""
                    // 这儿**故意不再写一句提示** —— 进度条上已经把
                    // 「谱子出好了，还没唱。按「生成」就照这一份唱」说了，
                    // 底部再来一句一模一样的，等于同一句话说两遍（2026-10-12 抓图看见的）。
                    // 只有自检会走到这儿（见 autoSingAfterScore 的说明）
                    if self.autoSingAfterScore {
                        self.autoSingAfterScore = false
                        self.runningID = nil
                        self.generate()
                        return
                    }
                }
            }
            // 生成完自动送进 Live（用户 2026-10-17 选的「1」）。
            // 没连着 Live 时 autoSendToLive 自己会静默退出。
            if let output {
                self.autoSendToLive(output: output)
            }
            self.runningID = nil
        }
        // 把以前生成过的列出来（关掉重开还能看见、还能导出）。
        // 一条都没有就留空列表 —— 空列表在界面上有提示，不造假条目。
        client.clearStaleProgressIfNeeded()
        reloadHistory()

        // 偏好设置里换了「输出文件夹」就重扫一遍 —— 挑完文件夹，这边左栏得跟着变。
        // （观察者不摘：这个视图模型跟程序同寿，没有比它晚死的时机。）
        NotificationCenter.default.addObserver(
            forName: OutputLocation.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadHistory()
        }

        // 收 Composer Assistant 送来的风格描述（见 `BridgeInbox`）。
        // 三个时机读同一个信箱、**不轮询**：启动一次、收到它的通知一次、
        // 窗口被激活一次 —— 通知万一被系统挡掉，切一下窗口也能收到。
        takeBridgeStyle()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(BridgeInbox.notificationName), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.takeBridgeStyle() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.takeBridgeStyle() }
        }

        // ★ 让界面跟着 client 的进度重绘。
        //
        // 2026-10-13 发现的坑：`client` 只是 AppViewModel 的一个**普通属性**，
        // 它自己的 @Published 变化只通知它自己的订阅者，而界面订阅的是 AppViewModel
        // ⇒ **运行中的百分比和那行字根本不刷新**，只在开始与结束各变一次。
        // 用户说的"看着很绝望的进度条"，一部分不是跑得慢，是**界面压根没在画**。
        // 转发一层就够：client 一有动静，就让 AppViewModel 也报一次变化。
        client.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // 2026-10-17：Live 开着就自动连（每 3 秒问一次）。
        startLiveWatcher()
    }

    /// 上面那条转发的把手（少了它，订阅会在 init 结束时就断掉）。
    private var cancellables = Set<AnyCancellable>()

    /// 把 Composer Assistant 送来的文本填进**对应的那个框**（风格 / 歌词）。
    /// 没有新的就什么都不做。
    ///
    /// **故意不弹提示**：框里的字自己变了就是最好的提示；
    /// 这是"底下的事"，不必让人看见有人在他背后写字。
    func takeBridgeStyle() {
        if let text = BridgeInbox.takeNew(.style) { form.prompt = text }
        if let text = BridgeInbox.takeNew(.lyrics) { form.lyrics = text }
        // MIR Studio 改完谱、点了「重新出歌」——在这儿开一轮新的生成。
        if let request = BridgeInbox.takeRegenerate() {
            applyStudioRegenerate(request)
        }
    }

    /// 收到工作室的重唱请求：把谱落到一个文件、填好表单，然后按「生成」。
    ///
    /// 为什么落文件：`form.abcPath` 是**路径**，脚本读的是磁盘上那份谱。
    /// 落在 Application Support（不是 output/）—— 这是"正在用的输入"，
    /// 不该在用户的作品列表里冒出一条。
    ///
    /// `CS_STUDIO_DRY=1` 只填表单、不真跑（验证信箱那条链路用，省一次四分钟）。
    func applyStudioRegenerate(_ request: BridgeInbox.Regenerate) {
        guard let abc = request.abc, !abc.isEmpty else { return }
        guard !isRunning else {
            studioMessage = "MIR Studio 送来一份改好的谱，但这边正在生成 —— 等这一轮完了再点一次「重新出歌」。"
            return
        }

        let folder = BridgeInbox.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        // ★ 名字里带 `-model`：工作室交回来的谱**已经是模型高度**（页面显示低八度，
        //   交接时服务端升回去了）。`prepare_score.py` 看到这个标记就不再升，
        //   否则人声会被抬两个八度（2026-10-25 加）。
        let file = folder.appendingPathComponent("studio-\(stamp)-model.abc")
        do {
            try abc.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            studioMessage = "MIR Studio 的谱收下了，但存不下来：\(error.localizedDescription)"
            return
        }

        form.abcPath = file.path
        if let style = request.style, !style.isEmpty { form.prompt = style }
        if let lyrics = request.lyrics, !lyrics.isEmpty { form.lyrics = lyrics }
        if let seed = request.seed { form.seed = seed }
        if let title = request.title, !title.isEmpty { form.title = FileName.safe(title) }
        engine = .yue2
        yue2Tier = (request.steps ?? 8) <= 8 ? .fast : .standard
        // 这一轮是"照谱唱"，不该沿用界面上选中的那一条（那一条的产物是旧的）。
        selectedID = nil

        // 自检有两种开关：环境变量（从命令行启动时）和偏好（双击启动时也生效 ——
        // GUI 从 launchd 起来，拿不到我 shell 里的环境变量）。
        let dry = ProcessInfo.processInfo.environment["CS_STUDIO_DRY"] == "1"
            || UserDefaults.standard.bool(forKey: "CSStudioDry")
        if dry {
            print("[CS] MIR Studio 重唱请求（dry）—— 谱=\(file.lastPathComponent)"
                + " 风格=\(form.prompt.prefix(24)) 词=\(form.lyrics.prefix(24))"
                + " 档=\(yue2Tier)")
            studioMessage = "（自检）MIR Studio 送来一份谱：\(file.lastPathComponent)"
            return
        }

        studioMessage = "MIR Studio 送来一份改好的谱 —— 开始重唱。"
        generate()
    }

    /// 把当前表单写回信箱，等 Composer Assistant 来取。
    ///
    /// **防抖**（2026-10-12 加「CS PROMPT」时定的）：连着敲字只落最后一次。
    /// 每敲一个字写一次盘既没必要，也说不清"哪个瞬间才算定了"；
    /// 对面要的只是**最后的样子**。
    func scheduleBridgeWriteBack() {
        bridgeWriteTask?.cancel()
        let prompt = form.prompt
        let lyrics = form.lyrics
        bridgeWriteTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            BridgeInbox.writeBack(prompt: prompt, lyrics: lyrics)
        }
    }

    /// 上面那个防抖任务的把手：每来一次新改动就把上一次取消掉。
    private var bridgeWriteTask: Task<Void, Never>?

    /// 扫一遍输出目录，把以前生成过的曲子重新列出来。
    ///
    /// 单列成方法，是因为有**两个**时机会用到它：开机、以及用户换了「输出文件夹」。
    /// 生成期间**不重扫** —— 手上那一首的产物路径是起跑时就算好的，
    /// 中途换列表只会让结果对不上条目。
    func reloadHistory() {
        guard !client.isRunning else { return }
        let history = client.loadHistory()
        items = history
        selectedID = history.first?.id
        if let newest = history.first {
            form = newest.request
            mode = GenerationMode.allCases.first { $0.apiValue == newest.request.mode } ?? .generate
            tier = QualityTier.allCases.first { $0.steps == newest.request.steps } ?? .low
            applyEngine(from: newest.request)
        }
    }

    /// 从一条任务的参数里还原「用哪台引擎、哪一档」。
    /// 单列成一个方法，是因为初始化与选中两条路都要用同一套判断 ——
    /// 分开写迟早有一处忘了改。
    private func applyEngine(from request: GenerationRequest) {
        // 只在**可选**的引擎里找：旧记录写着 "acestep" 的（那台模型已经拆了），
        // 一律回落到 YuE2 —— 否则下拉里没有它，界面会显示一个选不中的空档。
        engine = EngineKind.selectable.first { $0.apiValue == request.engine } ?? .yue2
        yue2Tier = request.steps <= 8 ? .fast : .standard
    }

    var isRunning: Bool { client.isRunning }
    var progress: ProgressSnapshot { client.progress }
    var lastError: String { client.lastError }

    /// 列表里那一行文字：优先显示歌词首行，没有就显示风格摘要。
    ///
    /// ⚠️ **首行常常不是歌词，而是 `[Verse]` 这种结构标记** —— 必须跳过，
    ///    否则一整列作品的名字会全叫「[Verse]」，隔天在访达里根本分不出谁是谁。
    ///    2026-10-12 加 YuE2 时自检撞见的（YuE2 的歌词模板里标记行更多）。
    static func title(for request: GenerationRequest) -> String {
        // ★ 2026-10-13：**给作品起的固定名字优先。**
        //   原来自始至终都是"拿歌词第一句现算"（连文件名都一样），
        //   于是同一首歌跑几版，列表里就出现一串**一模一样的条目** ——
        //   用户根本分不出哪个是哪个（他为此专门截了图过来）。
        //   现在：`params.json` 里存着名字就用它（生成时本来就会写一个自动名，
        //   所以老条目行为不变）；手工改过名字的，列表里立刻认得出。
        let fixed = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fixed.isEmpty { return fixed }
        let lyrics = request.lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lyrics.isEmpty, lyrics != "[Instrumental]" {
            let lines = lyrics.split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let firstReal = lines.first { line in
                !line.isEmpty && !(line.hasPrefix("[") && line.hasSuffix("]"))
            }
            if let firstReal { return String(firstReal.prefix(22)) }
        }
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { return String(prompt.prefix(22)) }
        return "未命名"
    }

    // MARK: 操作

    /// 「新写一首」：把表单清空、取消选中，准备填新内容。
    /// 注意它**不**往列表里塞空条目 —— 列表里只放真正生成过的曲子，
    /// 条目由「生成」那一刻自己长出来。
    func addNew() {
        form = GenerationRequest()
        mode = .generate
        tier = .low
        selectedID = nil
        exportMessage = ""
        // 谱子那份备忘录也要清：`form = GenerationRequest()` 已经把 `abcPath`
        // 清掉了，而卡片第一行读的正是它 —— 留着旧读数，下一次「先出谱子」
        // 那张卡就会**拿上一份的拍号调号**来显示（那是假话，比空着更糟）。
        scoreReading = nil
        scoreLyricsNote = ""
        // 引擎和档位**故意不重置** —— 刚用过哪台就接着用哪台。
        // 连着写几首时，每次都要把引擎再选一遍很烦。
    }

    func select(_ item: GenerationItem) {
        selectedID = item.id
        form = item.request
        // 换了一首，上一份的读数就作废（同 `addNew` 的理由：卡片别拿旧的冒充新的）。
        scoreReading = nil
        scoreLyricsNote = ""
        mode = GenerationMode.allCases.first { $0.apiValue == item.request.mode } ?? .generate
        tier = QualityTier.allCases.first { $0.steps == item.request.steps } ?? .low
        applyEngine(from: item.request)
    }

    // MARK: - 8001 语义服务（SheetSage2）

    /// 把一份谱子交给 8001 服务：读人写的和弦、修格式、出条件 JSON。
    ///
    /// **Flow-B 最关键的一条**：服务只"读"、不改。界面把核对结果摆出来；
    /// 送进 YuE2 的仍然是一份剥掉和弦的旋律 —— 和弦根本不进 AI，
    /// 所以它连改写的机会都没有。
    func analyzeWithSheetSage2(_ file: URL) {
        ss2Status = "正在整理乐谱…"
        ss2Busy = true
        ss2Summary = ""
        let root = client.root
        Task { @MainActor in
            do {
                let isABC = file.pathExtension.lowercased() == "abc"
                let xml = isABC ? nil : (try? Data(contentsOf: file))
                let abc = await Task.detached(priority: .userInitiated) { () -> String? in
                    if isABC { return try? String(contentsOf: file, encoding: .utf8) }
                    return SheetSage2Client.convertMusicXMLToABC(file, projectRoot: root)
                }.value
                let result = try await SheetSage2Client.analyze(
                    flow: isABC ? "A" : "B", musicxml: xml, abc: abc)
                ss2Summary = result.human
                ss2RepairedABC = result.repairedABC
                ss2MelodyABC = result.melodyABC
                ss2ConditionJSON = result.conditionJSON
                // 成功时**只留一行**：核对结论放在 `ss2Summary`（绿色那行）。
                // `ss2Status` 专门留给"进行中 / 出错"——两处都写同一句会显示两遍
                //（2026-10-24 第一次真机跑就看见了）。
                ss2Status = ""
            } catch {
                ss2Status = error.localizedDescription
            }
            ss2Busy = false
        }
    }

    /// 「上传音频」：选一段录音 → 问要拆什么 → 拆出草稿谱 / MIDI。
    ///
    /// 原来这个按钮只会做一件事（走 8001 服务转谱），而那个服务的 SheetSage2
    /// 权重 2026-10-24 撤了，于是它变成一个按了会报错的按钮。
    /// 2026-10-24 起改走 `audio.cpp`（GGUF + Metal），并且**多给一样东西：MIDI**。
    func importAudioForCover() {
        let panel = NSOpenPanel()
        panel.title = "选择一段音频"
        panel.message = "整首歌、或一段干净的人声都行。它只在本机拆，不出网。"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.audio]
        guard panel.runModal() == .OK, let file = panel.url else { return }

        // 三个按钮摆明白：同一段音频，谱子和 MIDI 是两个用途，别用一个开关含糊过去
        let alert = NSAlert()
        alert.messageText = "要拆什么？"
        alert.informativeText = "谱子用来改；MIDI 用来拖进 Dorico 或 DAW。两个都拆要跑两次，多等半分钟。"
        alert.addButton(withTitle: "草稿谱 + MIDI")
        alert.addButton(withTitle: "只要草稿谱")
        alert.addButton(withTitle: "只要 MIDI")
        let choice = alert.runModal()
        guard choice != .abort else { return }
        let wantScore = choice == .alertFirstButtonReturn || choice == .alertSecondButtonReturn
        let wantMIDI = choice == .alertFirstButtonReturn || choice == .alertThirdButtonReturn
        transcribeAudio(file, wantScore: wantScore, wantMIDI: wantMIDI)
    }

    /// 音频 → 草稿谱 / MIDI。
    ///
    /// 走哪条引擎：
    ///   ① `audio.cpp`（SheetSage2 出谱 / MuScriptor 出 MIDI）—— 有就用它，快；
    ///   ② 8001 语义服务 —— 它的出谱权重撤了，只在装回来时才补得上；
    ///   ③ 都不在 → 明说缺什么，不假装成功。
    ///
    /// 两个模型各要几 G 内存，所以**串行跑**，不并行。
    func transcribeAudio(_ file: URL, wantScore: Bool, wantMIDI: Bool) {
        let cpp = AudioCppClient.status()
        guard cpp.cli != nil else {
            transcribeStatus = cpp.human
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let base = file.deletingPathExtension().lastPathComponent
        let folder = client.outputRoot.appendingPathComponent("\(stamp) 听写-\(base)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            transcribeStatus = "建不了输出文件夹：\(error.localizedDescription)"
            return
        }

        transcribeBusy = true
        transcribeStatus = "正在拆…（模型第一次要把权重读进内存，开头慢一点）"
        Task { @MainActor in
            var notes: [String] = []
            do {
                if wantScore {
                    guard cpp.canTranscribeToScore else {
                        throw AudioCppClient.Failure.notInstalled(
                            "没找到 SheetSage2 的模型文件，出不了谱。\(cpp.human)")
                    }
                    let abcURL = folder.appendingPathComponent("草稿.abc")
                    let draft = try await AudioCppClient.transcribeToScore(audio: file, output: abcURL)

                    // 拿到草稿第一件事：交给 8001 服务"理干净"（结构校验、和弦原样、版权头）。
                    // 服务没开着就原样用 —— 草稿仍然是草稿，能用。
                    var finalABC = draft
                    if let polished = try? await SheetSage2Client.analyze(
                        flow: "A", musicxml: nil, abc: draft),
                       !polished.repairedABC.isEmpty {
                        finalABC = polished.repairedABC
                    }
                    try finalABC.write(to: abcURL, atomically: true, encoding: .utf8)
                    ss2MelodyABC = ""
                    notes.append("草稿谱（草稿.abc）")

                    // ★ 2026-10-26：整理成 YuE2 认的双行谱（Vocal + Ins）。
                    //   听来的谱常差一个八度；到工作室里点「人声降八度」一键改。
                    let twoURL = folder.appendingPathComponent("双行谱.abc")
                    var shownURL = abcURL
                    if AudioCppClient.buildTwoVoices(from: abcURL, to: twoURL),
                       let two = try? String(contentsOf: twoURL, encoding: .utf8),
                       !two.isEmpty {
                        shownURL = twoURL
                        ss2RepairedABC = two
                        ss2Summary = "音频拆成双行谱了：旋律 + 低音骨架。八度不对，到工作室里调。"
                        notes.append("双行谱（双行谱.abc）")
                    } else {
                        ss2RepairedABC = finalABC
                        ss2Summary = "音频拆成谱了。先看谱面，改完再送唱。"
                    }

                    // 顺手出一份 MusicXML —— 他要拖进 Dorico 的就是这个
                    if let xml = try? ScoreFiles.convert(shownURL, to: .xml) {
                        notes.append("MusicXML（\(xml.lastPathComponent)）")
                    }
                }

                if wantMIDI {
                    guard cpp.canTranscribeToMIDI else {
                        throw AudioCppClient.Failure.notInstalled(
                            "没找到 MuScriptor 的模型文件，出不了 MIDI。\(cpp.human)")
                    }
                    let midURL = folder.appendingPathComponent("拆轨.mid")
                    let eventsURL = folder.appendingPathComponent("拆轨乐器.json")
                    let used = try await AudioCppClient.transcribeToMIDI(
                        audio: file, output: midURL, eventsOut: eventsURL)
                    // 记下来源与产物：「改改乐器」要拿同一段音频、写回同一个文件
                    lastMIDIAudio = file
                    lastMIDIURL = midURL
                    lastMIDIInstruments = used
                    // 补乐器名：文件里写英文，界面上说中文
                    let tracks = (try? MIDITrackNames.annotate(midURL)) ?? []
                    if tracks.isEmpty {
                        notes.append("MIDI（拆轨.mid）")
                    } else {
                        notes.append("MIDI（拆轨.mid，\(tracks.count) 轨："
                                     + tracks.map { $0.chinese }.joined(separator: "、") + "）")
                    }
                }

                transcribeBusy = false
                transcribeStatus = "拆好了，存在「\(folder.lastPathComponent)」——"
                    + notes.joined(separator: "；")
                if wantScore { ss2ShowsPanel = true }
            } catch {
                transcribeBusy = false
                transcribeStatus = error.localizedDescription
            }
        }
    }

    /// 「改改乐器」：拿同一段音频、按勾选的乐器再拆一遍，写回同一份 `拆轨.mid`。
    ///
    /// 为什么覆盖而不是另存一份：用户的意思是「这条拆错了，重来」，
    /// 不是「再存一份」。留一堆同名文件夹，他反而分不清哪份是最后的。
    /// `拆轨乐器.json`（事件原文）一起重写 —— 它跟 MIDI 永远是同一轮的产物。
    ///
    /// 一个都不勾 = 不传这个参数 = 让它自己判断，跟原来的行为完全一致。
    func retranscribeMIDIWithPicked() {
        guard let audio = lastMIDIAudio, let out = lastMIDIURL else { return }
        // 按目录顺序传：集合本身无序，顺序变了模型/日志就不好对
        let picked = MuScriptorInstrumentCatalog.all.map(\.key)
            .filter { pickedInstruments.contains($0) }
        showsInstrumentPicker = false
        retranscribeBusy = true
        transcribeStatus = picked.isEmpty
            ? "重拆中…（这回不点名，让它自己判断）"
            : "重拆中…（只出："
                + picked.map { MuScriptorInstrumentCatalog.chinese(for: $0) }.joined(separator: "、")
                + "）"
        Task { @MainActor in
            do {
                let eventsURL = out.deletingLastPathComponent()
                    .appendingPathComponent("拆轨乐器.json")
                let used = try await AudioCppClient.transcribeToMIDI(
                    audio: audio, output: out, instruments: picked, eventsOut: eventsURL)
                lastMIDIInstruments = used
                let tracks = (try? MIDITrackNames.annotate(out)) ?? []
                retranscribeBusy = false
                let folderName = out.deletingLastPathComponent().lastPathComponent
                if tracks.isEmpty {
                    transcribeStatus = "重拆完了，这回一条轨都没分出来 —— 还在「\(folderName)」里。"
                } else {
                    transcribeStatus = "重拆好了（\(tracks.count) 轨："
                        + tracks.map { $0.chinese }.joined(separator: "、")
                        + "）—— 还在「\(folderName)」里。"
                }
            } catch {
                retranscribeBusy = false
                transcribeStatus = error.localizedDescription
            }
        }
    }

    /// 「扒歌词」：选一首歌 → 拆人声 → 认字 → 填进歌词框。
    ///
    /// 2026-10-27 新加：这是 MIR 的第四条入口（音频 → 文字）。
    /// 认出来的词直接进歌词框，接着就能走「谱子 → ACE」那条出口 ——
    /// 扒词不是终点，是让这首歌能重新配词、重新唱。
    func pickAudioForLyrics() {
        let panel = NSOpenPanel()
        panel.title = "选一首歌扒歌词"
        panel.message = "先把伴奏剥掉，再认人声里的字。"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        transcribeLyricsFromAudio(file)
    }

    /// 音频 → 歌词。产物：`<时间> 歌词-<歌名>/歌词.txt` + 人声分离/。
    func transcribeLyricsFromAudio(_ file: URL) {
        let cpp = AudioCppClient.status()
        guard cpp.canTranscribeLyrics else {
            lyricsStatus = cpp.human
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let base = file.deletingPathExtension().lastPathComponent
        let folder = client.outputRoot.appendingPathComponent("\(stamp) 歌词-\(base)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            lyricsStatus = "建不了输出文件夹：\(error.localizedDescription)"
            return
        }

        lyricsBusy = true
        lyricsStatus = "正在拆人声…（第一次跑要读模型，开头慢一点）"
        Task { @MainActor in
            do {
                let text = try await AudioCppClient.transcribeLyrics(audio: file, outDir: folder)
                form.lyrics = text
                lastVocals = folder.appendingPathComponent("人声分离/vocals.wav")
                lastLyricsFolder = folder
                lyricsBusy = false
                lyricsStatus = "认出来了（\(text.count) 字），已填进歌词框；"
                    + "也存进了「\(folder.lastPathComponent)」"
            } catch {
                lyricsBusy = false
                lyricsStatus = error.localizedDescription
            }
        }
    }

    /// 「按框里的词重新对齐」：把**你改过的词**重新打一遍时间轴。
    ///
    /// 为什么要有这一步：对齐器要求文字和音频严格对应，用刚扒出来的词（有错字）
    /// 去对，后半段会一路崩成几十毫秒一个字。词改对了再对，它才老实。
    func realignLyrics() {
        guard let vocals = lastVocals,
              FileManager.default.fileExists(atPath: vocals.path) else {
            alignStatus = "先扒一次歌词，才有干声可以对齐。"
            return
        }
        guard let folder = lastLyricsFolder else { return }
        let text = form.lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            alignStatus = "歌词框是空的。"
            return
        }

        alignBusy = true
        alignStatus = "正在按你改过的词对齐…"
        Task { @MainActor in
            // 按「呼吸」切：静音检测找人声段，词按行/句切，一句对一段。
            // 这条路不跑识别（用的是框里的词），所以快，而且句界来自真的停顿。
            let words = await AudioCppClient.alignBySentence(text: text, vocals: vocals, outDir: folder)
            alignBusy = false
            if words.isEmpty {
                alignStatus = "没对上。"
            } else {
                alignStatus = "对上了：\(words.count) 个字，存了 歌词时间.txt / 歌词对齐.json"
            }
        }
    }

    /// 「谱子出声」：选一份 MusicXML，照谱奏成音频并播放。
    ///
    /// 和「生成」是两条完全不同的路：这里**不让模型唱**，只是把谱面原样发成声音。
    /// 它回答的问题只有一个：**我写的这张谱，听起来是我想的那样吗？**
    func playScoreFile() {
        let panel = NSOpenPanel()
        panel.title = "选一份谱子"
        panel.message = "照谱奏：音高、时值、连音线原样，不加表现。"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types: [UTType] = [.xml]
        for ext in ["musicxml", "mxl", "abc"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let file = panel.url else { return }
        playScore(at: file)
    }

    /// 照谱奏一份文件（选文件那条路和自检都走这里）。
    func playScore(at file: URL) {
        guard file.pathExtension.lowercased() != "abc" else {
            playStatus = "照谱奏只认 MusicXML。先把 ABC 转一份 XML 再听。"
            return
        }
        playBusy = true
        playStatus = "正在读谱…"
        Task { @MainActor in
            do {
                let score = try ScorePlayer.load(file)
                guard !score.isEmpty else {
                    playBusy = false
                    playStatus = "这份谱子里没有能奏出来的音。"
                    return
                }

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                let stamp = formatter.string(from: Date())
                let base = file.deletingPathExtension().lastPathComponent
                let folder = client.outputRoot.appendingPathComponent("\(stamp) 照谱奏-\(base)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let wav = folder.appendingPathComponent("照谱奏.wav")

                let began = Date()
                try ScorePlayer.render(score, to: wav)
                let elapsed = Date().timeIntervalSince(began)

                playOutput = wav
                playBusy = false
                playStatus = score.summary + "；出声用了 \(String(format: "%.1f", elapsed)) 秒"

                let device = AudioDeviceCatalog.resolve(savedName: preferredOutputDeviceName)
                if let problem = player.play(url: wav, device: device) {
                    playStatus += "（播放没成：\(problem)）"
                }
            } catch {
                playBusy = false
                playStatus = error.localizedDescription
            }
        }
    }

    /// 「挂 LoRA」：选一份社区调好的 `.safetensors` 权重。
    ///
    /// ★ 它改什么、不改什么，这里必须说准（2026-10-24）：
    ///   改的是**唱法 / 音色**（上游 README 原话 Custom Style/Artist LoRA），
    ///   **不改咬字** —— 挂着它也不会让"字唱得准"变好，那是模型本身的事。
    ///   所以界面上没有把它写成"改善唱词"之类的字样。
    func pickLoRA() {
        let panel = NSOpenPanel()
        panel.title = "选一份 LoRA"
        panel.message = "社区调好的 .safetensors。它改唱法和音色，不改咬字。"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        form.loraScale = 1.0

        // ★ 2026-10-25：社区文件（ComfyUI / kohya 那套）用 `lora_A` / `lora_B` 命名，
        //   而本机引擎只认 `lora_down` / `lora_up` —— 差一个词，**而且它不报错**，
        //   `load_lora` 里 try/except 一吞，表现就是"挂了但没效果"。
        //   所以在选完这一步就把格式对好：同名 `-mlx` 版本在就直接用，不在就当场转。
        let base = file.deletingPathExtension()
        let converted = base.deletingLastPathComponent()
            .appendingPathComponent(base.lastPathComponent + "-mlx.safetensors")
        if file.lastPathComponent.hasSuffix("-mlx.safetensors")
            || FileManager.default.fileExists(atPath: converted.path) {
            form.loraPath = file.lastPathComponent.hasSuffix("-mlx.safetensors")
                ? file.path : converted.path
            exportMessage = "已挂上「\(file.lastPathComponent)」，下一次生成会带它"
            return
        }
        convertLoRA(file, to: converted)
    }

    /// 把社区格式的 LoRA 转成本机引擎认识的写法（几秒，112 MB 的文件也很快）。
    /// 用的是 `loras/convert_lora.py`（脚本在，逻辑都在那儿，界面只负责调用）。
    private func convertLoRA(_ file: URL, to converted: URL) {
        let python = client.root.appendingPathComponent("yue2-local/mlx-Yue/.venv/bin/python")
        let script = client.root.appendingPathComponent("loras/convert_lora.py")
        guard FileManager.default.fileExists(atPath: python.path),
              FileManager.default.fileExists(atPath: script.path) else {
            exportMessage = "这个 LoRA 的格式本机引擎不认，而转换工具没找到（loras/convert_lora.py）"
            return
        }
        loraBusy = true
        exportMessage = "正在把这件 LoRA 转成本机格式…"
        let p = Process()
        p.executableURL = python
        p.arguments = [script.path, file.path]
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.loraBusy = false
                if proc.terminationStatus == 0,
                   FileManager.default.fileExists(atPath: converted.path) {
                    self.form.loraPath = converted.path
                    self.exportMessage = "已挂上「\(file.lastPathComponent)」，下一次生成会带它"
                } else {
                    self.exportMessage = "这份 LoRA 转不了（可能不是 YuE2 的），换个文件试试"
                }
            }
        }
        do { try p.run() } catch {
            loraBusy = false
            exportMessage = "转换起不来：\(error.localizedDescription)"
        }
    }

    /// 面板里「保存并接上」：改过的 ABC 存进 `abc-cache/edited/`，
    /// 并让下一次「生成」照它唱。
    func saveEditedScore() {
        let text = ss2RepairedABC.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let dir = SheetSage2Paths.edited
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("edited-\(formatter.string(from: Date())).abc")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            ss2Status = "谱子存不下来：\(error.localizedDescription)"
            return
        }
        form.abcPath = url.path
        ss2Status = "改好的谱子已经接上，按「生成」就照它唱"
        ss2ShowsPanel = false
    }

    /// 送进引擎前的歌词：把界面上的延音下划线换成连字符 `-`。
    ///
    /// 用户 2026-10-24 听感定的：`_` 只在**界面**上用来标"一个字拖到下一个音"
    /// （读谱时由 Dorico 的「ー」换过来）；送进 YuE2 时用 `-`。
    /// 实测「连字符」那一版比"直接删掉"对齐得好，也保住了字数。
    static func lyricsForEngine(_ lyrics: String) -> String {
        lyrics.replacingOccurrences(of: "_", with: "-")
    }

    func generate() {
        guard !isRunning else { return }
        var request = form
        request.mode = mode.apiValue
        request.engine = engine.apiValue
        // 界面上的歌词原文先留一份：送引擎的版本要转换，歌词框里得原样保留
        //（用户 2026-10-24 定的：看到的是自己的中文词，送出去的是英文标记）。
        let uiLyrics = form.lyrics
        // 歌词里的 `_` 只是**界面上的延音记号**（读谱时把 Dorico 的「ー」换成它）。
        // YuE2 只认字、不认 `_`，送进去只会让它少一个音节 —— 所以这里剔掉。
        // 再把【主歌1】【副歌】这类中文结构标记换成引擎认的英文方括号标记。
        request.lyrics = SectionTags.toEngine(Self.lyricsForEngine(request.lyrics))
        // 两台引擎的「质量档」都落在 steps 上，含义各自不同：
        // ACE-Step 是扩散步数，YuE2 是声学合成的步数（8 快 / 32 标准）。
        request.steps = engine == .yue2 ? yue2Tier.steps : tier.steps
        request.duration = min(300, max(10, request.duration))
        // 这是「出整首」，不是「只出谱子」那一条路。
        request.planOnly = false
        // 顺手把这一首的名字定下来：列表上显示的那行字，同一个；
        // 脚本拿它给音频命名，界面拿它给输出目录命名。都在这一刻定死，
        // 免得生成完再去算、算出两样的名字。
        request.title = FileName.safe(Self.title(for: request))
        form = request
        // 歌词框恢复成用户写的中文原样（送出去的那份已经转好了）。
        form.lyrics = uiLyrics

        // 每按一次「生成」就新起一条 —— 不覆盖上一条。
        // 这样几个版本能并排比着听，也不会一失手把满意的那个冲掉。
        let item = GenerationItem(title: Self.title(for: request), request: request, state: "running")
        items.append(item)
        selectedID = item.id
        runningID = item.id
        client.start(request: request)
    }

    /// 「先出谱子」：只要乐谱，先不唱。约 40 秒（出整首要约 4 分半）。
    ///
    /// 为什么值得单摆一个按钮（用户 2026-10-12 提的）：YuE2 本来就能
    /// **先出乐谱再出歌** —— 谱子几十秒就有了，可原来非得等它唱完才看得到谱。
    /// 现在先出谱、你看过（要去 Dorico 改也行），再按「生成」照这份唱。
    ///
    /// 它只对 YuE2 有意义（ACE-Step 不出谱子），所以按钮只在 YuE2 那台显示。
    func generateScoreOnly() {
        guard !isRunning, engine == .yue2 else { return }
        var request = form
        request.mode = mode.apiValue
        request.engine = engine.apiValue
        request.steps = yue2Tier.steps
        // 同 generate()：界面留中文原文，送出去的是英文标记。
        let uiLyrics = form.lyrics
        request.lyrics = SectionTags.toEngine(Self.lyricsForEngine(request.lyrics))
        request.title = FileName.safe(Self.title(for: request))
        // ★ 这一趟要的是"重新写一份谱"，不是照着旧谱再写一遍 ——
        //   所以把「照外面那份谱子来」清掉。新的谱子出好之后，
        //   回调里会把它顶到这个位置上（那时才轮到"照它唱"）。
        request.abcPath = ""
        request.planOnly = true
        form = request
        form.lyrics = uiLyrics

        let item = GenerationItem(title: Self.title(for: request), request: request, state: "running")
        items.append(item)
        selectedID = item.id
        runningID = item.id
        client.start(request: request)
    }

    func stop() {
        client.stop()
        if let target = runningID ?? selectedID,
           let idx = items.firstIndex(where: { $0.id == target }) {
            items[idx].state = "idle"
        }
        runningID = nil
    }

    func togglePlay(_ item: GenerationItem) {
        guard let path = item.outputPath else { return }
        if playingID == item.id {
            player.stop()
            playingID = nil
            return
        }
        let device = AudioDeviceCatalog.resolve(savedName: preferredOutputDeviceName)
        if let problem = player.play(url: URL(fileURLWithPath: path), device: device) {
            exportMessage = problem
            playingID = nil
        } else {
            exportMessage = ""
            playingID = item.id
        }
    }

    /// 偏好设置里选的那块声卡（空 = 跟随系统）。
    /// 和 PreferencesView 里的 @AppStorage 共用同一个键，改完立刻生效。
    private var preferredOutputDeviceName: String {
        UserDefaults.standard.string(forKey: "outputDeviceName") ?? ""
    }

    func revealOutput(for item: GenerationItem) {
        // 有音频就定位音频；**只出了谱子**那一条就定位那份谱子 ——
        // 别让「显示文件」在没声音的条目上变成一个没反应的按钮（2026-10-12）。
        guard let path = item.outputPath ?? item.scorePath else { return }
        let url = URL(fileURLWithPath: path)
        // ★ 文件不在了就**明说**，别让访达退回去把父文件夹摊开
        //   ——用户 2026-10-24 反馈的正是这个："显示文件把文件夹给拉开来"。
        guard FileManager.default.fileExists(atPath: path) else {
            exportMessage = "这个文件不在了（可能被移动或改名）：\(url.lastPathComponent)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 「打开文件」：不经过访达，直接交给默认程序。
    ///
    /// 用户 2026-10-24 定的：「点了就打开，别只把文件夹摊开」。
    /// 音频给系统默认播放器；谱子优先交给 Dorico（.xml 的默认关联不一定是它）。
    func openOutput(for item: GenerationItem) {
        guard let path = item.outputPath ?? item.scorePath else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            exportMessage = "这个文件不在了（可能被移动或改名）：\(url.lastPathComponent)"
            return
        }
        if ["xml", "musicxml", "mxl"].contains(url.pathExtension.lowercased()) {
            openScore(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// 用 Dorico 打开谱子；没装 Dorico 就交给系统默认程序。
    ///
    /// ★ **不能靠系统关联**：本机实测 `.xml` 的候选程序里根本没有 Dorico
    ///   （只有豆包、备忘录之类），照关联走会打开错的程序。
    ///   所以按 bundle id → /Applications 里以 Dorico 开头的 App 逐级找。
    func openScore(_ url: URL) {
        for bundle in ["com.steinberg.dorico6", "com.steinberg.dorico5", "com.steinberg.dorico"] {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                NSWorkspace.shared.open([url], withApplicationAt: app,
                                        configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        if let apps = try? FileManager.default.contentsOfDirectory(atPath: "/Applications"),
           let name = apps.first(where: {
               $0.localizedCaseInsensitiveContains("Dorico") && $0.hasSuffix(".app")
           }) {
            let app = URL(fileURLWithPath: "/Applications/" + name)
            NSWorkspace.shared.open([url], withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration())
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openOutputFolder() {
        let dir = client.outputRoot
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    func chooseAudio(for mode: GenerationMode) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = mode == .repaint ? "选一段要重绘的音频" : "选一段参考音频"
        if panel.runModal() == .OK, let url = panel.url {
            if mode == .repaint { form.srcAudio = url.path } else { form.refAudio = url.path }
        }
    }

    // MARK: 导出

    /// 把生成结果导出成 MP3 或 WAV。转换交给 scripts/export_audio.sh，
    /// 界面只负责问路径、报结果 —— 那条脚本 Composer Assistant 也能直接调。
    func export(_ item: GenerationItem, as format: ExportFormat) {
        guard let source = item.outputPath, FileManager.default.fileExists(atPath: source) else {
            exportMessage = "这条还没有可导出的文件"
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出为 \(format.rawValue)"
        panel.message = format.detail
        panel.nameFieldStringValue = "\(item.title).\(format.ext)"
        panel.allowedContentTypes = [format == .mp3 ? UTType.mp3 : UTType.wav]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let script = client.root.appendingPathComponent("scripts/export_audio.sh").path
        let sourcePath = source
        let destPath = dest.path
        let ext = format.ext
        let label = format.rawValue
        exporting = true
        exportMessage = "正在导出 \(label)…"

        Task.detached { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [script, "--input", sourcePath, "--output", destPath, "--format", ext]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            var output = ""
            var failure = ""
            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                output = String(data: data, encoding: .utf8) ?? ""
                if proc.terminationStatus != 0 { failure = output }
            } catch {
                failure = error.localizedDescription
            }
            let ok = failure.isEmpty
            let note = ok
                ? "已导出：\(destPath.split(separator: "/").last.map(String.init) ?? destPath)"
                : (output.isEmpty ? failure : output.trimmingCharacters(in: .whitespacesAndNewlines))
            await MainActor.run {
                self?.exporting = false
                self?.exportMessage = note
            }
        }
    }

    // MARK: 送进 ACE Studio

    /// 把这一首的**音频 + 谱子**一起送进 ACE Studio —— 用户 2026-10-13 要的
    /// 「C.S. 和 ACE 的草稿传输。支持音频和 musicxml」。
    ///
    /// 以前这一步是他**手动拖文件**：在访达里翻出那一首的 flac 和 xml，逐个拖进 ACE。
    ///
    /// 谱子走 MusicXML 是有原因的（他的原话：「**ACE 认歌词和速度特别准通过 xml**」）——
    /// 2026-10-13 拿真文件在 ACE 2.1.8 上量过：导进去之后 `clip lyrics` 报 30 句、
    /// 第一句一字不差，`tempo get` 报 143（正是谱面速度）。
    /// 机制和坑都写在 `ACEDraftTransfer` 顶上，这里只负责把料备齐、把结果写回界面。
    /// 把**谱子**送进 ACE Studio（人声进唱轨，带歌词与速度）。
    ///
    /// 用户 2026-10-13 原话：「直接可以改成 **把谱子送到 ace** 以及 **将音频送到 ace**」
    /// —— 他要的是**两件分开的事**，不是"一下送两样"：
    /// 常见情形是谱子改过了、音频还是旧的（或者反过来），那就只补送一样。
    func sendScoreToACE(_ item: GenerationItem) {
        // 谱子只要 MusicXML。手上只有 ABC 时**就地从它转一份** ——
        // 那条转换路 `ScoreFiles` 早就通了，产物落在原来那份旁边。
        send(item, score: try? ScoreFiles.scoreURL(for: item, format: .xml), audio: nil,
             missing: "这一首还没有谱子。")
    }

    /// 把**音频**（草稿的 flac）送进 ACE Studio —— 落成一条音频轨，给他当参考。
    func sendAudioToACE(_ item: GenerationItem) {
        let audio = item.outputPath.flatMap {
            FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil
        }
        send(item, score: nil, audio: audio,
             missing: "这一首还没有音频。")
    }

    /// 把**拆轨的 MIDI** 送进 ACE Studio（2026-10-25 加的）。
    ///
    /// 跟「谱子 → ACE」不是一回事：谱子送进去是**一条唱轨**（带词），
    /// MIDI 送进去是**每条源轨一条通用 MIDI 轨**（默认钢琴，当参考/继续改）。
    /// MIDI 里原来的轨道名，ACE 不会自己拿去做轨道名 —— 脚本里补了这一步。
    func sendMIDIToACE(_ item: GenerationItem) {
        send(item, score: nil, midi: item.midiURL, audio: nil,
             missing: "这一首还没有 MIDI。")
    }

    /// 把**拆轨的 MIDI** 送进 Live（2026-10-25 用户要的：
    /// 「顺便加一个送MIDI到live的按钮」）。
    ///
    /// 跟「生成完自动送」那条不同：那条送的是**整首音频**，落在一条音频轨上；
    /// 这条送的是 MIDI，**每条源轨在 Live 里各建一条 MIDI 轨**，轨名照原名。
    /// Live 没连上时**不静默**（用户是主动按的，得知道为什么没动）。
    func sendMIDIToLive(_ item: GenerationItem) {
        guard let midi = item.midiURL else {
            transferOK = false
            transferMessage = "这一首还没有 MIDI。"
            return
        }
        guard liveState == .connected else {
            transferOK = false
            transferMessage = "先连上 Live，再把 MIDI 送过去。"
            return
        }
        guard !transferring else { return }
        transferring = true
        transferOK = nil
        transferMessage = "正在把 MIDI 送进 Live…"
        Task.detached { [weak self] in
            let result = LiveTransfer.sendMIDI(midi)
            await MainActor.run {
                self?.transferring = false
                self?.transferOK = result.ok
                self?.transferMessage = result.message
            }
        }
    }

    /// 把这一首送进 Musio Studio（2026-11-03）。
    ///
    /// 前提：Studio 开着、设置里的 Agents 开关打开；桥在 `musio-bridge/musio_bridge.py`。
    /// 音频落在 Studio 的**光标处**；MIDI 只放声部，不带它自己的速度。
    /// 有音频先送音频，没有就送 MIDI。
    func sendToMusio(_ item: GenerationItem) {
        guard !transferring else { return }
        let audio = item.outputPath.flatMap {
            FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil
        }
        let midi = item.midiURL
        guard audio != nil || midi != nil else {
            transferOK = false
            transferMessage = "这一首既没有音频也没有 MIDI。"
            return
        }
        transferring = true
        transferOK = nil
        transferMessage = "正在往 Musio Studio 送…"
        let title = item.title
        Task.detached { [weak self] in
            let result: MusioTransferResult
            if let audio {
                result = MusioTransfer.sendAudio(audio, title: title)
            } else {
                result = MusioTransfer.sendMIDI(midi!, title: title)
            }
            await MainActor.run {
                self?.transferring = false
                self?.transferOK = result.ok
                self?.transferMessage = result.message
            }
        }
    }

    /// 把这一首的**音频和 MIDI** 送到「灵感路由-交接」文件夹（2026-10-29）。
    ///
    /// 对面是 Waveform（Tracktion 的免费 DAW）。它没有"从外部往当前工程插素材"
    /// 的接口，所以这座桥只做到**移交素材**：复制到一个固定文件夹、把访达打开，
    /// 用户在 Waveform 里拖进工程。别对外说成"一键插进轨道"。
    ///
    /// 不覆盖同名文件（可能刚用过上一版），撞名就加序号。
    func sendToWaveform(_ item: GenerationItem) {
        let audio = item.outputPath.map { URL(fileURLWithPath: $0) }
        let result = WaveformBridge.send(title: item.title,
                                         audio: audio,
                                         midi: item.midiURL)
        transferOK = result.ok
        transferMessage = result.message
    }

    /// 把 **Live 里选中的那个 clip** 送进 ACE Studio（2026-10-18 用户要的那座桥）。
    ///
    /// 跟上面两个按钮的区别：那两个送的是**列表里选中的这一首**；
    /// 这个送的是**Live 里选中的那一段** —— 分轨后的音频、或者转好的 MIDI。
    /// 干活的是 `scripts/live_to_ace.py`（Live 那边只多用了一个只读命令）。
    func sendLiveClipToACE() {
        guard !transferring else { return }
        transferring = true
        transferOK = nil
        transferMessage = "正在把 Live 里选中的 clip 送进 ACE…"

        Task.detached { [weak self] in
            let result = LiveClipTransfer.send()
            await MainActor.run {
                self?.transferring = false
                self?.transferOK = result.ok
                self?.transferMessage = result.message
            }
        }
    }

    /// 反方向：把 **ACE 里选中的轨**渲染出来，送进 Live（2026-10-18）。
    ///
    /// 用户的原话是「在 Live 里分音轨是不要钱的」—— 所以 ACE 里唱好的东西
    /// 拿回 Live 分轨、循环、编曲，是常走的一条路。渲染本身要真实时间，
    /// 所以这里会等一会儿（脚本里 `--wait`）。
    func sendACEClipToLive() {
        guard !transferring else { return }
        transferring = true
        transferOK = nil
        transferMessage = "正在让 ACE 渲染选中的轨、再送进 Live…（要等一会儿）"

        Task.detached { [weak self] in
            let result = ACEClipTransfer.send()
            await MainActor.run {
                self?.transferring = false
                self?.transferOK = result.ok
                self?.transferMessage = result.message
            }
        }
    }

    /// 几件分开的动作用的同一套壳：状态、线程、回报都在这儿，免得写几遍。
    ///
    /// `midi` 有默认值 —— 谱子和音频那两条老路不用改，MIDI 那条自己传。
    private func send(_ item: GenerationItem, score: URL?, midi: URL? = nil,
                      audio: URL?, missing: String) {
        guard !transferring else { return }
        guard score != nil || audio != nil || midi != nil else {
            transferOK = false
            transferMessage = missing
            return
        }

        transferring = true
        transferOK = nil
        transferMessage = "正在往 ACE Studio 送…（它没开着的话，我会先把它打开）"

        let payload = ACEDraftTransfer.Payload(audio: audio, score: score,
                                               midi: midi, title: item.title)
        Task.detached { [weak self] in
            let result = ACEDraftTransfer.send(payload)
            await MainActor.run {
                self?.transferring = false
                self?.transferOK = result.ok
                self?.transferMessage = result.message
            }
        }
    }

    // MARK: - 连 Live（2026-10-17 用户要的）

    /// 常驻状态监视（3 秒一次）和点击后的等待（0.5 秒一次）。
    private var liveTimer: Timer?
    private var linkTimer: Timer?
    private var linkStarted: Date?

    /// 两边都开着就**自动连**：Live 那边的控制面一加载，这边 3 秒内就会亮成已连。
    ///
    /// 2026-10-17 用户追加：**启动时探一下 Live 开没开**，但**不替用户打开** ——
    /// 原话：「加一根探针，看一下 live 是不是开着。如果没开着，就照常启动。
    /// 如果用户待一会儿想开 live 的时候，可以点 LINK LIVE 直接打开 live。」
    /// ⇒ 探针只负责把按钮状态摆对；开 Live 是用户按「连 Live」的事。
    func startLiveWatcher() {
        liveTimer?.invalidate()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshLiveState()
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer

        // 只探测，不自动开 Live。
        refreshLiveState()
    }

    /// 静默问一次（不改按钮以外的任何东西）。
    func refreshLiveState() {
        guard !linkingLive else { return }
        if !LiveLink.isLiveRunning() {
            liveState = .notRunning
            return
        }
        Task.detached { [weak self] in
            let ok = LiveLink.ping()
            await MainActor.run {
                guard let self, !self.linkingLive else { return }
                self.liveState = ok ? .connected : .noBridge
            }
        }
    }

    /// 按钮那一下：没连上就打开 Live，然后一直等到连上（最多 30 秒）。
    func linkLive() {
        if linkingLive { return }
        Task.detached { [weak self] in
            let ok = LiveLink.ping()
            await MainActor.run {
                guard let self else { return }
                if ok {
                    self.liveState = .connected
                    self.liveMessage = "已经连着 Live 了。"
                } else {
                    self.beginLinking()
                }
            }
        }
    }

    private func beginLinking() {
        linkingLive = true
        liveState = .connecting
        linkStarted = Date()
        if LiveLink.isLiveRunning() {
            liveMessage = "正在找 Live 的桥…（第一次要等它加载控制面）"
        } else {
            liveMessage = "正在打开 Live…"
            LiveLink.openLive()
        }
        linkTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tickLink()
        }
        RunLoop.main.add(timer, forMode: .common)
        linkTimer = timer
    }

    private func tickLink() {
        Task.detached { [weak self] in
            let ok = LiveLink.ping()
            let running = LiveLink.isLiveRunning()
            await MainActor.run {
                guard let self, self.linkingLive else { return }
                if ok {
                    self.finishLinking(success: true, running: true)
                } else if Date().timeIntervalSince(self.linkStarted ?? Date()) > 45 {
                    self.finishLinking(success: false, running: running)
                }
            }
        }
    }

    private func finishLinking(success: Bool, running: Bool) {
        linkTimer?.invalidate()
        linkTimer = nil
        linkingLive = false
        if success {
            liveState = .connected
            liveMessage = "已连上 Live。"
        } else if running {
            liveState = .noBridge
            liveMessage = "Live 开了，但没找到桥 —— 在 Live 的 Settings → Link, Tempo & MIDI → Control Surface 里选一次 AbletonMySongwriter。"
        } else {
            liveState = .notRunning
            liveMessage = "Live 没打开。"
        }
    }

    // MARK: - 生成完自动送进 Live

    /// 用户 2026-10-17 选的「1」：生成完自动送。
    ///
    /// 先 ping 一下桥 —— **没连着 Live 就静默不送**（不弹错、不打扰）。
    /// 送的动作在后台跑，结果写回 `liveMessage`。
    private func autoSendToLive(output: String) {
        let folder = URL(fileURLWithPath: output).deletingLastPathComponent()
        Task.detached { [weak self] in
            guard LiveLink.ping() else { return }
            let result = LiveTransfer.send(folder: folder)
            await MainActor.run {
                guard let self else { return }
                self.liveMessage = result.ok
                    ? "已送进 Live：\(result.message)"
                    : "没送进 Live：\(result.message)"
            }
        }
    }
}

// MARK: - 主界面

struct ContentView: View {
    /// 状态由 `LocalMusicApp` 持有并传进来 —— 菜单栏那几条要驱动同一份状态
    ///（2026-10-12 加「文件」菜单时改的；原先它是这个视图自己的 `@StateObject`）。
    @ObservedObject var vm: AppViewModel
    @Environment(\.openSettings) private var openSettings
    /// 「输入歌词」那个按钮打开的小窗。写在视图里，不进 ViewModel ——
    /// 它纯粹是界面开合，跟生成状态无关。
    @State private var showsLyricsEditor = false
    /// 「换嗓子」的小窗（2026-10-25）。同样只是界面开合。
    @State private var showsVoiceSwap = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Palette.stroke).frame(width: 1)
            if vm.showJianpu {
                JianpuView { vm.showJianpu = false }
            } else {
                detail
            }
        }
        .frame(minWidth: 960, minHeight: 680)
        .background(Palette.windowBG)
        .preferredColorScheme(.dark)
        .onAppear(perform: selfCheckIfRequested)
        // 把当前表单写回信箱，等 Composer Assistant 来取（见 `BridgeInbox`）。
        // 防抖在 `scheduleBridgeWriteBack` 里 —— 连着敲字只落最后一次。
        .onChange(of: vm.form.prompt) { _, _ in vm.scheduleBridgeWriteBack() }
        .onChange(of: vm.form.lyrics) { _, _ in vm.scheduleBridgeWriteBack() }
        .sheet(isPresented: $vm.ss2ShowsPanel) { scoreEditPanel }
        .sheet(isPresented: $showsLyricsEditor) { lyricsEditorPanel }
        .sheet(isPresented: $showsVoiceSwap) { VoiceSwapView() }
        .sheet(isPresented: $vm.showsInstrumentPicker) { instrumentPickerPanel }
    }

    /// 自检开关（都只影响带环境变量启动的那一次，正常双击完全不受影响）：
    ///   CS_AUTORUN=1       界面自己按下「生成」，用来验证整条生成链路
    ///   CS_ENGINE=yue2     启动就切到 YuE2 那台引擎（不带 AUTORUN 就只是切过去，
    ///                      用来给手册拍图；带上 AUTORUN 才会真的跑一次）
    ///   CS_OPEN_SETTINGS=1 启动就打开偏好设置，用来验证声卡列表
    ///   CS_OPEN_HISTORY=1  启动就打开《版本历史》，用来核对窗口排版
    ///   CS_PLAY_TEST=1     启动就播放最新一条，用来验证「指定声卡」是否真的切过去了
    ///   CS_EXPORT_SCORE=xml|abc   启动就把选中那一首的谱子导出去（验证「文件」菜单那条）
    ///                             ⚠️ 配合 `CS_SCORE_DIR` 指到工作区里 ——
    ///                             跑自检的沙箱写不了「文稿」，不指就只能看到失败
    ///   CS_IMPORT_SCORE=<文件>    启动就导入一份谱子；
    ///                             `CS_IMPORT_ACTION=resing` 则照它重唱（默认只转格式）
    ///   CS_LYRICS_OVERRIDE=<词>   跟上面那条合用：先"改"一下歌词框，再导入谱子 ——
    ///                             钉住"重唱用的是框里这份词，不是那首的旧词"
    ///                             （`\n` 会换成换行）
    ///   CS_BRIDGE_PROBE=1  把表单填成 `CS_BRIDGE_PROMPT` / `CS_BRIDGE_LYRICS`
    ///                      给的内容，验证「CS PROMPT」那条桥里**写回**的一半
    ///                      （本程序 → Composer Assistant，落进信箱文件）
    ///   CS_SCORE_ONLY=1    启动就按「先出谱子」——只出谱、不唱（约 40 秒），
    ///                      验证「先出乐谱」这条路，以及出完之后那份谱子
    ///                      有没有被顶到「这次照它唱」的位置
    ///   CS_SCORE_THEN_SING=1  先出谱子，出完**自动接着按「生成」**照它唱。
    ///                      这条最接近用户的实际用法（先谱后歌），只是慢
    ///                      ——两段加起来约五分钟
    ///   CS_DEMO=1          跟上面那条合用：把表单填成一段**像样的词**，
    ///                      跑出来的东西是要进《使用手册》截图的
    ///                      （平常自检用最短的两句，跑得快）
    /// 自检脚手架：每秒看一眼「忙完了没」，忙完就回调。
    ///
    /// 为什么用轮询而不是 async/await：这几条路原来的签名是同步的（界面按钮直接调），
    /// 为了自检去改签名会把界面那一圈都带着改。轮询在这里**只是测试脚手架**，
    /// 不进产品路径 —— 正常双击启动时这几行一次都不会跑。
    private func pollUntilDone(maxSeconds: Int,
                              busy: @escaping () -> Bool,
                              onDone: @escaping () -> Void) {
        var waited = 0
        func tick() {
            waited += 1
            if busy() && waited < maxSeconds {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: tick)
            } else {
                onDone()
            }
        }
        // 先等一秒 —— 任务刚起那一下 busy 可能还没置上
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: tick)
    }

    private func selfCheckIfRequested() {
        let env = ProcessInfo.processInfo.environment

        // ── 欢迎界面 ──
        //
        // 用户 2026-10-12 选的「每次打开露一下」：约两秒半自己淡出，点一下／Esc 立刻进。
        // 它纯粹是个花瓶（他自己也这么说），所以**绝不能给自检和抓图添乱**：
        // 跑任何别的自检开关时都不开它；想专门看它就 `CS_WELCOME_ONLY=1`。
        let otherChecks = ["CS_AUTORUN", "CS_ENGINE", "CS_OPEN_SETTINGS", "CS_OPEN_HISTORY", "CS_OPEN_JIANPU",
                           "CS_PLAY_TEST", "CS_EXPORT_SCORE", "CS_IMPORT_SCORE",
                           "CS_CONVERT_SCORE", "CS_CONVERT_TO", "CS_CONVERT_PANEL",
                           "CS_CONVERT_NOTE",
                           "CS_SCORE_ONLY", "CS_SCORE_THEN_SING", "CS_SCORE_PROBE",
                           "CS_MIDI_RENAME", "CS_PLAY_SCORE",
                           "CS_TRANSCRIBE_AUDIO", "CS_PLAY_SCORE_UI",
                           "CS_RENAME_TEST", "CS_SEND_TO_ACE",
                           "CS_WAVEFORM_BRIDGE"]
        let runningOtherCheck = otherChecks.contains { env[$0] != nil }
        if env["CS_WELCOME_ONLY"] == "1" {
            WelcomeWindow.shared.show()
        } else if env["CS_NO_WELCOME"] != "1", !runningOtherCheck {
            // 让主窗口先露出来再叠上去 —— 否则启动那一下会看见它闪。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                WelcomeWindow.shared.show()
            }
        }

        // 工作室取谱自检：`CS_STUDIO_ABC_PROBE=<标题子串>` —— 选中那一首，
        // 打印它交给工作室的谱有多少字节（**不真打开浏览器**，省得弹窗）。
        if let probe = env["CS_STUDIO_ABC_PROBE"], !probe.isEmpty {
            var line = ""
            if let pick = vm.items.first(where: { $0.title.contains(probe) }) {
                vm.selectedID = pick.id
                let abc = vm.studioABC() ?? ""
                line = "[CS] MIR Studio 取谱 —— 「\(pick.title)」 \(abc.count) 字节"
                    + "（引擎 \(pick.request.engine)）\n"
            } else {
                line = "[CS] MIR Studio 取谱 —— 列表里没有含「\(probe)」的条目\n"
            }
            // 用 stderr 写：`print` 在重定向时有缓冲，进程被 kill 就丢了。
            FileHandle.standardError.write(Data(line.utf8))
        }
        if env["CS_STUDIO_DIR_PROBE"] == "1" {
            let line = "[CS] MIR Studio 路径 —— " + ScoreStudioClient.shared.probePaths() + "\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        // 「最近的作品」看哪个文件夹（2026-10-25）：真写一次，把写进去的内容报出来。
        if env["CS_STUDIO_ROOT_PROBE"] == "1" {
            let line = "[CS] MIR Studio 输出根 —— " + ScoreStudioClient.shared.probeWriteRoot() + "\n"
            FileHandle.standardError.write(Data(line.utf8))
        }

        if env["CS_OPEN_JIANPU"] == "1" {
            vm.showJianpu = true
        }
        if env["CS_OPEN_SETTINGS"] == "1" {
            openSettings()
        }
        if env["CS_OPEN_HISTORY"] == "1" {
            VersionHistoryWindow.shared.open()
        }
        // 「CS PROMPT」那条桥里**写回**这一半（本程序 → Composer Assistant）：
        // 把表单填成命令行给的内容，触发 onChange → 落进信箱。
        // 加它的理由：那半边的触发点是"用户在框里打字"，我点不动键盘 ——
        // 有了这个开关，整条能从头跑一遍，跑完去看信箱文件就知道写没写。
        if env["CS_BRIDGE_PROBE"] == "1" {
            vm.form.prompt = env["CS_BRIDGE_PROMPT"] ?? "bridge-probe style"
            vm.form.lyrics = (env["CS_BRIDGE_LYRICS"] ?? "bridge-probe lyrics")
                .replacingOccurrences(of: "\\n", with: "\n")
        }
        // 「送进 ACE Studio」这条**必须能自己跑一遍**：它跨进程去调 ACE 的命令行工具，
        // 而 ACE 那边的行为（歌词进没进去、速度采纳没有）只有真跑一次才知道。
        // 判据写在终端那两行 `[CS] ACE 传输…` 上；配合 ACE 那边的
        // `clip lyrics` / `tempo get` 回读，才知道到底送对了没有。
        // `CS_SEND_TITLE=<子串>` 可以指定送哪一首（不指定就送列表里第一条有产物的）——
        // 因为"哪一条有歌词"是因作品而异的，验歌词时得能点名。
        // `CS_SEND_WHAT=score|midi|audio` 只送一样（不写就谱子+音频都送）——
        // 界面上是**几个按钮**，自检得能分别验；MIDI 那条也算一样。
        if env["CS_SEND_TO_ACE"] == "1" {
            let wanted = env["CS_SEND_TITLE"] ?? ""
            let pick = vm.items.first {
                ($0.isFinished || $0.isScoreOnly)
                    && (wanted.isEmpty || $0.title.contains(wanted))
            }
            if let pick {
                vm.selectedID = pick.id
                let what = env["CS_SEND_WHAT"] ?? "both"
                print("[CS] ACE 传输 —— 送「\(pick.title)」（\(what)）"
                    + "（音频=\(pick.outputPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "无")"
                    + " / 谱子=\(pick.scoreURL?.lastPathComponent ?? "无")"
                    + " / MIDI=\(pick.midiURL?.lastPathComponent ?? "无")）")
                switch what {
                case "score": vm.sendScoreToACE(pick)
                case "midi": vm.sendMIDIToACE(pick)
                case "audio": vm.sendAudioToACE(pick)
                default:
                    vm.sendScoreToACE(pick)
                    // 两样都送时，第二样等第一样跑完 —— 两次传输共用一个
                    // `transferring`/`transferMessage`，叠着来会互相冲掉。
                    Task { @MainActor in
                        let deadline = Date().addingTimeInterval(180)
                        while vm.transferring, Date() < deadline {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                        let first = vm.transferMessage
                        vm.sendAudioToACE(pick)
                        while vm.transferring, Date() < deadline {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                        print("[CS] ACE 传输结果 —— \(first)；\(vm.transferMessage)")
                    }
                    return
                }
                Task { @MainActor in
                    // 等它跑完（探活 + 导入 + 回读，几十秒封顶），再把结果打出来。
                    let deadline = Date().addingTimeInterval(180)
                    while vm.transferring, Date() < deadline {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    print("[CS] ACE 传输结果 —— \(vm.transferMessage)")
                }
            } else {
                print("[CS] ACE 传输 —— 列表里没有可送的条目")
            }
        }
        // 送 Live 的 MIDI：`CS_SEND_TO_LIVE=midi` + `CS_SEND_TITLE=<子串>`。
        // 跟 ACE 那条一样的道理 —— 界面上的按钮点不到，得能从头跑一遍。
        if env["CS_SEND_TO_LIVE"] == "midi" {
            let wanted = env["CS_SEND_TITLE"] ?? ""
            let pick = vm.items.first {
                ($0.isFinished || $0.isScoreOnly)
                    && (wanted.isEmpty || $0.title.contains(wanted))
            }
            if let pick {
                vm.selectedID = pick.id
                print("[CS] MIDI 送 Live —— 送「\(pick.title)」"
                    + "（MIDI=\(pick.midiURL?.lastPathComponent ?? "无")）")
                vm.sendMIDIToLive(pick)
                Task { @MainActor in
                    let deadline = Date().addingTimeInterval(120)
                    while vm.transferring, Date() < deadline {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    print("[CS] MIDI 送 Live 结果 —— \(vm.transferMessage)")
                }
            } else {
                print("[CS] MIDI 送 Live —— 列表里没有可送的条目")
            }
        }
        // 「文件」菜单那几条：菜单我点不动（读菜单要「辅助功能」权限，本机没给，
        // 见 ROADMAP 那条），所以动作各留一个开关，从命令行把整条走一遍。
        if let format = env["CS_EXPORT_SCORE"], !format.isEmpty {
            // 导出要有落脚的地方（`exportScore` 会要求选中一首）。
            // **自检里没人能点左边那一列**，所以自动挑一首**带谱子的 YuE2 作品** ——
            // 只有真的在跑导出自检时才这么做，人用走不到这一句。
            // （存哪可以另指：`CS_SCORE_DIR` 会把那个固定文件夹换掉，别弄脏他真正的「文稿」。）
            if vm.selectedID == nil,
               let pick = vm.items.first(where: { $0.isYue2 && $0.scoreBase != nil }) {
                vm.select(pick)
            }
            vm.exportScore(as: format == "abc" ? .abc : .xml)
        }
        if let path = env["CS_IMPORT_SCORE"], !path.isEmpty {
            let file = URL(fileURLWithPath: path)
            // `CS_IMPORT_ASNEW=1` = 先按一下「新建一首」（左边清空、表单清空），
            // 再导入 —— **验的就是空项目那条新路**（用户 2026-10-13 卡住的那条）。
            // ⚠️ 不加这个开关时，启动会自动选中第一首（`reloadHistory`），
            //    于是走的是"有选中 → 立刻重唱"，那条会**真的开跑**；空项目这条不会。
            if env["CS_IMPORT_ASNEW"] == "1" { vm.addNew() }
            // `CS_LYRICS_OVERRIDE` = 模拟"我自己先改了歌词，再导入谱子"。
            // 用来钉住一件事：重唱到底用**框里这份词**还是**那首的旧词**
            //（2026-10-12 发现旧行为会盖掉用户刚改的词，修完之后加的自检）。
            if let lyrics = env["CS_LYRICS_OVERRIDE"], !lyrics.isEmpty {
                vm.form.lyrics = lyrics.replacingOccurrences(of: "\\n", with: "\n")
            }
            if env["CS_IMPORT_ACTION"] == "resing" {
                // ★ 2026-10-13：`resing` **不再要求先选中一首**（空项目也能用了，
                //   见 `ScoreFiles.resing`）⇒ 这里原先"自检时自动选第一首"那段**去掉了**。
                //   留着它，自检就永远走「有选中」那条老路，
                //   **用户真正卡住的那条（空项目）一次都验不到**。
                //   现在自检跑的就是他遇到的那一种：左边一手都没选。
                vm.resing(with: file)
                // 把"读到了什么、说了什么"打到终端 —— 卡片在界面上、终端里看不见，
                // 而这两句正是要给人看的东西，得能核（本项目的老规矩）。
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let read = vm.scoreReading?.summary ?? "（什么都没读出来）"
                    FileHandle.standardError.write(Data(
                        "【导入自检】读到的：\(read)\n【导入自检】说的：\(vm.exportMessage)\n".utf8))
                }
            } else {
                vm.convertImported(file)
            }
        }
        // 底部那两个转换按钮（纯粹转格式）。方向按后缀自动定；
        // 目标文件已存在时会弹「会覆盖」那一问 —— 自检时用 `CS_CONVERT_YES=1` 跳过。
        if let path = env["CS_CONVERT_SCORE"], !path.isEmpty {
            let file = URL(fileURLWithPath: path)
            let target: ScoreFormat = (ScoreFormat.of(file) == .xml) ? .abc : .xml
            // `CS_CONVERT_TO=<路径>` = 走「转完搬到指定位置」那条新路（2026-10-13 加）。
            // 保存面板本身点不动（读面板要辅助功能权限，本机没给），但**搬运那一段
            // 逻辑必须能自动验** —— 给它一个命令行入口，这是本项目的老做法。
            let dest = env["CS_CONVERT_TO"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            vm.convert(file, to: target, placing: dest, placeAlreadyConfirmed: dest != nil)
            // 把界面上那句「转好了 …（放在哪）」打到终端。
            // 它在详情区的**最底下**、抓图看不到（窗口比内容矮，滚动条在底端），
            // 而这句正是要给人看的话 —— 得能核（2026-10-13）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                FileHandle.standardError.write(Data("【转换自检】\(vm.exportMessage)\n".utf8))
            }
        }
        // 只看那个「放哪儿」的保存面板长什么样（抓图用）。
        // 它平常要点按钮才出来，而按钮点不动（读菜单/面板要辅助功能权限，本机没给）
        // —— 给它一条**直达**入口：走到"挑完源文件之后"那一步就停下等你操作。
        // ⚠️ 它会**模态地卡住**（就是要这样才抓得到图），看完记得把程序关掉。
        if let path = env["CS_CONVERT_PANEL"], !path.isEmpty {
            let file = URL(fileURLWithPath: path)
            let target: ScoreFormat = (ScoreFormat.of(file) == .xml) ? .abc : .xml
            vm.convertPicked(file, to: target)
        }
        // 只看那句「这个文件夹里没有 XX 文件」的防呆提示（两个方向各打一条）。
        // 面板点不动，但"点错时到底会不会说话、说得对不对"能验 —— 顺带记一笔：
        // 这条是因为用户说「找不到点 ABC 文件」才加的（他很可能点反了按钮）。
        if let dir = env["CS_CONVERT_NOTE"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir)
            for target in [ScoreFormat.abc, ScoreFormat.xml] {
                let source = (target == .xml) ? "abc" : "xml"
                let text = ScoreFiles.nothingToPickText(in: url, source: source, target: target)
                FileHandle.standardError.write(Data(
                    "【防呆自检】要转成 \(target.label)：\(text ?? "（有得挑，不会说话）")\n".utf8))
            }
        }
        // 读谱自检：给一份谱子，把读出来的东西打到终端。
        //
        // 为什么单独留这一个入口：它验的是「解析器读得对不对」，跟界面无关 ——
        // 拿一份真的 Dorico 谱子一跑，歌词、速度、拍号、调号、和弦全在终端里，
        // 对不对一眼就看出来了。**出了界面之外没法验的东西，就给它一条命令行入口**
        // （本项目的既有做法，见 ROADMAP 里那一串 `CS_*` 开关）。
        if let path = env["CS_SCORE_PROBE"], !path.isEmpty {
            var out = "\n──────── 读谱自检 ────────\n"
            do {
                let r = try ScoreReader.read(URL(fileURLWithPath: path))
                out += "文件：\(URL(fileURLWithPath: path).lastPathComponent)\n"
                out += "标题：\(r.title)\n"
                out += "作者：\(r.creators.joined(separator: " / "))\n"
                out += "摘要：\(r.summary)\n"
                func marks(_ list: [ScoreReading.Mark]) -> String {
                    // ABC 那边没有"第几小节"（它按行给）—— 空的时候别写「第小节」这种半句话。
                    list.map { $0.measure.isEmpty ? $0.text : "第\($0.measure)小节 \($0.text)" }
                        .joined(separator: "；")
                }
                out += "速度：\(marks(r.tempoMarks))\n"
                out += "拍号：\(marks(r.timeMarks))\n"
                out += "调号：\(marks(r.keyMarks))\n"
                out += "和弦：\(r.chords.count) 个 —— \(r.chords.prefix(12).joined(separator: " "))\n"
                out += "文字标记：\(marks(r.cueMarks))\n"
                out += "歌词：\(r.lyricLines.count) 行 / \(r.lyricCount) 字\n"
                for line in r.lyricLines { out += "    \(line)\n" }
            } catch {
                out += "读不出来：\(error.localizedDescription)\n"
            }
            out += "──────────────────────────\n"
            FileHandle.standardError.write(Data(out.utf8))
        }
        // 音频转 MIDI 的「补乐器名」自检：给一份 MIDI，改成标准名，再把每轨的名字打出来。
        //
        // 为什么要单独验它：改名是**直接改文件字节**的活（重写 Track Name 事件），
        // 一个字节算错整份 MIDI 就打不开了 —— 而这种错在界面上看不出来，
        // 只有拖进 DAW 才发现。所以给它一条命令行入口，跑一次就知道。
        if let path = env["CS_MIDI_RENAME"], !path.isEmpty {
            var out = "\n──────── MIDI 补名自检 ────────\n"
            let url = URL(fileURLWithPath: path)
            do {
                let names = try MIDITrackNames.annotate(url)
                out += "文件：\(url.lastPathComponent)\n"
                out += "有声部的轨：\(names.count) 条\n"
                // 文件里写英文、界面说中文 —— 两样都打出来，一眼能核对
                for (index, name) in names.enumerated() {
                    out += "    \(index + 1). \(name.english) ／ \(name.chinese)\n"
                }
            } catch {
                out += "没改成：\(error.localizedDescription)\n"
            }
            out += "────────────────────────────\n"
            FileHandle.standardError.write(Data(out.utf8))
        }
        // 「照谱奏」自检：给一份 MusicXML，读谱 → 渲染 wav，把账打在终端。
        //
        // 判据（人听之前先看数）：音符数、声部数、时长、速度，以及 wav 真的写出来了。
        // 产物路径用 `CS_PLAY_OUT` 指定，不指定就落在临时目录。
        if let path = env["CS_PLAY_SCORE"], !path.isEmpty {
            var out = "\n──────── 照谱奏自检 ────────\n"
            do {
                let score = try ScorePlayer.load(URL(fileURLWithPath: path))
                out += "文件：\(URL(fileURLWithPath: path).lastPathComponent)\n"
                out += "摘要：\(score.summary)\n"
                out += "声部：\(score.parts.map { $0.name.isEmpty ? "（无名）" : $0.name }.joined(separator: " / "))\n"
                out += "音色号：\(score.parts.map { String($0.program) }.joined(separator: ", "))\n"
                let destination = env["CS_PLAY_OUT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent("照谱奏自检.wav")
                let began = Date()
                try ScorePlayer.render(score, to: destination)
                let elapsed = Date().timeIntervalSince(began)
                let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
                let size = (attributes?[.size] as? Int) ?? 0
                out += "渲染：\(String(format: "%.1f", elapsed)) 秒，wav \(size) 字节\n"
                out += "产物：\(destination.path)\n"
            } catch {
                out += "没奏成：\(error.localizedDescription)\n"
            }
            out += "────────────────────────────\n"
            FileHandle.standardError.write(Data(out.utf8))
        }
        // 整条链路自检：**走界面那个方法本身**，不是绕开它。
        //
        // 为什么要这一层：下面几个自检验的是"命令能不能跑"，而这里验的是
        // 「按钮按下去之后到底成没成」—— 建输出文件夹、写 ABC、转 MusicXML、
        // 补 MIDI 名、状态那行写对没有。这些错了，自检不报、用户会撞上。
        //
        // `CS_TRANSCRIBE_MODE` 可填 `score` / `midi`（默认两个都拆）。
        if let path = env["CS_TRANSCRIBE_AUDIO"], !path.isEmpty {
            let mode = env["CS_TRANSCRIBE_MODE"] ?? "both"
            vm.transcribeAudio(URL(fileURLWithPath: path),
                               wantScore: mode != "midi",
                               wantMIDI: mode != "score")
            pollUntilDone(maxSeconds: 600) { vm.transcribeBusy } onDone: {
                let out = "\n【听写自检】\(vm.transcribeStatus)\n"
                FileHandle.standardError.write(Data(out.utf8))
                exit(0)
            }
        }
        // 同一个道理：「谱子出声」也走界面方法本身（含建目录、播放、状态）。
        if let path = env["CS_PLAY_SCORE_UI"], !path.isEmpty {
            vm.playScore(at: URL(fileURLWithPath: path))
            pollUntilDone(maxSeconds: 300) { vm.playBusy } onDone: {
                let out = "\n【照谱奏·界面自检】\(vm.playStatus)\n"
                    + "产物：\(vm.playOutput?.path ?? "（没有）")\n"
                FileHandle.standardError.write(Data(out.utf8))
                exit(0)
            }
        }
        // 「改改乐器」整条自检（2026-10-29）：
        //   CS_RENAME_TEST=<音频>          先正常拆一遍 MIDI
        //   CS_RENAME_INSTRUMENTS=a,b      再按这几样点名重拆（空 = 不点名重拆一遍）
        // 验的是「拆完 → 记下来源 → 勾选 → 重拆 → 状态那行写对没有」这条线，
        // 而不是"命令行能不能跑"（那条另有用例）。
        if let path = env["CS_RENAME_TEST"], !path.isEmpty {
            vm.transcribeAudio(URL(fileURLWithPath: path), wantScore: false, wantMIDI: true)
            pollUntilDone(maxSeconds: 600) { vm.transcribeBusy } onDone: {
                let first = vm.transcribeStatus
                let heard = vm.lastMIDIInstruments.joined(separator: ",")
                let wanted = (env["CS_RENAME_INSTRUMENTS"] ?? "")
                    .split(separator: ",").map(String.init)
                vm.pickedInstruments = Set(wanted)
                vm.retranscribeMIDIWithPicked()
                pollUntilDone(maxSeconds: 600) { vm.retranscribeBusy } onDone: {
                    let out = "\n【改乐器自检】\n"
                        + "第一次：\(first)\n"
                        + "它听到的（英文键）：\(heard)\n"
                        + "点名重拆：\(wanted.isEmpty ? "（不点名）" : wanted.joined(separator: ","))\n"
                        + "重拆后：\(vm.transcribeStatus)\n"
                    FileHandle.standardError.write(Data(out.utf8))
                    // 抓图用：CS_RENAME_PICKER=1 把勾选小窗也打开；CS_RENAME_HOLD=秒数 停住再看
                    if env["CS_RENAME_PICKER"] == "1" {
                        vm.pickedInstruments = Set(vm.lastMIDIInstruments)
                        vm.showsInstrumentPicker = true
                    }
                    let hold = Int(env["CS_RENAME_HOLD"] ?? "0") ?? 0
                    if hold > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(hold)) { exit(0) }
                    } else {
                        exit(0)
                    }
                }
            }
        }
        // 「送到 Waveform」自检（2026-10-29）：
        //   CS_WAVEFORM_BRIDGE=<文件>  把那个文件当成拆轨 MIDI 送一遍
        // 验的是复制、命名、打开访达，以及回报那句话写对没有。
        if let path = env["CS_WAVEFORM_BRIDGE"], !path.isEmpty {
            let result = WaveformBridge.send(title: "自检-桥",
                                             audio: nil,
                                             midi: URL(fileURLWithPath: path))
            let out = "\n【Waveform 桥自检】\(result.ok ? "成功" : "失败")：\(result.message)\n"
                + "文件夹：\(WaveformBridge.folder.path)\n"
            FileHandle.standardError.write(Data(out.utf8))
            exit(0)
        }
        // 引擎也能切回 ACE-Step（批量那条路的自检用它，因为它一版只要一分多钟）
        if env["CS_ENGINE"] == "acestep" {
            vm.engine = .aceStep
        }
        if env["CS_ENGINE"] == "yue2" {
            vm.engine = .yue2
            vm.yue2Tier = .fast
            // YuE2 那条链路要走 4 分半，自检时用一段短词，歌就短、几十秒能跑完 ——
            // 验的是「界面 → yue2_adapter.sh → YuE2 → 产物回到列表」这条线通不通，
            // 不是音质（音质由人听）。**只在真的跑自检时才动表单**，
            // 否则给手册拍图会拍到一段假歌词。
            if env["CS_AUTORUN"] == "1" || env["CS_SCORE_ONLY"] == "1" || env["CS_SCORE_THEN_SING"] == "1" {
                vm.form.prompt = "warm piano, soft female vocal, 88 BPM"
                vm.form.lyrics = "[Verse]\n这是自检用的两句词\n唱到这里就停\n"
            }
        }
        // 自检想验"自己的歌词"时（例如中文段标自动转英文），用它顶掉上面那段示例词。
        // `\n` 写成两字符，好从命令行传。
        if let lyrics = env["CS_LYRICS_OVERRIDE"], !lyrics.isEmpty {
            vm.form.lyrics = lyrics.replacingOccurrences(of: "\\n", with: "\n")
        }
        if env["CS_PLAY_TEST"] == "1", let item = vm.items.first(where: { $0.isFinished }) {
            vm.select(item)
            vm.togglePlay(item)
        }
        // 「先出谱子」那条路：先把引擎切过去（不切的话那个按钮根本不存在），
        // 再按下去 —— 它只写谱、不唱，约 40 秒。
        // `CS_SCORE_THEN_SING=1` 则出完谱子自动接着按「生成」照它唱。
        if env["CS_SCORE_ONLY"] == "1" || env["CS_SCORE_THEN_SING"] == "1" {
            vm.engine = .yue2
            vm.yue2Tier = .fast
            // `CS_DEMO=1` = 这次跑出来的东西**要进手册截图**，所以填一段像样的词；
            // 平常自检用最短的两句就够了（跑得快，验的是链路不是内容）。
            if env["CS_DEMO"] == "1" {
                vm.form.prompt = "warm piano, soft female vocal, 88 BPM"
                vm.form.lyrics = "[Verse]\n示例作品\n我数着回家的方向\n\n[Chorus]\n晚风替我唱\n那首没写完的歌\n"
            } else {
                vm.form.prompt = "warm piano, soft female vocal, 88 BPM"
                vm.form.lyrics = "[Verse]\n这是自检用的两句词\n唱到这里就停\n"
            }
            vm.autoSingAfterScore = env["CS_SCORE_THEN_SING"] == "1"
            guard !vm.isRunning else { return }
            vm.generateScoreOnly()
            return
        }
        guard env["CS_AUTORUN"] == "1" else { return }
        guard !vm.isRunning else { return }
        vm.generate()
    }

    // ---------------- 左栏：条目列表 ----------------

    private var sidebar: some View {
        VStack(spacing: 0) {
            Button {
                vm.addNew()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("新写一首").font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.accent))
            }
            .buttonStyle(.plain)
            .padding(12)

            Button {
                vm.showJianpu = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "music.note.list")
                    Text("MusicXML → 简谱").font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Palette.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.card))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if vm.items.isEmpty {
                Text("还没有曲子。\n在右边填好，按「生成」。")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(vm.items) { item in
                            row(for: item)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 236)
        .background(Palette.sidebar)
    }

    private func row(for item: GenerationItem) -> some View {
        let selected = vm.selectedID == item.id
        return Button {
            vm.select(item)
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(color(for: item.state))
                    .frame(width: 7, height: 7)
                Text(item.title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .foregroundStyle(selected ? Palette.textPrimary : Palette.textSecondary)
                Spacer(minLength: 0)
                if item.isFinished {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.accent)
                } else if item.isScoreOnly {
                    // 只出了谱子那一条 —— 右边给个谱号，一眼看得出它"还没唱"。
                    Image(systemName: "music.note.list")
                        .font(.system(size: 12))
                        .foregroundStyle(scoreOnlyColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Palette.accent.opacity(0.22) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        // 右键菜单（用户 2026-10-11 要的）：一个右键就能把这一首的文件调出来。
        // ★ 它**不要求先选中** —— 指到哪一条，菜单就是哪一条的。
        .contextMenu { menu(for: item) }
    }

    /// 左栏某一条的右键菜单。
    ///
    /// 菜单项**按状态给**：还没生成完的曲子没有文件可显示、也没有东西可导出，
    /// 那几项就不摆出来（而不是摆出来再变灰）。
    ///
    /// 顺序按「用户此刻最想干什么」排：把文件找出来 → 看整个文件夹 →
    /// 听一下 → 导出去。
    @ViewBuilder
    private func menu(for item: GenerationItem) -> some View {
        if item.isFinished {
            Button("在文件夹中显示") { vm.revealOutput(for: item) }
        }
        Button("打开输出文件夹") { vm.openOutputFolder() }

        if item.isFinished {
            Divider()
            Button(vm.playingID == item.id ? "停止试听" : "试听") {
                // 先选中再播：否则播放条显示的是另一首，两处对不上
                vm.select(item)
                vm.togglePlay(item)
            }
            Divider()
            // ★ 弹保存框要**等菜单收完**再弹。在菜单动作里直接 runModal，
            //   菜单还没消失就冒出个模态窗，会卡在那儿（macOS 上的老毛病）。
            Button("导出为 MP3…") {
                DispatchQueue.main.async { vm.export(item, as: .mp3) }
            }
            Button("导出为 WAV…") {
                DispatchQueue.main.async { vm.export(item, as: .wav) }
            }
        }
    }

    private func color(for state: String) -> Color {
        switch state {
        case "running": return .orange
        case "done": return .green
        // 「只出了谱子、还没唱」—— 用谱子的颜色。别用绿色（那会让人以为
        // 歌已经出来了），更不能用红的（它没出错）。
        case "score": return scoreOnlyColor
        case "failed": return .red
        default: return Palette.textSecondary.opacity(0.5)
        }
    }

    /// 「只有谱子」这个状态的颜色：淡青蓝，跟"完成"的绿、"进行中"的橙都分得开。
    private var scoreOnlyColor: Color { Color(red: 0.38, green: 0.78, blue: 0.95) }

    // ---------------- 右侧：参数与操作 ----------------

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                player
                // ★ 「送进 ACE Studio」紧跟在播放条下面 —— 它在操作**选中的这一首**，
                //   跟播放/试听是同一条线的事，所以摆在一起。
                aceButtons
                // ★ 「这次照这份谱子唱」的卡 —— **摆在歌词框上面**。
                //   以前这句话在表单**最底下**（`parameters` 尾巴上），
                //   而窗口比内容矮、滚动条停在上面 ⇒ 用户根本看不见，
                //   于是"导入完了"在他眼里等于什么都没发生（2026-10-13 他提的）。
                if !vm.form.abcPath.isEmpty {
                    scoreCard
                }
                workflowButtons
                // 「改改乐器」（2026-10-29）：拆过 MIDI 才摆出来 ——
                // 它修的是"刚拆的那一条"，没拆过就没有可改的东西。
                if vm.lastMIDIURL != nil {
                    midiRenameRow
                }
                if !vm.ss2Status.isEmpty {
                    Text(vm.ss2Status)
                        .font(.system(size: 12))
                        .foregroundStyle(vm.ss2Busy ? Palette.textSecondary : Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !vm.ss2Summary.isEmpty {
                    Text(vm.ss2Summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.45, green: 0.85, blue: 0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !vm.transcribeStatus.isEmpty {
                    Text(vm.transcribeStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(vm.transcribeBusy ? Palette.textSecondary : Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !vm.lyricsStatus.isEmpty {
                    Text(vm.lyricsStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(vm.lyricsBusy ? Palette.textSecondary : Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !vm.alignStatus.isEmpty {
                    Text(vm.alignStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(vm.alignBusy ? Palette.textSecondary : Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !vm.playStatus.isEmpty {
                    HStack(spacing: 8) {
                        Text(vm.playStatus)
                            .font(.system(size: 12))
                            .foregroundStyle(vm.playBusy ? Palette.textSecondary : Palette.accent)
                            .fixedSize(horizontal: false, vertical: true)
                        if let output = vm.playOutput, !vm.playBusy {
                            Button("在访达里看看") {
                                NSWorkspace.shared.activateFileViewerSelecting([output])
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
                labeled("歌词") {
                    VStack(alignment: .leading, spacing: 8) {
                        editor(text: $vm.form.lyrics, height: 128, placeholder: "[Instrumental]")
                            .disabled(isInstrumentalMode)
                            .opacity(isInstrumentalMode ? 0.45 : 1)
                        Toggle("纯器乐（不唱，只出伴奏）", isOn: Binding(
                            get: { isInstrumentalMode },
                            set: { on in
                                if on {
                                    vm.lyricsBeforeInstrumental = vm.form.lyrics
                                    vm.form.lyrics = "[Instrumental]"
                                } else {
                                    let back = vm.lyricsBeforeInstrumental
                                    vm.form.lyrics = back.isEmpty ? "" : back
                                }
                            }))
                            .font(.system(size: 13))
                            .toggleStyle(.checkbox)
                        if isInstrumentalMode {
                            Text("歌词锁住了。关掉这个勾，就能重新写词。")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
                labeled("风格") {
                    editor(text: $vm.form.prompt, height: 88,
                           placeholder: "An upbeat electronic instrumental track featuring synthesizer and drum machine.")
                }
                parameters
                progressArea
                actionButton
                if !vm.lastError.isEmpty {
                    Text(vm.lastError)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.42))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !vm.exportMessage.isEmpty {
                    Text(vm.exportMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity)
        .background(Palette.windowBG)
    }

    /// 「送进 ACE Studio」那**两个**按钮。
    ///
    /// **用户 2026-10-13 要的**：「直接可以改成 **把谱子送到 ace** 以及 **将音频送到 ace**」。
    ///
    /// 这一对按钮**原来那个位置站的是「MusicXML → ABC / ABC → MusicXML」**。
    /// 用户当天把那一对废了，理由是：
    /// > 「如果 CS 可以直接认 XML 了的话，XML 和 ABC 之间的格式互转功能就可以被废掉了」
    /// —— 说得对：读谱器从 0.8.2 起**两种格式都认**（导入谱子、读拍号调号歌词），
    /// 他自己那条"转格式"的路就不走了；而"送进 ACE"是他**天天**要做的那一步。
    /// 转换能力**仍在底层留着** —— 送 ACE 时手上只有 ABC 的话，
    /// 还是靠 `ScoreFiles.scoreURL` 就地转一份 MusicXML（ACE 不认 ABC）。
    ///
    /// 三条讲究：
    ///   ① **两件事分开**，不是"一键送两样"（用户原话就是两件）：
    ///      常见情形是谱子改过了、音频还是旧的，那就只补送一样。
    ///   ② **这一首没有那一样时按钮禁用**（灰掉），不弹错 ——
    ///      位置永远在，他不会"找不到按钮"。
    ///   ③ **结果写在这一行里**（按钮右边），不往窗口底下塞
    ///      （本项目栽过两次：比内容矮的时候，底部那行他根本看不见）。
    // MARK: - 三个入口 + 谱面面板

    /// 三个入口按钮：**上传音频 / 导入 MusicXML / 输入歌词**。
    ///
    /// 它们不是新做的三条路 —— 底下全都复用现有的：
    /// 选音频、`importScore()`、歌词框。这里只是把它们摆到明面上。
    /// 「看乐谱」只在服务给回了谱子之后出现（没有谱子时不摆一个按不动的按钮）。
    private var workflowButtons: some View {
        HStack(spacing: 8) {
            entryButton("上传音频", icon: "waveform", busy: vm.transcribeBusy) {
                vm.importAudioForCover()
            }
            entryButton("导入 MusicXML", icon: "doc.badge.plus", busy: vm.ss2Busy) {
                vm.importScore()
            }
            entryButton("输入歌词", icon: "text.cursor", busy: false) {
                showsLyricsEditor = true
            }
            // 「扒歌词」（2026-10-27）：音频进来，文字出去。
            // 和「上传音频」并列 —— 一个要谱，一个要词，都是把音频变成能改的材料。
            entryButton("扒歌词", icon: "text.quote", busy: vm.lyricsBusy) {
                vm.pickAudioForLyrics()
            }
            // 「对齐时间」（2026-10-27）：词改对了之后，再打一遍时间轴。
            entryButton("按词对时间", icon: "clock", busy: vm.alignBusy) {
                vm.realignLyrics()
            }
            // 「谱子出声」（2026-10-24）：照谱奏，不进模型。
            // 和「生成」分开放 —— 一个把谱面原样发成声音，一个让模型照谱唱，两件事。
            entryButton("谱子出声", icon: "speaker.wave.2", busy: vm.playBusy) {
                vm.playScoreFile()
            }
            // 「挂 LoRA」（2026-10-24）：mlx-Yue 升级后多出来的能力。
            // 它改的是**唱法 / 音色**，不是咬字 —— 挂着的时候按钮上直接写文件名，
            // 免得人忘了自己挂着什么。
            entryButton(vm.form.loraPath.isEmpty
                        ? "挂 LoRA"
                        : "LoRA：\(URL(fileURLWithPath: vm.form.loraPath).lastPathComponent)",
                        icon: "wand.and.stars", busy: vm.loraBusy) {
                vm.pickLoRA()
            }
            if !vm.form.loraPath.isEmpty {
                entryButton("不挂", icon: "xmark.circle", busy: false) {
                    vm.form.loraPath = ""
                    vm.form.loraScale = 1.0
                }
            }
            // 「换嗓子」（2026-10-25）：先出一首歌，再用一段录音把嗓子换掉。
            // 跟「生成」是前后两段 —— 所以它开一个小窗，不占生成那条路的位置。
            entryButton("换嗓子", icon: "person.wave.2", busy: false) {
                showsVoiceSwap = true
            }
            if !vm.ss2RepairedABC.isEmpty {
                entryButton("看乐谱", icon: "music.note.list", busy: false) {
                    vm.ss2ShowsPanel = true
                }
            }
            entryButton("送到 MIR Studio", icon: "paintbrush.pointed", busy: false) {
                vm.sendToScoreStudio()
            }
            if !vm.studioMessage.isEmpty {
                Text(vm.studioMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    private func entryButton(_ title: String, icon: String, busy: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(busy ? Palette.textSecondary : Palette.textPrimary)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.field))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.stroke))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    /// 谱面面板：显示服务修好格式的 ABC（**带版权头、和弦原样**），
    /// 用户可以直接改；「保存并接上」把改过的谱子存进 `abc-cache/edited/`，
    /// 下一次「生成」就照它唱。
    private var scoreEditPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("乐谱").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("手写和弦不会被 AI 改写；这里动的是送唱的旋律")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
            }
            if !vm.ss2Summary.isEmpty {
                Text(vm.ss2Summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.45, green: 0.85, blue: 0.6))
            }
            TextEditor(text: $vm.ss2RepairedABC)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Palette.field)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 300)
            HStack(spacing: 10) {
                Text("速度").font(.system(size: 12))
                TextField("", value: Binding(
                    get: { vm.form.bpm ?? 0 },
                    set: { vm.form.bpm = $0 > 0 ? $0 : nil }
                ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text("BPM").font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                Text("移调").font(.system(size: 12))
                TextField("", value: $vm.ss2Transpose, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Text("半音（还没接到引擎，先不生效）")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
            }
            HStack {
                Text("条件 JSON 是另一条通道，不塞进 ABC 注释")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Button("取消") { vm.ss2ShowsPanel = false }
                Button("保存并接上") { vm.saveEditedScore() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 780, height: 580)
        .background(Palette.windowBG)
        .preferredColorScheme(.dark)
    }

    /// 「改改乐器」那一行 —— 拆过 MIDI 才摆（2026-10-29）。
    ///
    /// 摆在一排入口按钮下面、状态行上面：它修的是**刚拆出来的那一条**。
    /// 摆远了，他会以为还得重新去「上传音频」走一遍。
    private var midiRenameRow: some View {
        HStack(spacing: 10) {
            Button {
                // 预选 = 这次真听到的那几样。让他从"实际结果"里删减，
                // 而不是面对一张空清单从零开始想。
                vm.pickedInstruments = Set(vm.lastMIDIInstruments)
                vm.showsInstrumentPicker = true
            } label: {
                Label("它听错了？改改乐器", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)
            .disabled(vm.retranscribeBusy || vm.transcribeBusy)

            if vm.retranscribeBusy {
                ProgressView().controlSize(.small)
                Text("重拆中…")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
            } else {
                Text(midiRenameHint)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// 那一行右边的话：这次听到什么，以及点名能干什么。
    private var midiRenameHint: String {
        let names = vm.lastMIDIInstruments.map { MuScriptorInstrumentCatalog.chinese(for: $0) }
        guard !names.isEmpty else {
            return "这次没听出确定的乐器；可以点名，让它只出你指定的那几样"
        }
        return "这次听到：" + names.joined(separator: "、") + "（可点名再拆一遍）"
    }

    /// 乐器勾选小窗。
    ///
    /// 三句说明都摆在上面，因为这是个「勾了就少」的开关，不说清会误伤：
    /// 勾上的才出、漏勾那样就没有、一个都不勾＝让它自己判断。
    ///
    /// 最后一句是老实交代：表里没有中国民族乐器。不给希望，也不藏着。
    private var instrumentPickerPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("改改乐器").font(.system(size: 15, weight: .semibold))
            Text("勾上的才会出；漏勾那样就没有。一个都不勾 = 让它自己判断（跟刚才一样）。")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(MuScriptorInstrumentCatalog.groups, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.textSecondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)],
                                      alignment: .leading, spacing: 6) {
                                ForEach(MuScriptorInstrumentCatalog.instruments(in: group)) { item in
                                    Toggle(item.chinese, isOn: instrumentBinding(item.key))
                                        .font(.system(size: 12))
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 380)

            Text("这张表里没有中国民族乐器（古筝、琵琶、二胡）—— 遇到民乐，它会归到最近的西洋音色上，点名也改不了这一点。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("一个都不勾") { vm.pickedInstruments = [] }
                Text("已勾 \(vm.pickedInstruments.count) 样")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Button("算了") { vm.showsInstrumentPicker = false }
                Button("按这些重拆") { vm.retranscribeMIDIWithPicked() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 720, height: 620)
        .background(Palette.windowBG)
        .preferredColorScheme(.dark)
    }

    private func instrumentBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { vm.pickedInstruments.contains(key) },
            set: { on in
                if on { vm.pickedInstruments.insert(key) } else { vm.pickedInstruments.remove(key) }
            }
        )
    }

    /// 「输入歌词」的小窗。用的还是同一份 `form.lyrics`，跟主界面不分家。
    private var lyricsEditorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("歌词").font(.system(size: 15, weight: .semibold))
            Text("写在这里，跟主界面的歌词框是同一份。")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
            editor(text: $vm.form.lyrics, height: 360, placeholder: "[Instrumental]")
            HStack {
                Spacer()
                Button("好了") { showsLyricsEditor = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 580, height: 500)
        .background(Palette.windowBG)
        .preferredColorScheme(.dark)
    }

    private var aceButtons: some View {
        let item = vm.items.first { $0.id == vm.selectedID }
        return HStack(spacing: 8) {
            aceButton("谱子 → ACE", systemImage: "music.note.list",
                      enabled: hasScore(item)) {
                if let item { vm.sendScoreToACE(item) }
            }
            aceButton("音频 → ACE", systemImage: "waveform",
                      enabled: hasAudio(item)) {
                if let item { vm.sendAudioToACE(item) }
            }
            // 「MIDI → ACE」（2026-10-25）：这一首有拆轨的 MIDI 才摆出来 ——
            // 没有的时候不占位置，免得一行塞满按不动的按钮。
            if let item, item.midiURL != nil {
                aceButton("MIDI → ACE", systemImage: "pianokeys",
                          enabled: hasMIDI(item)) {
                    vm.sendMIDIToACE(item)
                }
            }
            // 「Live 选中 → ACE」（2026-10-18）：送的是 Live 里选中的那一段，
            // 不是列表里的这一首 —— 分轨后的音频、或转好的 MIDI 都走这里。
            aceButton("Live 选中 → ACE", systemImage: "arrow.right.doc.on.clipboard",
                      enabled: vm.liveState == .connected && !vm.transferring) {
                vm.sendLiveClipToACE()
            }
            // 「ACE 选中 → Live」（2026-10-18）：反过来把 ACE 里选中的轨渲染出来送 Live。
            // 「在 Live 里分音轨是不要钱的」—— 所以这方向也得通。
            aceButton("ACE 选中 → Live", systemImage: "arrow.left.doc.on.clipboard",
                      enabled: vm.liveState == .connected && !vm.transferring) {
                vm.sendACEClipToLive()
            }
            // 「MIDI → Live」（2026-10-25）：这一首有拆轨 MIDI 才摆出来，
            // 跟「MIDI → ACE」同一个分寸（没有就不占位置）。
            if let item, item.midiURL != nil {
                aceButton("MIDI → Live", systemImage: "pianokeys",
                          enabled: vm.liveState == .connected && hasMIDI(item)) {
                    vm.sendMIDIToLive(item)
                }
            }
            // 「送到 Waveform」（2026-10-29）：接免费 DAW 的交接。
            // **有音频或拆轨 MIDI 才出现** —— 什么都没有就不占这个位置。
            if let item, hasAudio(item) || item.midiURL != nil {
                aceButton("送到 Waveform", systemImage: "square.and.arrow.up.on.square",
                          enabled: true) {
                    vm.sendToWaveform(item)
                }
            }
            // 「→ Musio」（2026-11-03）：送进 Musio Studio，落在它当前的光标处。
            if let item, hasAudio(item) || item.midiURL != nil {
                aceButton("→ Musio", systemImage: "waveform.badge.plus",
                          enabled: !vm.transferring) {
                    vm.sendToMusio(item)
                }
            }
            liveButton
            if !vm.transferMessage.isEmpty {
                Text(vm.transferMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(transferMessageColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !vm.liveMessage.isEmpty {
                Text(vm.liveMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(liveMessageColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 「连 Live」—— 2026-10-17 用户要的那个按钮。
    /// 按下：没开着就打开 Live，然后一直等到桥连上；已经连着就只报一句。
    private var liveButton: some View {
        let connected = vm.liveState == .connected
        let title: String = {
            switch vm.liveState {
            case .connected: return "Live 已连"
            case .connecting: return "正在连…"
            default: return "连 Live"
            }
        }()
        return Button {
            vm.linkLive()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: connected ? "link.circle.fill" : "link")
                    .font(.system(size: 10))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(connected ? Palette.accent : Palette.textPrimary)
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 9).fill(Palette.field))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(connected ? Palette.accent : Palette.stroke)
            )
        }
        .buttonStyle(.plain)
        .disabled(vm.liveState == .connecting)
        .fixedSize()
        .help(connected
              ? "已经连着 Ableton Live"
              : "打开 Ableton Live 并连接（没开着的话会先打开它）")
    }

    private var liveMessageColor: Color {
        switch vm.liveState {
        case .connected: return Color(red: 0.42, green: 0.85, blue: 0.55)
        case .connecting: return Palette.textSecondary
        default: return Color(red: 1, green: 0.72, blue: 0.35)
        }
    }

    /// 这一首有没有**可送的谱子**。只有出了谱子的那两条路才算 ——
    /// ACE-Step 那一档不出谱子，按钮就该是灰的。
    private func hasScore(_ item: GenerationItem?) -> Bool {
        guard let item, !vm.transferring else { return false }
        return (try? ScoreFiles.scoreURL(for: item, format: .xml)) != nil
    }

    /// 这一首有没有**可送的音频**（只有谱子、还没唱的那一条没有）。
    private func hasAudio(_ item: GenerationItem?) -> Bool {
        guard let item, !vm.transferring else { return false }
        guard let path = item.outputPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// 这一首有没有**可送的 MIDI**（「上传音频」拆轨之后才有）。
    private func hasMIDI(_ item: GenerationItem?) -> Bool {
        guard let item, !vm.transferring else { return false }
        return item.midiURL != nil
    }

    /// 送 ACE 的按钮的样子 —— 跟「打开文件夹」同一副骨架，字号小一号：
    /// 它们是顺手用的工具，不跟「生成」抢眼睛（这一行原来的转换按钮就是这个分寸）。
    private func aceButton(_ title: String, systemImage: String,
                           enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10))
                Text(vm.transferring ? "正在送…" : title).font(.system(size: 12))
            }
            .foregroundStyle(enabled ? Palette.textPrimary : Palette.textSecondary)
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 9).fill(Palette.field))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.stroke))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .fixedSize()
        .help(enabled ? "把\(title.split(separator: " ").first ?? "")送进 ACE Studio（没开着的话会自动打开它）"
                      : "这一首还没有这一样可送的")
    }

    private var transferMessageColor: Color {
        switch vm.transferOK {
        case .some(true): return Color(red: 0.42, green: 0.85, blue: 0.55)
        case .some(false): return Color(red: 1, green: 0.42, blue: 0.42)
        case .none: return Palette.textSecondary
        }
    }

    /// 「这次照这份谱子唱」那张卡。
    ///
    /// **用户 2026-10-13 要的**：原话「导入乐谱的时候顺便读一下它的
    /// 拍号调号歌词音符，不要导入之后还是空」。
    ///
    /// 一次解决两件事：
    ///   ① 摆到**看得见**的地方（以前这句话在表单最底下，他看不见）；
    ///   ② 把读到的**说出来** —— 拍号、调号、速度、音符数、歌词字数。
    ///      这些东西谱子里本来就有，以前只是没人翻译给他看。
    ///
    /// 读不出细节时（导进来的是 `.abc`、或刚按「先出谱子」出的那一份），
    /// **第一行照样显示** —— 「这次照的是哪一份」必须永远看得见。
    private var scoreCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "music.note.list").font(.system(size: 12))
                Text("这次照这份谱子唱："
                     + URL(fileURLWithPath: vm.form.abcPath).lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let r = vm.scoreReading {
                Text(r.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // ★ 谱子里的词**去哪儿了** —— 这一句才是"真的读到了"的凭据。
            //   用户 2026-10-13：「歌词直接放在歌词栏里，也可以证明真的读到乐谱内容了」。
            //   它摆在歌词框正上方，跟框里那些字是**同时**变的 ——
            //   颜色不覆盖，所以是卡片的高亮色（比读数那行显眼）。
            if !vm.scoreLyricsNote.isEmpty {
                Text(vm.scoreLyricsNote)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // ★ 2026-10-20 用户给这个玩法定名：**cover**。
            //   原话：「这样我们就完成了……高级玩家最喜欢玩的一个很低的游戏，叫做 cover。」
            Text("按「新建一首」就清掉；按「生成」就照它唱 —— 这就是一次 cover。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Palette.accent)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.field))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.stroke))
    }

    private var player: some View {
        let item = vm.items.first { $0.id == vm.selectedID }
        let ready = item?.isFinished ?? false
        return HStack(spacing: 12) {
            Button {
                if let item { vm.togglePlay(item) }
            } label: {
                Image(systemName: (vm.playingID != nil && vm.playingID == vm.selectedID) ? "stop.fill" : "play.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(ready ? Palette.textPrimary : Palette.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.field))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.stroke))
            }
            .buttonStyle(.plain)
            .disabled(!ready)

            // 波形是**最后**才分空间的（-2），名字次之（-1），按钮最先（0）。
            // ★ 这个次序踩过一次：给名字 -1、波形留 0，波形就把整行吃光，
            //   名字被压成 0 宽、直接看不见了（2026-10-11）。
            //   空间不够时，波形该被裁掉一截，而不是把名字和按钮挤出去。
            waveform(active: vm.playingID != nil && vm.playingID == vm.selectedID)
                .clipped()
                .layoutPriority(-2)

            if let item, item.isFinished, let path = item.outputPath {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // ★ 必须限宽。名字现在是**人话**，中文标题能到 22 个字，
                    //   而一个中文字约等于两个英文字宽 —— 不限宽的话它会把
                    //   右边的「导出」「显示文件」整个挤出窗口。
                    //   2026-10-11 实测：中文标题一进来，「显示文件」被切掉一半，
                    //   只剩「显示」两个字露在外面。
                    //   窗口最小宽度是 960，这一行剩下约 660pt；
                    //   播放键 34 + 波形 + 名字 150 + 导出 + 显示文件，这样才排得下。
                    .frame(maxWidth: 150, alignment: .leading)
                    .layoutPriority(-1)
                exportMenu(for: item)
                scoreButton(for: item)
                revealButton(for: item)
            } else if let item, item.isScoreOnly {
                // 「先出谱子」按过之后的样子：这一条**还没有声音**，但谱子已经到手。
                // 播放键保持禁用（上面 `ready` 那一句），这里只把谱子递出去 ——
                // 没有音频可导，所以「导出」也不摆出来（摆了也是错的）。
                HStack(spacing: 5) {
                    Image(systemName: "music.note.list").font(.system(size: 10))
                    Text("只有谱子，还没唱").font(.system(size: 11))
                }
                .foregroundStyle(scoreOnlyColor)
                .lineLimit(1)
                Spacer(minLength: 0)
                scoreButton(for: item)
                revealButton(for: item)
            } else {
                Text("还没有生成结果")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.stroke))
    }

    /// 导出下拉：MP3 或 WAV
    private func exportMenu(for item: GenerationItem) -> some View {
        Menu {
            ForEach(ExportFormat.allCases) { format in
                Button("导出为 \(format.rawValue) — \(format.detail)") {
                    vm.export(item, as: format)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.down")
                Text(vm.exporting ? "导出中…" : "导出").font(.system(size: 12))
            }
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.field))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.stroke))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(vm.exporting)
    }

    /// 「谱子」按钮：在访达里定位这一首的谱子（MusicXML 优先）。
    ///
    /// YuE2 那一首才有 —— 用户要拿它进 Dorico 改，所以入口得摆在明面上，
    /// 不能只让他自己去文件夹里翻（2026-10-12 加）。
    /// 抽成一个方法，是因为播放条上有**两处**要用它：
    /// 出了歌的、和只出了谱子的（后者没有音频，按钮更该在）。
    @ViewBuilder
    private func scoreButton(for item: GenerationItem) -> some View {
        if let score = item.scoreURL {
            Button {
                vm.openScore(score)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "music.note.list")
                    Text("谱子").font(.system(size: 12))
                }
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.field))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.stroke))
            }
            .buttonStyle(.plain)
            .help("用 Dorico 打开这份谱子（没装 Dorico 就用系统默认程序）")
        }
    }

    /// 「打开文件」按钮 —— 点了直接打开，不再只是把文件夹摊开。
    ///
    /// 用户 2026-10-24 定的：显示文件要「直接打开文件」。
    /// 音频交给系统默认播放器；只出了谱子的条目就打开那份谱子（Dorico 优先）。
    private func revealButton(for item: GenerationItem) -> some View {
        Button {
            vm.openOutput(for: item)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.forward.app")
                Text("打开文件").font(.system(size: 12))
            }
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.field))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.accent.opacity(0.45)))
        }
        .buttonStyle(.plain)
        .help("直接打开这一首的音频（谱子用右边的「谱子」）")
    }

    /// 一条静态波形占位条 —— 只为让这一栏看起来像「播放器」。
    private func waveform(active: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<64, id: \.self) { i in
                let h = 4 + abs(sin(Double(i) * 0.7)) * 16
                Capsule()
                    .fill(active ? Palette.accent : Palette.textSecondary.opacity(0.55))
                    .frame(width: 2.5, height: h)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 24)
    }

    private var parameters: some View {
        VStack(alignment: .leading, spacing: 14) {
            // ★ 引擎选择摆在这一栏的最上面 —— 它决定下面哪些格子还有意义。
            //   两台引擎共用同一套「风格 / 歌词 / 质量档」，差别只在
            //   「时长、BPM、调号、模式」这几格是 ACE-Step 独有的。
            //   ⚠️ 2026-10-16 起只列 `selectable`（＝只有 YuE2）—— 本机那台
            //   Composer Step 模型被拆了，不能再让它出现在下拉里。
            HStack(spacing: 12) {
                labeledInline("引擎") {
                    dropdown(options: EngineKind.selectable, selection: $vm.engine) { $0.label }
                }
                Spacer(minLength: 0)
            }
            Text(vm.engine.hint)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if vm.engine.usesACEStepParameters {
            HStack(spacing: 16) {
                labeledInline("BPM") {
                    TextField("自动", text: Binding(
                        get: { vm.form.bpm.map(String.init) ?? "" },
                        set: { vm.form.bpm = Int($0.filter(\.isNumber)) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 54)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(box)
                }
                labeledInline("调号") {
                    TextField("自动", text: $vm.form.keyscale)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: 92)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(box)
                }
                labeledInline("时长(秒)") {
                    TextField("60", value: $vm.form.duration, format: .number)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: 60)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(box)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 16) {
                labeledInline("模式") {
                    dropdown(options: GenerationMode.allCases, selection: $vm.mode) { $0.rawValue }
                }
                labeledInline("质量") {
                    tierPicker
                }
                labeledInline("语言") {
                    dropdown(options: languageOptions.map(\.code), selection: $vm.form.language) { code in
                        languageOptions.first { $0.code == code }?.name ?? code
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Text(vm.mode.hint).font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 0)
                if vm.mode != .generate {
                    Button(vm.mode == .repaint ? "选择源音频…" : "选择参考音频…") {
                        vm.chooseAudio(for: vm.mode)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.accent)
                    let chosen = vm.mode == .repaint ? vm.form.srcAudio : vm.form.refAudio
                    if !chosen.isEmpty {
                        Text(URL(fileURLWithPath: chosen).lastPathComponent)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            // ★ 2026-10-16 实测后才知道这个开关真正管的是什么。它原来写的是
            //   「让内置语言模型补全风格与歌词」—— 那是从上游文档抄的，等于没说到
            //   点子上：**它关着，ACE-Step 就不唱**。同一个曲子、同一段词、同样 3
            //   分钟、同 seed，关着出来是纯音乐；打开就照词唱了（机器耳朵转出
            //   「月亮…回家的」，跟填的词对得上）。所以标签改成用户真正关心的那句话。
            VStack(alignment: .leading, spacing: 4) {
                Toggle("让它唱（打开后才会唱你写的词）", isOn: $vm.form.thinking)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .toggleStyle(.checkbox)
                Text("关着只出音乐；打开后它会照你填的词唱 —— 代价是多起一个语言模型，慢一些。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            } else {
                // ── YuE2 ──
                // 它自己有主意：歌词写多长、歌就有多长，所以没有「时长」这一格。
                // 能调的只有声学合成的步数（实测过的两档）。
                HStack(spacing: 16) {
                    labeledInline("档位") {
                        HStack(spacing: 0) {
                            ForEach(Yue2Tier.all) { t in
                                Button {
                                    vm.yue2Tier = t
                                } label: {
                                    Text("\(t.name)·\(t.steps)步")
                                        .font(.system(size: 12))
                                        .foregroundStyle(vm.yue2Tier == t ? .white : Palette.textSecondary)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(vm.yue2Tier == t ? Palette.accent : Color.clear)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.stroke))
                        .fixedSize()
                    }
                    Text(vm.yue2Tier.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textSecondary)
                    Spacer(minLength: 0)
                }

                Text("歌词写多少、歌就有多长。谱子（.abc，以及给 Dorico 直接打开的 .xml）会和音频放在同一个文件夹里。\n"
                     + "想先看谱、再听歌：按「先出谱子」（约 40 秒，只写谱不唱），看过或改过之后按「生成」，就照那一份唱。")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // ★ 「这次照的是哪一份谱子」原先就写在这儿（表单最底下）——
                //   2026-10-13 挪到歌词框上面那张卡里去了（`scoreCard`）：
                //   摆在这个位置等于没摆（窗口比内容矮、滚动条停在上面，他看不见）。
            }

        }
    }

    private let languageOptions: [(code: String, name: String)] = [
        ("unknown", "自动"), ("zh", "中文"), ("en", "英语"), ("de", "德语"),
    ]

    /// 进度区：一张「现在在干什么」的说明卡，加一根进度条。
    ///
    /// 为什么不是一个光秃秃的进度条（2026-10-13 用户提的）：
    /// 一趟要跑几分钟，而百分比经常半分钟不动 —— 等着的人只能盯着一根不动的条，
    /// 分不清"在慢慢干活"还是"已经卡死了"。这里补三样：
    ///   ① 一句**人话**说清现在在哪一步（大字）；
    ///   ② 一句补充说明（脚本给的：这一步大概多久、为什么慢）；
    ///   ③ 「已经等了 X」—— **每秒都在涨**，它本身就是还活着的证据。
    private var progressArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            progressCard
            progressBar
        }
    }

    private var progressCard: some View {
        let p = vm.progress
        let running = p.state == "running"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if running { PulsingDot(color: Palette.accent) }
                Text(progressTitle(p))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(progressTitleColor(p))
                    // 长了就折行 —— 不许截成省略号，那等于说了半句
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !progressSub(p, now: Date()).isEmpty {
                Group {
                    if running {
                        // 走秒：一秒重画这一行。**只有这一行**在重画，
                        // 闲着的时候一个定时器都不留。
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(progressSub(p, now: ctx.date))
                        }
                    } else {
                        Text(progressSub(p, now: Date()))
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, running ? 14 : 0)   // 跟标题左对齐（让开那颗点）
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(p.state == "idle" ? Palette.field.opacity(0.5) : Palette.field)
        )
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.stroke))
    }

    /// 大字那句：现在在干什么。
    private func progressTitle(_ p: ProgressSnapshot) -> String {
        if p.message.isEmpty { return p.state == "running" ? "正在准备…" : "空闲" }
        return p.message
    }

    private func progressTitleColor(_ p: ProgressSnapshot) -> Color {
        switch p.state {
        case "done":    return .green
        case "failed":  return Color(red: 1, green: 0.42, blue: 0.42)
        case "running": return Palette.textPrimary
        default:        return Palette.textSecondary
        }
    }

    /// 小字那行：脚本给的说明 + 「等了多久」。
    ///
    /// 时间**只报已经等了多久，不报还要多久** —— 剩余时间是拍脑袋估的，
    /// 一旦超时就成了假话，比不说更让人焦躁。这一步大概要多久，交给脚本
    /// 用一句经验之谈说（例如「头一次开最慢，通常一两分钟」），那是实话。
    private func progressSub(_ p: ProgressSnapshot, now: Date) -> String {
        var parts: [String] = []
        if let d = p.detail, !d.isEmpty { parts.append(d) }
        if let start = vm.client.startedAt {
            switch p.state {
            case "running":
                parts.append("已经等了 " + Self.waitedText(now.timeIntervalSince(start)))
            case "done", "failed":
                parts.append("这一趟一共用了 " + Self.waitedText(now.timeIntervalSince(start)))
            default:
                break
            }
        }
        return parts.joined(separator: " · ")
    }

    /// 秒数说成人话：90 秒写成「1 分 30 秒」，不让人自己心算。
    private static func waitedText(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) 秒" }
        return "\(s / 60) 分 \(s % 60) 秒"
    }

    private var progressBar: some View {
        let p = vm.progress
        return HStack(spacing: 10) {
            GeometryReader { geo in
                let filled = max(0, geo.size.width * CGFloat(p.percent) / 100.0)
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.field)
                    Capsule()
                        .fill(p.state == "failed"
                              ? Color(red: 0.85, green: 0.25, blue: 0.25)
                              : Palette.accent)
                        .frame(width: filled)
                    if p.state == "running", filled > 2 {
                        // 条头上一颗呼吸的光点：**百分比不动的时候，动的是它**。
                        PulsingDot(color: .white, size: 7, dim: 0.25)
                            .offset(x: filled - 3.5)
                    }
                }
            }
            .frame(height: 8)

            Text("\(p.percent)%")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var actionButton: some View {
        HStack(spacing: 10) {
            Button {
                vm.isRunning ? vm.stop() : vm.generate()
            } label: {
                Text(vm.isRunning ? "停止" : "生成")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(vm.isRunning ? Color(red: 0.85, green: 0.25, blue: 0.25) : Palette.accent)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            // 用户 2026-10-12 特意交代过：「如果直接点出歌的话，就是谱子和歌都出来」
            // —— 这句就在这儿说清楚，免得他以为非得先出谱子才有谱子。
            .help(vm.engine == .yue2
                  ? "出整首歌：谱子和音频一起放在同一个文件夹里（快档约四分半）"
                  : "出这一首")

            // 「先出谱子」：**YuE2 那台才有**（ACE-Step 不出谱子）。
            //
            // 用户 2026-10-12 提的：YuE2 本来就能「先出乐谱、再出歌」——
            // 谱子几十秒就有，可原先非得等它唱完才看得到。现在按这个先拿谱子
            //（拿去 Dorico 改也行），再按「生成」，就照这一份唱。
            // 生成期间它跟着禁用 —— 同一台引擎一次只跑一趟。
            if vm.engine == .yue2 {
                Button {
                    vm.generateScoreOnly()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "music.note.list")
                        Text("先出谱子").font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Palette.field))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.accent.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .disabled(vm.isRunning)
                .fixedSize()
                .help("只要乐谱，先不唱（约 40 秒）。出完按「生成」就照这一份唱")
            }

            // ★ **这里原先站着两个「MusicXML → ABC / ABC → MusicXML」按钮，2026-10-13 废掉了。**
            //   用户当天的话：「**如果 CS 可以直接认 XML 了的话，XML 和 ABC 之间的格式互转
            //   功能就可以被废掉了**」—— 成立：读谱器从 0.8.2 起两种格式都认
            //   （导入谱子、读拍号调号歌词），那条"先转格式再送回去"的路他自己不走了。
            //   ⇒ 它们换成了**播放条下面那两个「谱子 → ACE」「音频 → ACE」**
            //     （理由和分寸写在 `aceButtons` 那儿）。
            //   转换的**能力**没删，留在 `ScoreFiles` 里：送 ACE 时手上只有 ABC 的话，
            //   还是要靠它就地转一份 MusicXML（ACE 不认 ABC）。

            // 「在文件夹里看」的第二个入口。把字写出来，不只用图标 ——
            // 光一个文件夹图案，容易被当成「新建文件夹」（2026-10-11 用户提的）。
            Button {
                vm.openOutputFolder()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text("打开文件夹").font(.system(size: 13))
                }
                .foregroundStyle(Palette.textPrimary)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 9).fill(Palette.field))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.stroke))
            }
            .buttonStyle(.plain)
            .help("打开存放生成结果的文件夹")

            // 偏好设置入口放在这儿（比去菜单栏找省事）：挑试听走哪块声卡
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 15)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Palette.field))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.stroke))
            }
            .buttonStyle(.plain)
            .help("偏好设置：试听使用哪块声卡（也可以按 ⌘,）")
        }
    }

    // （原先这里有一个 `convertButton` —— 那两个「MusicXML ↔ ABC」按钮的皮。
    //   2026-10-13 用户把那一对废掉了，皮也一起撤了。
    //   **转换能力本身没删**：`ScoreFiles.convertScoreFile` 还在，
    //   送 ACE 时手上只有 ABC 就靠它转一份 MusicXML。）

    // ---------------- 小组件 ----------------

    private var box: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Palette.field)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.stroke))
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.textSecondary)
            content()
        }
    }

    private func labeledInline<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
            content()
        }
    }

    /// 自定义下拉 —— 不用系统 Picker，免得跟随系统强调色（本机是红色）。
    private func dropdown<T: Hashable>(options: [T], selection: Binding<T>, label: @escaping (T) -> String) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(label(option)) { selection.wrappedValue = option }
            }
        } label: {
            HStack(spacing: 8) {
                Text(label(selection.wrappedValue))
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(box)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var tierPicker: some View {
        HStack(spacing: 0) {
            ForEach(QualityTier.allCases) { t in
                Button {
                    vm.tier = t
                } label: {
                    Text("\(t.rawValue)·\(t.steps)步")
                        .font(.system(size: 12))
                        .foregroundStyle(vm.tier == t ? .white : Palette.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(vm.tier == t ? Palette.accent : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.stroke))
        .fixedSize()
    }

    /// 歌词框里是不是 `[Instrumental]` —— 是的话就是"纯器乐"，框该锁死。
    private var isInstrumentalMode: Bool {
        vm.form.lyrics.trimmingCharacters(in: .whitespacesAndNewlines) == "[Instrumental]"
    }

    private func editor(text: Binding<String>, height: CGFloat, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.system(size: 15))
                // ★ **两套写法都留着**（2026-10-13 用户报「框子里写东西也是黑的」）：
                //   · `foregroundStyle` 管**已经落定的文字**；
                //   · `tint` 管**光标与选中**；
                //   · 而**打字那一瞬间还没上屏的字**（中文输入法的 marked text）
                //     两样都管不着 —— 它用的是系统色，跟着**系统外观**走，
                //     他的系统是浅色模式 ⇒ 那一刻是黑的。
                //   ⇒ 真正的解法在 `LocalMusicApp.init()`：把程序钉在深色外观上
                //     （`NSAppearance.darkAqua`），系统色才会跟着变白。
                .foregroundStyle(Palette.textPrimary)
                .tint(Palette.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(6)
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.textSecondary.opacity(0.7))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 9).fill(Palette.field))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.stroke))
    }
}

/// 一颗会轻轻呼吸的小圆点。
///
/// 用途：进度条那头、说明卡左边。**它的全部意义就是"动"** ——
/// 百分比经常半分钟不涨，等待的人需要有个东西一直在动，才敢相信程序没卡死。
/// 用系统动画驱动（而不是自己开定时器）：不影响布局，也不占主线程。
private struct PulsingDot: View {
    var color: Color = .white
    var size: CGFloat = 7
    /// 暗下去时的不透明度。进度条上那颗要更含蓄一点，所以可以调。
    var dim: Double = 0.2

    @State private var bright = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(bright ? 1 : dim)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: bright)
            .onAppear { bright = true }
    }
}
