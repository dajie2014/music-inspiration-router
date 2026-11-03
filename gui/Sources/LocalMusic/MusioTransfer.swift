import Foundation

// MARK: - 把这一首送进 Musio Studio（2026-11-03）
//
// 跟 `LiveTransfer` / `ACEDraftTransfer` 一样，这层是**薄壳**：
// 真正干活的在上一级的 `musio-bridge/musio_bridge.py` —— 它连 Studio 的
// 本机接口（127.0.0.1:47820），把音频放到**光标处**，有句表就按句切开。
//
// ★ 前提：Musio Studio 开着，并且「设置 → Agents」里那个开关打开。
//   没开时它会明确报「连不上」，不会静默失败。

struct MusioTransferResult {
    var ok: Bool
    var message: String
}

enum MusioTransfer {

    /// 桥的位置：`default-workspace/musio-bridge/musio_bridge.py`（在项目根的上一级）。
    private static var script: URL {
        BackendClient.locateRoot()
            .deletingLastPathComponent()
            .appendingPathComponent("musio-bridge/musio_bridge.py")
    }

    /// 把一首的音频（flac/wav）送进 Studio。**阻塞**（几秒），调用方放后台线程。
    static func sendAudio(_ audio: URL, title: String) -> MusioTransferResult {
        guard FileManager.default.fileExists(atPath: script.path) else {
            return MusioTransferResult(ok: false,
                                       message: "找不到 musio-bridge/musio_bridge.py。")
        }
        let result = run("/usr/bin/python3",
                         [script.path, "send-audio",
                          "--path", audio.path,
                          "--track", trackName(title)],
                         timeout: 120)
        return interpret(result, what: "送 Musio")
    }

    /// 把一份 MIDI 送进 Studio —— 只放声部，不带它自己的速度。
    static func sendMIDI(_ midi: URL, title: String) -> MusioTransferResult {
        guard FileManager.default.fileExists(atPath: script.path) else {
            return MusioTransferResult(ok: false,
                                       message: "找不到 musio-bridge/musio_bridge.py。")
        }
        let result = run("/usr/bin/python3",
                         [script.path, "send-midi", "--path", midi.path],
                         timeout: 120)
        return interpret(result, what: "送 Musio")
    }

    private static func trackName(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "MIR" : "MIR · \(t)"
    }

    private static func interpret(_ result: ToolResult, what: String) -> MusioTransferResult {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0 else {
            let tail = text.split(separator: "\n").last.map(String.init) ?? text
            return MusioTransferResult(ok: false,
                                       message: tail.isEmpty ? "\(what)的脚本没吭声。" : tail)
        }
        // 桥输出是纯文本：第一行「落到第 N 小节」，中间「切在 …」，最后一行「完成」。
        let lines = text.split(separator: "\n").map(String.init)
        let landed = lines.first { $0.contains("落到第") } ?? ""
        let cuts = lines.filter { $0.contains("切在") }.count
        var message = "已送进 Musio Studio"
        if !landed.isEmpty { message += "：" + landed }
        if cuts > 0 { message += "，切成 \(cuts + 1) 段" }
        return MusioTransferResult(ok: true, message: message + "。")
    }

    // MARK: - 跑脚本

    private struct ToolResult {
        var status: Int32
        var text: String
    }

    private static func run(_ executable: String, _ arguments: [String],
                            timeout: TimeInterval) -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ToolResult(status: -1, text: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ToolResult(status: process.terminationStatus,
                          text: String(data: data, encoding: .utf8) ?? "")
    }
}
