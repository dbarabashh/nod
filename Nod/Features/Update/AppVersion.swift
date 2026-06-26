import Foundation

/// The running client's version, read once from the bundle. `build` is the
/// monotonic integer (`CFBundleVersion`) the update gate compares against the
/// server `minimum_build`; `version` is the marketing string shown to users.
enum AppVersion {
    static let version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    static let build: Int = .init(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0

    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()
}
