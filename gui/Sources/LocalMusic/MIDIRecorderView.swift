import SwiftUI
import CoreMIDI
import CoreAudio

/// 「录 MIDI」那个小窗：接键盘 → 定速度 → 弹 → 存成 .mid → 交给器乐版。
///
/// 用户 2026-11-08 的要求：不用挑音色，就用系统通用音色（固定大钢琴）；
/// 当天又点名加三样 —— **节拍器 / Tap Tempo / Pre-roll**。
struct MIDIRecorderView: View {
    @StateObject private var recorder = MIDIRecorder()
    @Environment(\.dismiss) private var dismiss

    var onSave: (URL) -> Void

    /// 空格键监听（见 onAppear）：录音时按空格 = 停。
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("弹一段器乐草稿")
                .font(.title2.weight(.semibold))
            Text("接上 MIDI 键盘就能弹。用的是系统自带的大钢琴音色，不用挑音色库。录完直接交给「器乐版」出一版器乐。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 设备
            HStack(spacing: 10) {
                if recorder.devices.isEmpty {
                    Text("还没看到 MIDI 键盘").foregroundStyle(.secondary)
                } else {
                    Picker("设备", selection: Binding(
                        get: { recorder.selected },
                        set: { recorder.select($0) })) {
                        ForEach(recorder.devices) { d in
                            Text(d.name).tag(d.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260)
                }
                Button("刷新") { recorder.refreshDevices() }
                Spacer()
            }

            // 声卡（输出设备）：节拍器和钢琴都从这块卡出去，跟「试听」共用同一个设置
            HStack(spacing: 10) {
                Text("声卡").foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { recorder.deviceID ?? AudioDeviceID(0) },
                    set: { recorder.setOutputDevice($0 == 0 ? nil : $0) })) {
                    Text("跟随系统").tag(AudioDeviceID(0))
                    ForEach(recorder.outputDevices) { d in
                        Text(d.name).tag(d.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 320)
                Button("刷新") { recorder.reloadDevices() }
                Spacer()
            }

            // 速度、节拍器、预备拍
            HStack(spacing: 12) {
                Text("速度").foregroundStyle(.secondary)
                TextField("", value: $recorder.bpm, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .multilineTextAlignment(.center)
                Text("BPM").font(.caption).foregroundStyle(.secondary)

                Button {
                    recorder.tap()
                } label: {
                    Label("Tap", systemImage: "hand.tap")
                }
                .help("跟着心里的拍子敲四下，它自己算速度")

                Toggle("节拍器", isOn: $recorder.metronomeOn)
                    .toggleStyle(.checkbox)
                Button(recorder.metronomeTicking ? "停点" : "试一下") {
                    recorder.toggleMetronome()
                }
                .disabled(recorder.isRecording)

                Picker("预备", selection: $recorder.countInBeats) {
                    Text("不预备").tag(0)
                    Text("1 小节").tag(4)
                    Text("2 小节").tag(8)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 150)
            }

            // 录音
            HStack(spacing: 14) {
                Button {
                    if recorder.isRecording {
                        recorder.stopRecording()
                    } else {
                        recorder.startRecording()
                    }
                } label: {
                    Label(recorder.isRecording ? (recorder.isCountingIn ? "预备中…" : "停") : "开始录",
                          systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : .accentColor)
                .disabled(recorder.selected == 0)
                // 用户 2026-11-08 要的：录完按空格停，不用去点按钮
                Text(recorder.isRecording ? "（按空格停）" : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(String(format: "%02d:%05.2f", Int(recorder.elapsed) / 60, recorder.elapsed))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(recorder.isRecording ? .red : .primary)
                Text("\(recorder.noteCount) 个音").foregroundStyle(.secondary)
                // 出问题时靠这一条分辨：是键盘没进来，还是进来了没记上
                Text("· 收到 \(recorder.midiEvents) 条 MIDI")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("听一遍") { recorder.playBack() }
                    .disabled(recorder.isRecording || !recorder.hasNotes)
            }

            if !recorder.message.isEmpty {
                Text(recorder.message)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Divider()

            HStack {
                Button("关掉") { dismiss() }
                if recorder.hasNotes || recorder.isRecording {
                    Button("这一遍不要了") { recorder.cancel() }
                }
                Spacer()
                Button("存下来，交给器乐版") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(recorder.isRecording || !recorder.hasNotes)
                // 2026-11-08 用户提的：录好的 MIDI 要能直接送出去 ——
                // 主界面上「有 MIDI 能送」的去处，这里一个不少。
                Menu("存下来，送到…") {
                    Button("ACE Studio") { saveAndSend(to: "ACE") }
                    Button("Ableton Live") { saveAndSend(to: "Live") }
                    Button("Waveform") { saveAndSend(to: "Waveform") }
                    Button("Musio Studio") { saveAndSend(to: "Musio") }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(recorder.isRecording || !recorder.hasNotes)
            }
        }
        .padding(22)
        .frame(width: 640)
        .onAppear {
            recorder.refreshDevices()
            // 空格 = 停止录音。用本地按键监听而不是 SwiftUI 的 onKeyPress：
            // 后者要求视图有焦点，而这个小窗里焦点常在输入框上。
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 49 else { return event }   // 49 = 空格
                // 正在输入框里打字（比如改速度），别抢空格
                if NSApp.keyWindow?.firstResponder is NSTextView { return event }
                if recorder.isRecording {
                    recorder.stopRecording()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            if recorder.isRecording { recorder.stopRecording() }
        }
    }

    /// 存一份 .mid，然后直接送到某个去处（都在后台跑 —— 那几个接口会阻塞几十秒）。
    ///
    /// 用的是主界面同一套发送层，不另起一套：界面上的「MIDI → ACE / MIDI → Live」
    /// 跟这里是同一个脚本、同一份回执文案。
    private func saveAndSend(to target: String) {
        let url = midiFileURL()
        do {
            try recorder.writeMIDI(to: url)
        } catch {
            recorder.report("存不下来：\(error.localizedDescription)")
            return
        }
        let title = url.deletingPathExtension().lastPathComponent
        recorder.report("存好了，正在送到 \(target)…")
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = true
            var text = ""
            switch target {
            case "ACE":
                let r = ACEDraftTransfer.send(.init(audio: nil, score: nil, midi: url, title: title))
                ok = r.ok; text = r.message
            case "Live":
                let r = LiveTransfer.sendMIDI(url)
                ok = r.ok; text = r.message
            case "Waveform":
                let r = WaveformBridge.send(title: title, audio: nil, midi: url)
                ok = r.ok; text = r.message
            default:
                let r = MusioTransfer.sendMIDI(url, title: title)
                ok = r.ok; text = r.message
            }
            let final = (ok ? "" : "⚠️ ") + text
            DispatchQueue.main.async {
                recorder.report(final)
            }
        }
    }

    private func midiFileURL() -> URL {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("器乐草稿-\(stamp).mid")
    }

    private func save() {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("器乐草稿-\(stamp).mid")
        do {
            try recorder.writeMIDI(to: url)
            onSave(url)
            dismiss()
        } catch {
            recorder.report("存不下来：\(error.localizedDescription)")
        }
    }
}
