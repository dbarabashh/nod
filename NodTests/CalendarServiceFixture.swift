import XCTest
@testable import Nod

/// A `CalendarService` on its own defaults suite, so one test's switch cannot
/// reach another's. Shared because both calendar test files want the same
/// three lines and had started to keep their own copy.
@MainActor
enum CalendarServiceFixture {
    static func service(switchedOn: Bool) throws -> CalendarService {
        let suite = "nod.tests.calendar.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(switchedOn, forKey: CalendarService.defaultsKey)
        return CalendarService(defaults: defaults)
    }
}
