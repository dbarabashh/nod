import SwiftUI

/// The language list, as menu content.
///
/// Thirty-five languages in one flat menu reach the bottom of the screen, and a
/// list that tall is not read — it is scrolled past. The notch cannot answer
/// that with a scrollable popover the way a normal window would: it is a
/// non-activating borderless panel and `.popover` needs a real key window (see
/// `NotchStates`). So the answer is the one AppKit has always had for a long
/// list — submenus, with nothing on either level long enough to need scrolling.
///
/// What sits above them is what the user's own Mac already asks for. Somebody
/// working between English and Ukrainian opens this menu on exactly those two
/// and never reaches a region at all.
struct LanguageMenu: View {
    let selected: AppLanguage
    let onPick: (AppLanguage) -> Void

    /// The system's own languages, plus the current pick when it isn't one of
    /// them — a menu that doesn't show what is selected reads as broken.
    private var shortcuts: [AppLanguage] {
        let preferred = AppLanguage.systemPreferred()
        return preferred.contains(selected) ? preferred : [selected] + preferred
    }

    var body: some View {
        // A `Section` header, the way `MicrophoneInputPicker` gets one from its
        // `Picker` label: it says what the list sets, which "English" on its
        // own does not.
        Section("Nod language — summaries and answers") {
            ForEach(shortcuts, id: \.self) { language in
                row(language)
            }
        }
        ForEach(AppLanguage.byRegion(), id: \.region) { group in
            Menu(group.region.title) {
                ForEach(group.languages, id: \.self) { language in
                    row(language)
                }
            }
        }
    }

    /// A `Toggle`, not a `Button`: AppKit draws a checked menu item for it, so
    /// the mark saying which of the thirty-five is live comes from the platform
    /// rather than from an icon this app would have to place itself. `Picker`
    /// would draw the same mark, but it renders one flat list and cannot hold
    /// the submenus that are the point.
    private func row(_ language: AppLanguage) -> some View {
        Toggle(language.nativeName, isOn: Binding(
            get: { language == selected },
            set: { isOn in if isOn { onPick(language) } }
        ))
    }
}
