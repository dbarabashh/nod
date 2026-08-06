import SwiftUI

/// The tools the demo shows Nod reaching into.
///
/// Their real vector marks ship in the asset catalog as `Brand<name>` — the
/// design system's SF-Symbols-only rule governs *our* iconography, and a
/// third-party brand identity is the one thing it cannot express. A viewer
/// watching the landing video has to recognise Slack and Notion instantly, and
/// an approximation reads as a knock-off at exactly the moment the point is
/// "this connects to the tools you already use".
enum DemoTool: String, Equatable {
    case slack
    case jira
    case notion
    case calendar
    case gmail
    case github
    case crm
    /// Support desk — the conversations an insight is counted from. No single
    /// vendor, so this one keeps a symbol.
    case support

    var displayName: String {
        switch self {
        case .slack: "Slack"
        case .jira: "Jira"
        case .notion: "Notion"
        case .calendar: "Calendar"
        case .gmail: "Gmail"
        case .github: "GitHub"
        case .crm: "Salesforce"
        case .support: "Support"
        }
    }

    /// The asset name, or nil for the one tool with no vendor behind it.
    var assetName: String? {
        switch self {
        case .slack: "Brandslack"
        case .jira: "Brandjira"
        case .notion: "Brandnotion"
        case .calendar: "Brandgooglecalendar"
        case .gmail: "Brandgmail"
        case .github: "Brandgithub"
        case .crm: "Brandsalesforce"
        case .support: nil
        }
    }

    /// Marks that are black-on-transparent need a light plate behind them or
    /// they vanish into the notch.
    var needsLightPlate: Bool {
        switch self {
        case .notion, .github: true
        default: false
        }
    }
}

/// A tool's mark, sized to sit inline with a line of text.
struct DemoToolIcon: View {
    let tool: DemoTool
    var size: CGFloat = 18

    var body: some View {
        if let assetName = tool.assetName {
            Image(assetName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(tool.needsLightPlate ? size * 0.16 : 0)
                .frame(width: size, height: size)
                .background(plate)
        } else {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .fill(Color(red: 0.20, green: 0.55, blue: 0.45))
                )
        }
    }

    @ViewBuilder
    private var plate: some View {
        if tool.needsLightPlate {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(.white)
        }
    }
}
