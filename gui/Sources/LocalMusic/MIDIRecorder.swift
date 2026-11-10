import Foundation
import CoreMIDI
import AVFoundation
import AppKit

/// 录一段「器乐草稿」—— 接 MIDI 键盘，弹什么记什么，用系统自带的通用音色出声。
///
/// 用户 2026-11-08 的要求：
/// 「最好能有一个 MIDI 录制功能。完全可以用那种默认的 general mid 的声音，
///  也不要选什么音色库，就是让用户弹器乐草稿的。」
///
/// 2026-11-08 当天追加三样（用户点名）：
///   · 节拍器 —— 录音时按速度打点，能关
///   · Tap Tempo —— 敲几下就定速度，不用填数字
///   · Pre-roll —— 录之前先空打一小节（或几拍），免得一按就开弹、头一拍被吃掉
///
/// 为什么用 CoreMIDI + AVAudioUnitSampler：两个都是系统框架，
/// 不用装任何东西、不出网；项目里「谱子出声」(ScorePlayer) 已经在用同一套音源。
final class MIDIRecorder: ObservableObject {

    struct Note {
        var pitch: Int
        var start: Double        // 秒，从录音真正开始那一刻算
        var duration: Double
        var velocity: Int
    }

    struct Device: Identifiable, Hashable {
        let id: MIDIEndpointRef
        let name: String
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var selected: MIDIEndpointRef = 0
    @Published private(set) var isRecording = false
    @Published private(set) var isCountingIn = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var noteCount: Int = 0
    @Published private(set) var message: String = ""
    @Published private(set) var lastTaps: [Date] = []
    @Published private(set) var metronomeTicking = false
    /// 收到的 MIDI 事件总数 —— 界面显示它，用来分辨"没收到"和"收到了没记上"
    @Published private(set) var midiEvents: Int = 0

    // 速度与节拍器
    @Published var bpm: Double = 88
    @Published var metronomeOn = true
    @Published var beatsPerBar = 4
    @Published var countInBeats = 4          // 预备几拍；0 = 不预备

    // 声卡（输出设备）
    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published var deviceID: AudioDeviceID?

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: MIDIEndpointRef = 0

    private var notes: [Note] = []
    /// 按下还没抬起的音（键 → 起点、力度）
    private var pending: [Int: (t: Double, vel: Int)] = [:]
    /// 收进来的所有音（含预备期），停止时再筛
    private var captured: [(pitch: Int, start: Double, duration: Double, vel: Int)] = []
    private var recordStartAt: Date?
    private var ticking = false
    private var clickTimer: Timer?
    private var displayTimer: Timer?
    private var beatIndex = 0

    // 出声
    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    /// 节拍器单独一个采样器，加载**打击乐**音色（木鱼）——
    /// 原来用 AVAudioPlayerNode 播自己合成的正弦，实测**完全没有声音**
    /// （buffer 的采样率和引擎实际输出对不上，scheduleBuffer 静默失败）。
    /// 打击乐 bank 走的是和钢琴同一个采样器路径，那条路已经验证能出声。
    private let clickSampler = AVAudioUnitSampler()
    private var clickReady = false

    init() {
        // 先把「上次选的声卡」认出来，再建引擎 —— 连线那一刻就要用对设备
        outputDevices = AudioDeviceCatalog.outputDevices()
        let saved = UserDefaults.standard.string(forKey: "outputDeviceName") ?? ""
        deviceID = AudioDeviceCatalog.resolve(savedName: saved)
        setupAudio()
        setupMIDI()
        refreshDevices()
    }

    // MARK: - 音源

    private func setupAudio() {
        engine.attach(sampler)
        engine.attach(clickSampler)

        // ① 先定声卡、再连线（跟 AudioDevices.play 那条老规矩一样：
        //    混音器会按连线那一刻的设备格式配好，之后再换就对不上了）
        applyDevice(userChosen: false)

        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        engine.connect(clickSampler, to: engine.mainMixerNode, format: nil)

        if let bank = Self.systemSoundBank() {
            try? sampler.loadSoundBankInstrument(at: bank,
                                                 program: 0,
                                                 bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                                 bankLSB: UInt8(kAUSampler_DefaultBankLSB))
            // 打击乐 bank：音色号在这里不重要，关键是 bankMSB 走打击乐那一档
            let drumStatus = (try? clickSampler.loadSoundBankInstrument(
                at: bank, program: 0,
                bankMSB: UInt8(kAUSampler_DefaultPercussionBankMSB),
                bankLSB: UInt8(kAUSampler_DefaultBankLSB))) != nil
            clickReady = drumStatus
            if !drumStatus { message = "打击乐音色没加载上，节拍器可能没声音" }
        } else {
            message = "系统音色库没找到，节拍器和钢琴都不会响"
        }

        do { try engine.start() } catch {
            message = "音源起不来：\(error.localizedDescription)"
        }
    }

    /// 把引擎的输出绑到某块声卡上（nil = 跟随系统）。
    private func applyDevice(userChosen: Bool) {
        guard let unit = engine.outputNode.audioUnit else { return }
        let target = deviceID ?? AudioDeviceCatalog.defaultOutputDeviceID()
        guard let target else { return }
        var value = target
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &value,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr, userChosen {
            message = "这块声卡切不上（错误码 \(status)），这次还是走系统默认"
            deviceID = nil
        }
    }

    /// 界面上换声卡：停 → 换 → 起。
    func setOutputDevice(_ id: AudioDeviceID?) {
        guard !isRecording else {
            message = "录着的时候别换声卡"
            return
        }
        deviceID = id
        engine.stop()
        applyDevice(userChosen: id != nil)
        do {
            try engine.start()
            message = id == nil ? "跟着系统走" : ""
        } catch {
            message = "换声卡之后起不来：\(error.localizedDescription)"
        }
        // 名字存起来 —— 设备 ID 每次开机都会变，名字才是稳的
        let name = id.flatMap { AudioDeviceCatalog.name(of: $0) } ?? ""
        UserDefaults.standard.set(name, forKey: "outputDeviceName")
    }

    /// 一个很短的「嗒」—— 纯正弦 + 淡出，不带任何采样，也不依赖音色库。
    private static func makeClick(frequency: Double, seconds: Double, gain: Float) -> AVAudioPCMBuffer? {
        let rate = 44_100.0
        let frames = AVAudioFrameCount(seconds * rate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            let env = exp(-t * 90)
            data[i] = Float(sin(2 * Double.pi * frequency * t) * env) * gain
        }
        return buffer
    }

    private static func systemSoundBank() -> URL? {
        let candidates = [
            "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls",
            "/System/Library/Components/DLSMusicDevice.component/Contents/Resources/gs_instruments.dls"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - MIDI 输入

    private func setupMIDI() {
        let status = MIDIClientCreateWithBlock("灵感路由-MIDI录音" as CFString, &client) { _ in
            DispatchQueue.main.async { [weak self] in self?.refreshDevices() }
        }
        guard status == noErr else {
            message = "系统不让连 MIDI（\(status)）"
            return
        }
        MIDIInputPortCreateWithBlock(client, "录音" as CFString, &port) { [weak self] packetList, _ in
            let data = Self.events(from: packetList)
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.handle(data) }
        }
    }

    private static func events(from list: UnsafePointer<MIDIPacketList>) -> [(UInt8, Int, Int)] {
        var out: [(UInt8, Int, Int)] = []
        var packet = list.pointee.packet
        for _ in 0..<list.pointee.numPackets {
            // ⚠️ 2026-11-08 修：原来用 Mirror 读 packet.data，它读满 256 字节
            // （元组的固定大小），把后面的垃圾也当成 MIDI 事件解析；真实事件混在里面，
            // 结果就是"弹得响、一个音也记不下"。这里按 packet.length 取真字节。
            let length = Int(packet.length)
            let bytes: [UInt8] = withUnsafeBytes(of: packet.data) { raw in
                Array(raw.prefix(max(0, min(length, raw.count))))
            }
            var i = 0
            while i + 1 < bytes.count {
                let status = bytes[i]
                let kind = status & 0xF0
                if kind == 0x80 || kind == 0x90 {
                    let pitch = Int(bytes[i + 1])
                    let vel = kind == 0x90 ? Int(bytes[i + 2]) : 0
                    out.append((kind, pitch, vel))
                    i += 3
                } else if kind == 0xB0 || kind == 0xE0 {
                    i += 3
                } else if kind == 0xC0 || kind == 0xD0 {
                    i += 2
                } else {
                    i += 1
                }
            }
            packet = MIDIPacketNext(&packet).pointee
        }
        return out
    }

    /// 重新问系统要一遍声卡列表（插拔设备之后点「刷新」）。
    func reloadDevices() {
        outputDevices = AudioDeviceCatalog.outputDevices()
    }

    func refreshDevices() {
        var found: [Device] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(i)
            guard endpoint != 0 else { continue }
            found.append(Device(id: endpoint, name: Self.name(of: endpoint)))
        }
        devices = found
        if connected == 0 || !found.contains(where: { $0.id == connected }) {
            if let first = found.first { select(first.id) }
        }
        if found.isEmpty {
            message = "还没看到 MIDI 键盘 —— 接上之后点「刷新」"
        }
    }

    private static func name(of endpoint: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cf)
        if let cf { return cf.takeRetainedValue() as String }
        return "MIDI 设备"
    }

    func select(_ endpoint: MIDIEndpointRef) {
        if connected != 0 {
            MIDIPortDisconnectSource(port, connected)
        }
        connected = endpoint
        selected = endpoint
        let status = MIDIPortConnectSource(port, endpoint, nil)
        message = status == noErr ? "" : "连不上这个设备（\(status)）"
    }

    // MARK: - Tap Tempo

    /// 敲一下。连敲两下以上就按最近几下的平均间隔定速度。
    func tap() {
        let now = Date()
        if let last = lastTaps.last, now.timeIntervalSince(last) > 2.0 {
            lastTaps = []
        }
        lastTaps.append(now)
        if lastTaps.count > 6 { lastTaps.removeFirst(lastTaps.count - 6) }
        guard lastTaps.count >= 2 else {
            message = "再敲几下就能定速度"
            return
        }
        var gaps: [Double] = []
        for i in 1..<lastTaps.count {
            gaps.append(lastTaps[i].timeIntervalSince(lastTaps[i - 1]))
        }
        let avg = gaps.reduce(0, +) / Double(gaps.count)
        guard avg > 0.15 else { return }
        bpm = min(300, max(30, 60.0 / avg))
        message = String(format: "速度定在 %.1f", bpm)
    }

    // MARK: - 录音

    private var preRollSeconds: Double {
        Double(countInBeats) * 60.0 / max(30, min(300, bpm))
    }

    func startRecording() {
        guard connected != 0 else {
            message = "先选一个 MIDI 设备"
            return
        }
        notes = []
        pending = [:]
        captured = []
        noteCount = 0
        elapsed = 0
        beatIndex = 0

        let start = Date().addingTimeInterval(preRollSeconds)
        recordStartAt = start
        isRecording = true
        isCountingIn = preRollSeconds > 0
        message = isCountingIn ? "预备 —— 听到点了再弹" : ""

        if metronomeOn { startClicking() }

        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordStartAt else { return }
            let now = Date()
            self.elapsed = max(0, now.timeIntervalSince(start))
            if self.isCountingIn, now >= start {
                self.isCountingIn = false
                if self.message == "预备 —— 听到点了再弹" { self.message = "在录了" }
            }
        }
    }

    func stopRecording() {
        guard isRecording, let start = recordStartAt else { return }
        let t = Date().timeIntervalSince(start)
        // 还没抬起的音，先收掉
        for (pitch, open) in pending {
            captured.append((pitch: pitch, start: open.t,
                             duration: max(0.05, t - open.t), vel: open.vel))
        }
        pending = [:]
        // 按「录音区间」筛：完全落在负时间的丢掉，跨过起点的钳到 0
        notes = captured.compactMap { c in
            if c.start + c.duration <= 0 { return nil }
            let s = max(0, c.start)
            let e = max(s + 0.05, c.start + c.duration)
            return Note(pitch: c.pitch, start: s, duration: e - s, velocity: c.vel)
        }
        captured = []
        noteCount = notes.count
        isRecording = false
        isCountingIn = false
        elapsed = max(0, t)
        stopClicking()
        displayTimer?.invalidate()
        displayTimer = nil
        if notes.isEmpty {
            message = "一个音都没录到 —— 确认一下点是不是打完了才开始弹"
        }
    }

    /// 取消这一遍（不要了）。
    func cancel() {
        stopClicking()
        displayTimer?.invalidate()
        displayTimer = nil
        notes = []
        pending = [:]
        captured = []
        isRecording = false
        isCountingIn = false
        noteCount = 0
        elapsed = 0
        recordStartAt = nil
        message = "这一遍丢掉了"
    }

    private func handle(_ events: [(UInt8, Int, Int)]) {
        let now = Date()
        let t = recordStartAt.map { now.timeIntervalSince($0) } ?? 0
        midiEvents += events.count
        for (kind, pitch, velocity) in events {
            if kind == 0x90 && velocity > 0 {
                play(pitch: pitch, velocity: velocity)
                // ★ 2026-11-08：不再看 isRecording —— 先统统收进来，停止时再按区间筛。
                //   原来"只在录音中才记"这一层判断，一旦时间算偏就整段白录。
                pending[pitch] = (t, velocity)
            } else {
                stop(pitch: pitch)
                if let open = pending.removeValue(forKey: pitch) {
                    captured.append((pitch: pitch, start: open.t,
                                     duration: max(0.05, t - open.t), vel: open.vel))
                }
            }
        }
    }

    private func play(pitch: Int, velocity: Int) {
        sampler.startNote(UInt8(clamping: pitch), withVelocity: UInt8(clamping: velocity), onChannel: 0)
    }

    private func stop(pitch: Int) {
        sampler.stopNote(UInt8(clamping: pitch), onChannel: 0)
    }

    // MARK: - 节拍器

    func startClicking() {
        stopClicking()
        ticking = true
        metronomeTicking = true
        beatIndex = 0
        let interval = 60.0 / max(30, min(300, bpm))
        clickTick()                                     // 第一下立刻打
        clickTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.clickTick()
        }
    }

    private func clickTick() {
        guard ticking else { return }
        let strong = beatIndex % max(1, beatsPerBar) == 0
        if clickReady {
            // GM 打击乐：76 = 高音木鱼、77 = 低音木鱼，9 是打击乐通道
            clickSampler.startNote(strong ? 76 : 77,
                                   withVelocity: strong ? 112 : 84,
                                   onChannel: 9)
        }
        beatIndex += 1
    }

    private func stopClicking() {
        ticking = false
        metronomeTicking = false
        clickTimer?.invalidate()
        clickTimer = nil
    }

    /// 单独试一下速度（不录音）。
    func toggleMetronome() {
        guard !isRecording else { return }
        if ticking { stopClicking() } else { startClicking() }
    }

    // MARK: - 试听

    func playBack() {
        guard !isRecording, !notes.isEmpty else { return }
        engine.stop()
        try? engine.start()
        for note in notes {
            DispatchQueue.main.asyncAfter(deadline: .now() + note.start) { [weak self] in
                self?.play(pitch: note.pitch, velocity: note.velocity)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + note.start + note.duration) { [weak self] in
                self?.stop(pitch: note.pitch)
            }
        }
        message = "正在放这一遍"
    }

    // MARK: - 存成 .mid

    /// 写成标准 MIDI 文件（format 0，单轨）。
    ///
    /// ⚠️ 2026-11-08 修：原来把「秒」直接当拍（乘 4），等于写死 240 BPM。
    /// 现在按面板上的速度换算成四分音符数 —— 拖进任何软件都是这个速度。
    func writeMIDI(to url: URL) throws {
        guard !notes.isEmpty else { throw NSError(domain: "midi", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "还没有录到音"]) }
        let division = 480
        let total = notes.map { $0.start + $0.duration }.max() ?? 0
        guard total > 0 else { throw NSError(domain: "midi", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "时长是 0"]) }

        struct Ev { var beat: Double; var on: Bool; var pitch: Int; var velocity: Int }
        var evs: [Ev] = []
        let secondsPerBeat = 60.0 / max(30, min(300, bpm))
        for n in notes {
            evs.append(Ev(beat: n.start / secondsPerBeat, on: true, pitch: n.pitch, velocity: n.velocity))
            evs.append(Ev(beat: (n.start + n.duration) / secondsPerBeat, on: false,
                          pitch: n.pitch, velocity: 0))
        }
        evs.sort { $0.beat == $1.beat ? (!$0.on && $1.on) : $0.beat < $1.beat }

        var track = Data()
        // ★ 2026-11-08：补上**速度和拍号**。
        //   不写的话，拖进 ACE / DAW 会按默认 120 播 —— 音符关系对，整体快慢错。
        //   速度事件：FF 51 03 + 每四分音符多少微秒
        let micros = Int(60_000_000.0 / max(30, min(300, bpm)))
        track.append(contentsOf: [0x00, 0xFF, 0x51, 0x03,
                                  UInt8((micros >> 16) & 0xFF),
                                  UInt8((micros >> 8) & 0xFF),
                                  UInt8(micros & 0xFF)] as [UInt8])
        // 拍号事件：FF 58 04 + 分子 + 2 的幂 + 24 + 8（4/4 就是 04 02 18 08）
        let beatTypePower = 2                       // 4 分音符
        track.append(contentsOf: [0x00, 0xFF, 0x58, 0x04,
                                  UInt8(clamping: beatsPerBar), UInt8(beatTypePower),
                                  0x18, 0x08] as [UInt8])
        var lastTick = 0
        for e in evs {
            let tick = Int((e.beat * Double(division)).rounded())
            let delta = max(0, tick - lastTick)
            lastTick = tick
            track.append(contentsOf: Self.vlq(delta))
            track.append(contentsOf: [e.on ? 0x90 : 0x80, UInt8(clamping: e.pitch),
                                      UInt8(clamping: e.velocity)])
        }
        track.append(contentsOf: [0x00, 0xFF, 0x2F, 0x00] as [UInt8])

        var out = Data("MThd".utf8)
        out.append(contentsOf: [0, 0, 0, 6, 0, 0, 0, 1] as [UInt8])
        out.append(contentsOf: [UInt8((division >> 8) & 0xFF), UInt8(division & 0xFF)])
        out.append(Data("MTrk".utf8))
        out.append(contentsOf: [UInt8((track.count >> 24) & 0xFF), UInt8((track.count >> 16) & 0xFF),
                                UInt8((track.count >> 8) & 0xFF), UInt8(track.count & 0xFF)])
        out.append(track)
        try out.write(to: url)
    }

    private static func vlq(_ value: Int) -> [UInt8] {
        var v = value
        var bytes = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            bytes.insert(UInt8((v & 0x7F) | 0x80), at: 0)
            v >>= 7
        }
        return bytes
    }

    var hasNotes: Bool { !notes.isEmpty }

    func report(_ text: String) { message = text }
}
