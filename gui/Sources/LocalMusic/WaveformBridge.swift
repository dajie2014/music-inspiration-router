import Foundation
import AppKit

/// 灵感路由 ⇄ Waveform 的交接（2026-10-29）。
///
/// 只做一件事：把这一首的 **MIDI 和音频** 复制到一个固定文件夹，
/// 然后在访达里把它打开。用户在 Waveform 里拖进工程就行。
///
/// **为什么只做到这一步**：Waveform 没有"从外部往当前工程里插素材"的接口。
/// 想做到"按一下素材就出现在轨道上"，只能去改它的工程文件（`.tracktionedit`），
/// 那是另一件事 —— 格式没摸清就改会把工程改坏，先不做。
///
/// **为什么放在「音乐」里**：工程、采样、导出物通常都在这儿，不用满硬盘找。
enum WaveformBridge {

    /// 交接文件夹。**所有来自灵感路由的素材都放这一个地方** ——
    /// 用户只需要记住一个位置。
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/灵感路由-交接", isDirectory: true)
    }

    struct Result {
        var ok: Bool
        var message: String
    }

    /// 把这一首能给的都送过去。
    ///
    /// - Parameters:
    ///   - title: 歌名，用来起文件名
    ///   - audio: 生成的音频（可能没有）
    ///   - midi: 拆轨的 MIDI（可能没有）
    /// - Returns: 一句话，界面直接显示
    static func send(title: String, audio: URL?, midi: URL?) -> Result {
        guard audio != nil || midi != nil else {
            return Result(ok: false, message: "这一首还没有音频或 MIDI，没东西可送。")
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return Result(ok: false, message: "建不了交接文件夹：\(error.localizedDescription)")
        }

        let stem = FileName.safe(title.isEmpty ? "未命名" : title)
        var sent: [String] = []
        var failed: [String] = []

        if let midi {
            do {
                let name = try uniqueName(stem: "\(stem)", ext: "mid", in: folder)
                try fm.copyItem(at: midi, to: folder.appendingPathComponent(name))
                sent.append(name)
            } catch {
                failed.append("MIDI（\(error.localizedDescription)）")
            }
        }

        if let audio {
            let ext = audio.pathExtension.isEmpty ? "wav" : audio.pathExtension.lowercased()
            do {
                let name = try uniqueName(stem: "\(stem)", ext: ext, in: folder)
                try fm.copyItem(at: audio, to: folder.appendingPathComponent(name))
                sent.append(name)
            } catch {
                failed.append("音频（\(error.localizedDescription)）")
            }
        }

        // 不管成没成，都把文件夹打开 —— 成功了他直接拖，失败了他也能看见目录
        NSWorkspace.shared.open(folder)

        if sent.isEmpty {
            return Result(ok: false, message: "没送成功：\(failed.joined(separator: "；"))")
        }
        var message = "已送到「\(folder.lastPathComponent)」：\(sent.joined(separator: "、"))"
            + " —— 在 Waveform 里拖进去就行"
        if !failed.isEmpty {
            message += "；没送成：\(failed.joined(separator: "；"))"
        }
        return Result(ok: true, message: message)
    }

    /// 起了个不撞车的名字：`歌名.mid`；已经有了就 `歌名-2.mid`。
    ///
    /// **不覆盖**：他可能刚在 Waveform 里用过上一版，覆盖掉就找不回来了。
    private static func uniqueName(stem: String, ext: String, in folder: URL) throws -> String {
        let fm = FileManager.default
        var name = "\(stem).\(ext)"
        var n = 2
        while fm.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(stem)-\(n).\(ext)"
            n += 1
            if n > 99 { break }
        }
        return name
    }
}
