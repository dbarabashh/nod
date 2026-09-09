import SwiftUI

extension View {
    /// 30×30 surface tile with a hairline border — the header icon-button
    /// chrome shared by the session detail and the action-items checklist.
    func iconButtonChrome() -> some View {
        frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                    .fill(Theme.Palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                            .stroke(Theme.Palette.border, lineWidth: 0.5)
                    )
            )
    }
}
