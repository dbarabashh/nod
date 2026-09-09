import AppKit
import Foundation

/// The email a person sends from Settings when something is wrong or missing.
///
/// Built as a `mailto:` rather than sent by the app: the person sees every
/// word before it leaves, including the machine facts appended under the
/// signature line, and nothing goes anywhere unless they press Send. The
/// facts are the ones a report is useless without — which build, which macOS,
/// which Mac — and are read here so the reader never has to ask for them.
struct SupportReport: Equatable {
    enum Kind: Equatable {
        case feature
        case bug

        var subject: String {
            switch self {
            case .feature: "Nod feature request"
            case .bug: "Nod bug report"
            }
        }

        var prompt: String {
            switch self {
            case .feature: "<tell us what Nod should do>"
            case .bug: "<tell us what happened, and what you expected>"
            }
        }
    }

    struct Environment: Equatable {
        var appVersion: String
        var build: Int
        var channel: String?
        var osVersion: String
        var model: String
        var chip: String
        var architecture: String
        var screens: Int
        var appearance: String

        @MainActor
        static func current() -> Environment {
            Environment(
                appVersion: AppVersion.version,
                build: AppVersion.build,
                channel: SettingsView.buildChannel,
                osVersion: AppVersion.osVersion,
                model: sysctlString("hw.model") ?? "unknown",
                chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
                architecture: architecture,
                screens: NSScreen.screens.count,
                appearance: NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
            )
        }

        private static var architecture: String {
            #if arch(arm64)
                "arm64"
            #else
                "x86_64"
            #endif
        }

        private static func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static let address = "dmytro@hellonod.app"

    let kind: Kind
    let environment: Environment
    let triggeredFrom: String
    let reportID: String

    init(kind: Kind, environment: Environment, triggeredFrom: String, reportID: String = "nod-\(UUID().uuidString.lowercased())") {
        self.kind = kind
        self.environment = environment
        self.triggeredFrom = triggeredFrom
        self.reportID = reportID
    }

    var body: String {
        let channel = environment.channel.map { "\($0.lowercased()) " } ?? "release "
        return """
        Hey Dmytro,

        \(kind.prompt)

        --
        App: Nod \(environment.appVersion) (\(environment.build))
        Build: \(channel)\(environment.architecture)
        macOS: \(environment.osVersion)
        Mac: \(environment.model), \(environment.chip)
        Screens: \(environment.screens)
        Appearance: \(environment.appearance)
        Triggered from: \(triggeredFrom)
        Report ID: \(reportID)
        """
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.address
        components.queryItems = [
            URLQueryItem(name: "subject", value: kind.subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }
}
