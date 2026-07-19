import Foundation

/// Renders a meeting to an Obsidian-friendly Markdown document: YAML
/// frontmatter (title, dates, language, kind, tags) followed by the summary
/// and the full transcript. Pure and side-effect-free so it's unit-testable;
/// the file-save flow (NSSavePanel + write) lives at the call site.
///
/// Local export is a data-ownership feature — the user's notes are theirs to
/// take out, in a plain-text format any editor can read.
enum MeetingMarkdownExport {
    /// Builds the full `.md` document for one meeting.
    /// `tags` are optional label names (rendered as Obsidian hashtag-style tags).
    static func render(
        meeting: Meeting,
        transcript: [TranscriptRecord],
        tags: [String] = [],
        actionItems: [ActionItem] = []
    ) -> String {
        var out = frontmatter(meeting: meeting, tags: tags)
        out += "\n"

        let title = (meeting.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        out += "# \(title.isEmpty ? "Untitled meeting" : title)\n"

        let summary = meeting.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            out += "\n## Summary\n\n\(summary)\n"
        }

        // Action items as Obsidian-friendly task list items (`- [ ]` / `- [x]`),
        // in recap order. They live in their own table now, not the summary
        // markdown, so a local export re-attaches them for data ownership.
        if !actionItems.isEmpty {
            out += "\n## Action items\n\n"
            out += actionItems
                .map { taskLine(for: $0, spokenAt: meeting.startedAt) }
                .joined(separator: "\n")
            out += "\n"
        }

        if !transcript.isEmpty {
            out += "\n## Transcript\n\n"
            out += transcript
                .map { line(for: $0, meetingStart: meeting.startedAt) }
                .joined(separator: "\n")
            out += "\n"
        }

        return out
    }

    /// A filesystem-safe `<name>.md` filename derived from the title (falling
    /// back to the date). Mirrors anarlog's sanitiser: strip path-hostile
    /// characters, collapse runs of `_`, trim, cap length.
    static func fileName(for meeting: Meeting) -> String {
        let base = (meeting.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = base.isEmpty ? Self.fileDateFormatter.string(from: meeting.startedAt) : base
        return sanitize(raw) + ".md"
    }

    // MARK: - Frontmatter

    private static func frontmatter(meeting: Meeting, tags: [String]) -> String {
        var lines = ["---"]
        if let title = meeting.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            lines.append("title: \(yamlString(title))")
        }
        lines.append("date: \(iso.string(from: meeting.startedAt))")
        lines.append("ended: \(iso.string(from: meeting.endedAt))")
        lines.append("duration: \(durationLabel(from: meeting.startedAt, to: meeting.endedAt))")
        lines.append("language: \(meeting.language)")
        lines.append("kind: \(meeting.kind.rawValue)")
        lines.append("source: Nod")

        let cleanTags = tags
            .map { sanitizeTag($0) }
            .filter { !$0.isEmpty }
        if !cleanTags.isEmpty {
            lines.append("tags:")
            for tag in cleanTags {
                lines.append("  - \(tag)")
            }
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Body helpers

    private static func line(for record: TranscriptRecord, meetingStart: Date) -> String {
        let stamp = offsetLabel(from: meetingStart, to: record.ts)
        return "[\(stamp)] **\(record.displayLabel())**: \(record.text)"
    }

    /// One action item as a Markdown task list line. The deadline is resolved
    /// against the meeting date first: "end of week" only means something next
    /// to the day it was said, and an exported file is read long after that.
    private static func taskLine(for item: ActionItem, spokenAt: Date) -> String {
        let box = item.done ? "[x]" : "[ ]"
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let deadline = item.deadline?.trimmingCharacters(in: .whitespacesAndNewlines), !deadline.isEmpty else {
            return "- \(box) \(text)"
        }
        return "- \(box) \(text) (\(ActionItemDeadline.exportLabel(phrase: deadline, spokenAt: spokenAt)))"
    }

    /// `[MM:SS]` (or `[H:MM:SS]` past an hour) offset of a transcript line from
    /// the meeting start — more useful in an exported file than a wall-clock time.
    static func offsetLabel(from start: Date, to point: Date) -> String {
        let total = max(0, Int(point.timeIntervalSince(start)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    static func durationLabel(from start: Date, to end: Date) -> String {
        let minutes = max(0, Int(end.timeIntervalSince(start))) / 60
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    // MARK: - Sanitisers

    /// Double-quote a YAML scalar and escape what would break the quoting.
    private static func yamlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func sanitizeTag(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "#", with: "")
    }

    private static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        var cleaned = String(String.UnicodeScalarView(
            name.unicodeScalars.map { invalid.contains($0) ? "_" : $0 }
        ))
        while cleaned.contains("__") {
            cleaned = cleaned.replacingOccurrences(of: "__", with: "_")
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_ ."))
        if cleaned.isEmpty { cleaned = "untitled" }
        return String(cleaned.prefix(100))
    }

    private static let iso = ISO8601DateFormatter()

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return formatter
    }()
}
