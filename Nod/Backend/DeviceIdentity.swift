import Foundation
import IOKit

/// Stable per-machine identity used by the single-device lock (the server
/// binds an account to one `id` at a time; see the `user_devices` migration).
///
/// `id` is the hardware `IOPlatformUUID` — constant for the life of the Mac and
/// unchanged by reinstalling Nod, so a reinstall is *not* treated as a new
/// device. If IOKit ever can't supply it we fall back to a UserDefaults UUID so
/// we always send a stable value; the lock degrades to per-install, never off.
enum DeviceIdentity {
    static let id: String = resolveID()

    /// Human-readable machine name, surfaced server-side for a future "your
    /// devices" screen. Not an identity input — never used for the lock.
    /// Resolved once: the name can't change within a session, and this is read
    /// on every proxy call (the transcribe hot path).
    static let name: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

    /// `name` percent-encoded for the `x-device-name` HTTP header — machine
    /// names aren't ASCII-safe, which a header value must be. Cached alongside
    /// `name` so the encoding isn't redone on every request.
    static let encodedName: String? = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics)

    private static let fallbackKey = "device.fallbackID"

    private static func resolveID() -> String {
        if let hardware = hardwareUUID(), !hardware.isEmpty {
            return hardware
        }
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: fallbackKey) {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: fallbackKey)
        Log.auth.error("hardware UUID unavailable — using per-install device id")
        return fresh
    }

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        return property.takeRetainedValue() as? String
    }
}
