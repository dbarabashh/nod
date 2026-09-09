import Foundation
import Sentry

/// Crash and hang reports, sent to Sentry when the build carries a DSN and
/// the person has not switched them off.
///
/// Kept deliberately narrow, because `privacy.md` § 3.8 promises what the
/// app does not collect and this is the one third-party SDK inside it: no
/// personal data (`sendDefaultPii` stays off, so no IP or username), no
/// network breadcrumbs or spans (a request URL can carry a meeting id), no
/// logs; screenshots and view hierarchies are iOS-only and never offered. What leaves is the stack trace, the app
/// version and channel, macOS version and Mac model. Tracing samples a small
/// share of app launches so a slow start is visible without a report per run.
enum CrashReporting {
    static let defaultsKey = "diagnostics.crashReports"
    /// Set the first time a person answers the question, in onboarding or in
    /// the one-time prompt an existing install shows after updating. Nothing
    /// is sent before that: a report is opted into, never assumed.
    static let askedKey = "diagnostics.asked"
    static let isEnabledByDefault = true

    struct Configuration: Equatable {
        let dsn: String
        let environment: String
        let release: String
    }

    /// nil when the build carries no DSN: Debug never does, and a release
    /// whose setting was left empty reports nothing rather than failing.
    static func configuration(from info: [String: Any]?, version: String, build: Int) -> Configuration? {
        guard let dsn = (info?["NodSentryDSN"] as? String)?.trimmingCharacters(in: .whitespaces), !dsn.isEmpty else {
            return nil
        }
        let environment = (info?["NodSentryEnvironment"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "production"
        return Configuration(dsn: dsn, environment: environment, release: "nod@\(version)+\(build)")
    }

    static func hasBeenAsked(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: askedKey)
    }

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        hasBeenAsked(in: defaults) && currentChoice(in: defaults)
    }

    /// What a switch for the question should start on: the answer given, or
    /// the default while there is none yet.
    static func currentChoice(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? isEnabledByDefault
    }

    /// The answer, wherever it was given. Starts or stops the SDK to match.
    @MainActor
    static func record(enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: askedKey)
        defaults.set(enabled, forKey: defaultsKey)
        if enabled { start() } else { stop() }
    }

    @MainActor
    static func start() {
        guard isEnabled() else {
            Log.ui.info(hasBeenAsked() ? "crash reports off by choice" : "crash reports off until asked")
            return
        }
        guard let configuration = configuration(from: Bundle.main.infoDictionary, version: AppVersion.version, build: AppVersion.build) else {
            Log.ui.info("crash reports off: no DSN in this build")
            return
        }
        SentrySDK.start { options in
            options.dsn = configuration.dsn
            options.environment = configuration.environment
            options.releaseName = configuration.release
            options.sendDefaultPii = false
            options.enableCrashHandler = true
            options.enableAppHangTracking = true
            options.enableNetworkBreadcrumbs = false
            options.enableNetworkTracking = false
            options.enableCaptureFailedRequests = false
            options.enableLogs = false
            options.enableMetrics = false
            options.tracesSampleRate = 0.1
        }
        Log.ui.info("crash reports on env=\(configuration.environment) release=\(configuration.release)")
    }

    /// Stops reporting for the rest of this run; the next launch reads the
    /// preference before starting the SDK at all.
    @MainActor
    static func stop() {
        SentrySDK.close()
    }
}

#if DEBUG || NOD_SANDBOX
    extension CrashReporting {
        /// Forgets the answer, so the welcome step asks again.
        static func resetPersistedChoice(in defaults: UserDefaults = .standard) {
            defaults.removeObject(forKey: askedKey)
            defaults.removeObject(forKey: defaultsKey)
        }
    }
#endif
