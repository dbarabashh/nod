import Foundation

/// Where Nod keeps what it writes outside the database: the meeting write-ahead
/// log, the diarization model cache, debug audio dumps, and the one preference
/// file that has to survive a `defaults` reset.
///
/// One place because sandboxing the app would move all of them at once, and
/// because the resolution carries a fallback worth stating: where Application
/// Support can't be created we use the temp directory rather than crash. That
/// is right for the caches and wrong for the WAL, whose whole job is surviving
/// a crash — `MeetingOutbox` is where that trade-off has to be read.
enum AppSupport {
    /// Resolved and created once per process, not per call: the ambient-capture
    /// check reads a path off this every few seconds, and a getter that touches
    /// the filesystem has no upper bound when the disk stalls.
    static let root: URL = {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())

        let url = base.appendingPathComponent("Nod", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// `~/Library/Application Support/Nod/<component>`, created if missing.
    /// Creation is the point — call this where you are about to write.
    static func directory(_ component: String) -> URL {
        let url = root.appendingPathComponent(component, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
