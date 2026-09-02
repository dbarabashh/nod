import SwiftUI

struct TitledAction {
    let title: String
    var isEnabled = true
    let action: () -> Void

    init(_ title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
    }
}

/// The bottom band of an app-styled sheet: an optional destructive act on the
/// left, and on the right a quiet Cancel beside the one glass primary. Escape
/// and Return are wired here so every sheet answers the keyboard the same way.
struct SheetFooter: View {
    var delete: TitledAction?
    let cancel: () -> Void
    let primary: TitledAction

    var body: some View {
        HStack(spacing: 10) {
            if let delete {
                Button(delete.title, action: delete.action)
                    .font(.system(size: 12.5))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Palette.danger)
                    .linkCursor()
                    .disabled(!delete.isEnabled)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: cancel)
                .font(.system(size: 12.5))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.muted)
                .keyboardShortcut(.cancelAction)
            Button(action: primary.action) {
                Text(primary.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!primary.isEnabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

#Preview {
    VStack(spacing: 0) {
        SheetFooter(cancel: {}, primary: TitledAction("Create", isEnabled: false) {})
        Divider().overlay(Theme.Palette.border)
        SheetFooter(delete: TitledAction("Delete") {}, cancel: {}, primary: TitledAction("Save") {})
    }
    .frame(width: 380)
    .background(WindowBackdrop())
}
