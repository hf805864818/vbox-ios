import Foundation

// MARK: - 字幕数据模型

/// 单条字幕
struct SubtitleCue: Identifiable {
    let id = UUID()
    let startTime: Double   // 开始时间（秒）
    let endTime: Double     // 结束时间（秒）
    let text: String        // 字幕文本（可含换行）
}

// MARK: - 字幕解析器
/// 支持 SRT / VTT / ASS 三种格式的字幕文件解析
/// 纯 Swift 实现，不依赖播放引擎
enum SubtitleParser {

    enum SubtitleFormat {
        case srt
        case vtt
        case ass
        case unknown
    }

    // MARK: - 主入口

    /// 从文件 URL 解析字幕
    static func parse(url: URL) -> [SubtitleCue]? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            // 尝试其他编码
            if let data = try? Data(contentsOf: url),
               let str = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) ?? String(data: data, encoding: .utf16) {
                return parse(content: str, format: detectFormat(url: url))
            }
            return nil
        }
        let format = detectFormat(url: url)
        return parse(content: content, format: format)
    }

    /// 从文本内容解析字幕
    static func parse(content: String, format: SubtitleFormat) -> [SubtitleCue] {
        switch format {
        case .srt:
            return parseSRT(content)
        case .vtt:
            return parseVTT(content)
        case .ass:
            return parseASS(content)
        case .unknown:
            // 自动检测
            if content.hasPrefix("WEBVTT") {
                return parseVTT(content)
            } else if content.contains("[Events]") {
                return parseASS(content)
            } else {
                return parseSRT(content)
            }
        }
    }

    // MARK: - 格式检测

    static func detectFormat(url: URL) -> SubtitleFormat {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "srt": return .srt
        case "vtt": return .vtt
        case "ass", "ssa": return .ass
        default: return .unknown
        }
    }

    // MARK: - SRT 解析
    /// 格式示例：
    /// 1
    /// 00:00:01,000 --> 00:00:03,000
    /// 字幕文本
    /// (空行)
    static func parseSRT(_ content: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        // 按空行分割块
        let blocks = content.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard lines.count >= 2 else { continue }

            // 查找时间轴行（包含 -->）
            var timeLineIndex = -1
            for (i, line) in lines.enumerated() {
                if line.contains("-->") {
                    timeLineIndex = i
                    break
                }
            }
            guard timeLineIndex >= 0 else { continue }

            let times = parseTimeLine(lines[timeLineIndex], separator: ",")
            guard times.0 >= 0, times.1 > 0 else { continue }

            // 时间轴后的行都是字幕文本
            let textLines = lines[(timeLineIndex + 1)...].filter { !$0.isEmpty }
            let text = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            cues.append(SubtitleCue(startTime: times.0, endTime: times.1, text: text))
        }

        return cues.sorted { $0.startTime < $1.startTime }
    }

    // MARK: - VTT 解析
    /// 格式示例：
    /// WEBVTT
    /// 00:00:01.000 --> 00:00:03.000
    /// 字幕文本
    static func parseVTT(_ content: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard !lines.isEmpty else { continue }

            // 查找时间轴行
            var timeLineIndex = -1
            for (i, line) in lines.enumerated() {
                if line.contains("-->") {
                    timeLineIndex = i
                    break
                }
            }
            guard timeLineIndex >= 0 else { continue }

            let times = parseTimeLine(lines[timeLineIndex], separator: ".")
            guard times.0 >= 0, times.1 > 0 else { continue }

            let textLines = lines[(timeLineIndex + 1)...].filter { !$0.isEmpty }
            let text = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            cues.append(SubtitleCue(startTime: times.0, endTime: times.1, text: text))
        }

        return cues.sorted { $0.startTime < $1.startTime }
    }

    // MARK: - ASS/SSA 解析
    /// 格式示例：
    /// [Events]
    /// Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    /// Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,字幕文本
    static func parseASS(_ content: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        // 查找 Format 行确定字段顺序
        var formatFields: [String] = []
        var inEventsSection = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inEventsSection = trimmed.contains("[Events]")
                continue
            }

            if inEventsSection {
                if trimmed.lowercased().hasPrefix("format:") {
                    let formatStr = trimmed.substring(from: trimmed.index(trimmed.startIndex, offsetBy: 7))
                    formatFields = formatStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    continue
                }

                if trimmed.lowercased().hasPrefix("dialogue:") {
                    let dialogueStr = trimmed.substring(from: trimmed.index(trimmed.startIndex, offsetBy: 9))
                    // ASS 字段用逗号分割，但 Text 字段本身可能含逗号
                    // 根据 Format 行的字段数来分割
                    let fields = parseASSDialogueFields(dialogueStr, fieldCount: formatFields.count)

                    guard formatFields.count >= 3,
                          fields.count >= formatFields.count else { continue }

                    let startIdx = formatFields.firstIndex(of: "start") ?? 1
                    let endIdx = formatFields.firstIndex(of: "end") ?? 2
                    let textIdx = formatFields.firstIndex(of: "text") ?? (formatFields.count - 1)

                    guard startIdx < fields.count, endIdx < fields.count, textIdx < fields.count else { continue }

                    let startTime = parseASSTime(fields[startIdx].trimmingCharacters(in: .whitespaces))
                    let endTime = parseASSTime(fields[endIdx].trimmingCharacters(in: .whitespaces))
                    guard startTime >= 0, endTime > 0 else { continue }

                    // ASS 字幕文本处理：\N → 换行，去除 ASS 样式标签 {\...}
                    var rawText = fields[textIdx].trimmingCharacters(in: .whitespaces)
                    // 合并 Text 之后的多余字段（逗号分割导致的）
                    if textIdx < fields.count - 1 {
                        let extraFields = fields[(textIdx + 1)...]
                        rawText = ([rawText] + extraFields).joined(separator: ",")
                    }
                    let text = cleanASSText(rawText)
                    guard !text.isEmpty else { continue }

                    cues.append(SubtitleCue(startTime: startTime, endTime: endTime, text: text))
                }
            }
        }

        return cues.sorted { $0.startTime < $1.startTime }
    }

    // MARK: - 时间解析工具

    /// 解析时间轴行，如 "00:00:01,000 --> 00:00:03,000"
    /// separator: SRT 用逗号，VTT 用点
    private static func parseTimeLine(_ line: String, separator: Character) -> (Double, Double) {
        // 提取 --> 两侧的时间
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return (-1, -1) }

        let startTime = parseTimeString(parts[0].trimmingCharacters(in: .whitespaces), separator: separator)
        let endTime = parseTimeString(parts[1].trimmingCharacters(in: .whitespaces), separator: separator)

        return (startTime, endTime)
    }

    /// 解析单个时间字符串 "00:01:23,456" 或 "00:01:23.456" 或 "01:23"
    private static func parseTimeString(_ timeStr: String, separator: Character) -> Double {
        // 去除可能的前后空格和 VTT 的位置标记（如 "00:00:01.000 line:80%"）
        let cleaned = timeStr.components(separatedBy: " ").first ?? timeStr

        // 将分隔符统一为点
        let normalized = cleaned.replacingOccurrences(of: String(separator), with: ".")

        let components = normalized.components(separatedBy: ":")

        switch components.count {
        case 3: // HH:MM:SS.mmm
            let h = Double(components[0]) ?? 0
            let m = Double(components[1]) ?? 0
            let s = Double(components[2]) ?? 0
            return h * 3600 + m * 60 + s
        case 2: // MM:SS.mmm
            let m = Double(components[0]) ?? 0
            let s = Double(components[1]) ?? 0
            return m * 60 + s
        case 1: // SS.mmm
            return Double(components[0]) ?? 0
        default:
            return -1
        }
    }

    /// 解析 ASS 时间格式 "0:00:01.00" 或 "0:0:01.00"
    private static func parseASSTime(_ timeStr: String) -> Double {
        let parts = timeStr.components(separatedBy: ":")
        guard parts.count == 3 else { return -1 }
        let h = Double(parts[0]) ?? 0
        let m = Double(parts[1]) ?? 0
        let s = Double(parts[2]) ?? 0
        return h * 3600 + m * 60 + s
    }

    // MARK: - ASS 文本处理

    /// ASS Dialogue 行字段分割
    /// 前 N-1 个字段按逗号分割，最后一个字段（Text）保留所有逗号
    private static func parseASSDialogueFields(_ str: String, fieldCount: Int) -> [String] {
        guard fieldCount > 1 else {
            return [str]
        }
        var fields: [String] = []
        var remaining = str
        for _ in 0..<(fieldCount - 1) {
            if let commaRange = remaining.range(of: ",") {
                fields.append(String(remaining[..<commaRange.lowerBound]))
                remaining = String(remaining[commaRange.upperBound...])
            } else {
                fields.append(remaining)
                remaining = ""
            }
        }
        fields.append(remaining) // 最后一个字段是 Text
        return fields
    }

    /// 清理 ASS 字幕文本
    /// \N / \n → 换行
    /// {\...} → 移除 ASS 样式标签
    private static func cleanASSText(_ text: String) -> String {
        var result = text
        // 移除 {\...} 样式标签
        while let start = result.range(of: "{"), let end = result.range(of: "}", range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        // \N 和 \n → 换行
        result = result.replacingOccurrences(of: "\\N", with: "\n")
        result = result.replacingOccurrences(of: "\\n", with: "\n")
        // \h → 空格
        result = result.replacingOccurrences(of: "\\h", with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
