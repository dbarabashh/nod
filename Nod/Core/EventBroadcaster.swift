/// Zero or more observers of one event, called in the order they subscribed.
///
/// Where a single `var onX: ((Payload) -> Void)?` risks a second assignment
/// silently discarding the first — nothing marks that as a mistake, the
/// property just holds whichever closure was set last — every call to
/// `subscribe(_:)` here adds an observer instead of replacing one.
///
/// `@MainActor`, not a generic actor-agnostic type: every current owner is
/// itself `@MainActor`, and an unsynchronized array of closures reached from
/// more than one actor is exactly the unguarded mutable state the
/// concurrency rules exist to rule out.
@MainActor
final class EventBroadcaster<Payload> {
    private var handlers: [(Payload) -> Void] = []

    func subscribe(_ handler: @escaping (Payload) -> Void) {
        handlers.append(handler)
    }

    func fire(_ payload: Payload) {
        for handler in handlers {
            handler(payload)
        }
    }
}

extension EventBroadcaster where Payload == Void {
    func fire() {
        fire(())
    }
}
