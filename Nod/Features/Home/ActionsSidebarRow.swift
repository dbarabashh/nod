import SwiftUI

/// The rail's route into the checklist, carrying how much is open.
///
/// The count used to belong to a row of its own — "34 things need attention" —
/// pointing at a screen that previewed the very list this row leads to. One
/// destination does not need two doors, so the number moved onto the door that
/// was already there.
///
/// Takes its stores from the environment rather than being handed a count, for
/// the same reason `AmbientContextSidebarRow` does: ticking a task off would
/// otherwise invalidate the whole sidebar to redraw one row.
struct ActionsSidebarRow: View {
    let isSelected: Bool
    let onSelect: () -> Void

    @EnvironmentObject private var actionItemStore: ActionItemStore
    @EnvironmentObject private var entitlements: EntitlementService
    @State private var openCount = 0

    var body: some View {
        SidebarNavRow(
            title: "Actions",
            icon: "nc-check",
            isSelected: isSelected,
            badge: openCount,
            action: onSelect
        )
        .help("Everything still open across your sessions")
        .onChange(of: actionItemStore.revision) { _ in recount() }
        .onAppear(perform: recount)
    }

    private func recount() {
        openCount = entitlements.mayUse(.actionItems) ? actionItemStore.openItems.count : 0
    }
}
