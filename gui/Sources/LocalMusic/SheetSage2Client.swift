import Foundation

/// 8001 语义服务的唯一客户端。
///
/// Copyright (c) 2026 Jie Da / Inspiration-Assistant
/// SheetSage2 x YuE2 Integration - local, non-commercial research use only.
///
/// 三条工作流共用这一份：
///   · Flow-B：导入 MusicXML → 读人写的和弦（只读，不改）
///   · Flow-A：AI 出的 ABC → 校验 / 补格式
///   · Flow-C：音频转谱 → 校验 / 补格式
///
/// **一律用 base64 传文件，不传路径。** 服务是 launchd 常驻进程，
/// macOS 的隐私保护会拦住它读 `~/Documents` —— 实测同一请求走路径要 177 秒，
/// 走 base64 只要 0.035 秒（2026-10-24 量到的）。
enum SheetSage2Client {

    static let endpoint = URL(string: "http://127.0.0.1:8001")!

    // MARK: - 返回结构

    struct ChordAudit: Decodable {
        var xmlChords: Int = 0
        var abcChords: Int = 0
        var inOrderMatches: Int = 0
        var chordsRewritten: Bool = true

        enum CodingKeys: String, CodingKey {
            case xmlChords = "xml_chords"
            case abcChords = "abc_chords"
            case inOrderMatches = "in_order_matches"
            case chordsRewritten = "chords_rewritten"
        }
    }

    struct Result {
        var flow: String = ""
        var barCount: Int = 0
        var repairedABC: String = ""
        var melodyABC: String = ""
        var conditionJSON: String = ""
        var chordAudit = ChordAudit()
        var interludeBars: [Int] = []
        var notesInjected: Int = 0
        var human: String = ""
    }

    enum Failure: LocalizedError {
        case offline
        case rejected(String)
        case badPayload

        var errorDescription: String? {
            switch self {
            case .offline:
                return "谱面服务还没起来，这一趟只用原来的路。"
            case .rejected(let human):
                return human
            case .badPayload:
                return "谱面服务回了一句看不懂的话。"
            }
        }
    }

    // MARK: - 调服务

    static func analyze(flow: String, musicxml: Data?, abc: String?,
                        vocalPart: String? = nil, timeout: TimeInterval = 60) async throws -> Result {
        var body: [String: Any] = ["flow": flow]
        if let musicxml {
            body["musicxml_base64"] = musicxml.base64EncodedString()
        }
        if let abc, !abc.isEmpty {
            body["abc_text"] = abc
        }
        if let vocalPart, !vocalPart.isEmpty {
            body["vocal_part"] = vocalPart
        }

        var request = URLRequest(url: endpoint.appendingPathComponent("analyze_score"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badPayload }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if http.statusCode != 200 {
            if let error = object["error"] as? [String: Any],
               let human = error["human"] as? String {
                throw Failure.rejected(human)
            }
            throw Failure.rejected("谱面服务这一步没成（\(http.statusCode)）。")
        }

        return try parse(object, fallbackFlow: flow)
    }

    /// Flow-C 的音频转谱。服务端起一次性子进程；这里只要等。
    static func transcribe(audioPath: String, task: String = "melody-full",
                           timeout: TimeInterval = 1800) async throws -> Result {
        var request = URLRequest(url: endpoint.appendingPathComponent("transcribe"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["audio_path": audioPath, "task": task])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badPayload }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if http.statusCode != 200 {
            if let error = object["error"] as? [String: Any],
               let human = error["human"] as? String {
                throw Failure.rejected(human)
            }
            throw Failure.rejected("音频转谱这一步没成（\(http.statusCode)）。")
        }
        return try parse(object, fallbackFlow: "C")
    }

    /// analyze 和 transcribe 的返回形状一样（都是 flow + outputs + diagnostics），
    /// 所以解析只写一份。
    private static func parse(_ object: [String: Any], fallbackFlow: String) throws -> Result {
        guard let outputs = object["outputs"] as? [String: Any] else {
            throw Failure.badPayload
        }

        var result = Result()
        result.flow = object["flow"] as? String ?? fallbackFlow
        result.barCount = object["bar_count"] as? Int ?? 0
        result.repairedABC = outputs["repaired_abc"] as? String ?? ""
        result.melodyABC = outputs["melody_abc"] as? String ?? ""
        if let condition = outputs["structured_condition_json"] as? [String: Any] {
            if let pretty = try? JSONSerialization.data(
                withJSONObject: condition, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: pretty, encoding: .utf8) {
                result.conditionJSON = text
            }
            if let summary = condition["summary"] as? [String: Any],
               let bars = summary["interlude_bars"] as? [Int] {
                result.interludeBars = bars
            }
        }
        if let guarantees = object["guarantees"] as? [String: Any] {
            result.notesInjected = guarantees["notes_injected"] as? Int ?? 0
        }
        if let diagnostics = object["diagnostics"] as? [String: Any],
           let audit = diagnostics["chord_audit"] as? [String: Any] {
            result.chordAudit.xmlChords = audit["xml_chords"] as? Int ?? 0
            result.chordAudit.abcChords = audit["abc_chords"] as? Int ?? 0
            result.chordAudit.inOrderMatches = audit["in_order_matches"] as? Int ?? 0
            result.chordAudit.chordsRewritten = audit["chords_rewritten"] as? Bool ?? true
        }
        result.human = humanSummary(result)
        return result
    }

    /// 一句话人话 —— 界面只显示它，不显示 JSON。
    static func humanSummary(_ result: Result) -> String {
        let audit = result.chordAudit
        var parts: [String] = []
        if audit.xmlChords > 0 {
            if audit.inOrderMatches == audit.xmlChords, !audit.chordsRewritten {
                parts.append("手写和弦 \(audit.xmlChords) 个，逐条核对全部原样保留")
            } else {
                parts.append("手写和弦 \(audit.xmlChords) 个，核对上 \(audit.inOrderMatches) 个")
            }
        }
        if !result.interludeBars.isEmpty {
            parts.append("间奏 \(result.interludeBars.count) 小节：人声停、伴奏继续")
        }
        if result.barCount > 0 {
            parts.append("共 \(result.barCount) 小节")
        }
        return parts.joined(separator: "；")
    }

    // MARK: - 把 MusicXML 转成 ABC（只为了给面板看和给服务校验）

    /// 用项目里现成的 `xml2abc` 转一份到 `~/inspiration-assistant/abc-cache/inbox/`。
    ///
    /// 不弹面板、不碰用户目录 —— 这只是中间件。转不出来就返回 nil，
    /// 界面退回"只核对和弦、不显示谱面"，不阻塞生成。
    static func convertMusicXMLToABC(_ file: URL, projectRoot: URL) -> String? {
        let inbox = SheetSage2Paths.inbox
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        let script = projectRoot
            .deletingLastPathComponent()
            .appendingPathComponent("yue2-local/tools/xml2abc/xml2abc_179/xml2abc.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "-o", inbox.path, file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let made = inbox.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".abc")
        return try? String(contentsOf: made, encoding: .utf8)
    }
}

/// `~/inspiration-assistant/` 下的固定位置。服务、App 都照这一份走。
enum SheetSage2Paths {
    static var base: URL {
        URL(fileURLWithPath: NSString(string: "~/inspiration-assistant").expandingTildeInPath)
    }
    static var cache: URL { base.appendingPathComponent("abc-cache") }
    static var inbox: URL { cache.appendingPathComponent("inbox") }
    static var edited: URL { cache.appendingPathComponent("edited") }
}
