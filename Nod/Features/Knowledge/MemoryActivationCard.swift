import SwiftUI

struct MemoryActivationCard: View {
    let surface: ProductAnalytics.Surface
    let onAsk: (String) -> Void

    @EnvironmentObject private var screenContext: ScreenContextService
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var entitlements: EntitlementService
    @EnvironmentObject private var chat: KnowledgeChatStore
    @EnvironmentObject private var analytics: ProductAnalytics
    @EnvironmentObject private var threads: KnowledgeThreadStore
    @State private var ready: Bool?
    @State private var failed = false
    @State private var dismissed = true
    @State private var completed = false
    @State private var loadedUserID: UUID?
    @State private var retryID = 0

    private var stage: MemoryActivation.Stage {
        MemoryActivation.stage(
            eligible: loadedUserID != nil && loadedUserID == profile.profile?.userID
                && entitlements.can(.askAcrossMeetings) && screenContext.isEntitled,
            dismissed: dismissed, completed: completed, enabled: screenContext.isAmbientEnabled,
            needsAccess: screenContext.needsAccessibility, paused: screenContext.pausedUntil != nil,
            ready: ready, failed: failed
        )
    }

    var body: some View {
        Group {
            if stage != .hidden {
                MemoryActivationContent(
                    stage: stage,
                    retentionDays: screenContext.retentionDays,
                    isBusy: chat.isSending,
                    onAction: act,
                    onDismiss: dismiss
                )
                .task(id: stage) {
                    analytics.record(
                        .memoryActivationViewed,
                        properties: .init(surface: surface, outcome: .viewed, detail: .init(rawValue: "memory_\(stage.rawValue)"))
                    )
                }
            }
        }
        .task(id: profile.profile?.userID) {
            ready = nil
            loadedUserID = profile.profile?.userID
            guard let userID = loadedUserID else { return }
            dismissed = TodayNudge.isDismissed(.ambient, for: userID)
            completed = UserDefaults.standard.bool(forKey: MemoryActivation.completionKey(userID))
            guard !dismissed, !completed else { return }
            do {
                let answered = try await threads.hasScreenAnswer(for: userID)
                guard !Task.isCancelled, loadedUserID == userID else { return }
                if answered {
                    completed = true
                    UserDefaults.standard.set(true, forKey: MemoryActivation.completionKey(userID))
                }
            } catch {
                Log.ui.error("memory activation: answer history check failed — \(error.localizedDescription)")
            }
        }
        .task(id: refreshKey) {
            ready = nil
            failed = false
            guard let userID = loadedUserID, stage != .hidden,
                  screenContext.isAmbientEnabled, screenContext.pausedUntil == nil,
                  !screenContext.needsAccessibility else { return }
            while !Task.isCancelled {
                await refresh(userID)
                do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                catch { return }
            }
        }
        .onChange(of: chat.isSending) { sending in
            guard !sending, let userID = loadedUserID else { return }
            completed = UserDefaults.standard.bool(forKey: MemoryActivation.completionKey(userID))
        }
    }

    private var refreshKey: String {
        "\(loadedUserID?.uuidString ?? ""):\(screenContext.isAmbientEnabled):\(screenContext.needsAccessibility):\(screenContext.pausedUntil != nil):\(screenContext.isEntitled):\(entitlements.can(.askAcrossMeetings)):\(dismissed):\(completed):\(screenContext.contextRevision):\(retryID)"
    }

    private func refresh(_ userID: UUID) async {
        do {
            let available = try await screenContext.hasRecentContext(for: userID)
            guard !Task.isCancelled, loadedUserID == userID else { return }
            ready = available
            failed = false
        } catch {
            guard !Task.isCancelled, loadedUserID == userID else { return }
            ready = nil
            failed = true
            Log.screen.error("memory activation: availability check failed — \(error.localizedDescription)")
        }
    }

    private func act() {
        analytics.record(
            .memoryActivationActed,
            properties: .init(surface: surface, outcome: .success, detail: .init(rawValue: "memory_\(stage.rawValue)"))
        )
        switch stage {
        case .off: screenContext.setAmbientEnabled(true)
        case .permission: AccessibilityAccess.openSystemSettings()
        case .paused: screenContext.resume()
        case .ready:
            guard !chat.isSending else { return }
            onAsk(MemoryActivation.question)
        case .failed, .waiting:
            retryID &+= 1
        case .hidden, .checking: break
        }
    }

    private func dismiss() {
        guard let userID = loadedUserID else { return }
        TodayNudge.dismiss(.ambient, for: userID)
        analytics.record(
            .memoryActivationActed,
            properties: .init(surface: surface, outcome: .declined, detail: .init(rawValue: "memory_\(stage.rawValue)"))
        )
        dismissed = true
    }
}

private struct MemoryActivationContent: View {
    let stage: MemoryActivation.Stage
    let retentionDays: Int
    let isBusy: Bool
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).textStyle(Theme.Typography.sectionTitle).foregroundStyle(Theme.Palette.ink)
            Text(detail).textStyle(Theme.Typography.secondary).foregroundStyle(Theme.Palette.graphite)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                GlassPillButton(button, size: .compact, action: onAction)
                    .disabled(stage == .checking || (stage == .ready && isBusy))
                SecondaryPillButton("Not now", action: onDismiss)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard()
    }

    private var title: String {
        switch stage {
        case .off, .hidden: "Pick up where you left off"
        case .permission: "One permission, then your first question"
        case .paused: "Screen memory is paused"
        case .checking: "Checking your screen memory…"
        case .waiting: "Give Nod something to remember"
        case .ready: "Ask about what you've been working on"
        case .failed: "Couldn't check your screen memory"
        }
    }

    private var detail: String {
        switch stage {
        case .off, .hidden:
            "Turn on ambient context to ask about your recent work. Nod stores text from the window you're using for \(retentionDays) days, never images. Excluded apps and sites aren't read. You can pause, switch off or delete captures anytime."
        case .permission:
            "Add Nod under Accessibility in System Settings, then return here. This card will update when access is ready."
        case .paused:
            "Nothing new is being captured. Resume when you're ready to try a question about your work."
        case .checking:
            "Looking for available context from the last 24 hours."
        case .waiting:
            "Open a document or page you want Nod to remember and work there briefly. Return here to ask about it. Excluded apps and sites stay excluded."
        case .ready:
            "Context from the last 24 hours is available. Ask Nod for a summary with sources, then follow up in the chat."
        case .failed:
            "Check your connection and try again. Your capture settings haven't changed."
        }
    }

    private var button: String {
        switch stage {
        case .off, .hidden: "Turn on ambient context"
        case .permission: "Open System Settings"
        case .paused: "Resume"
        case .checking: "Checking…"
        case .waiting: "Check again"
        case .ready: "Summarize my recent work"
        case .failed: "Try again"
        }
    }
}

#Preview {
    MemoryActivationContent(stage: .ready, retentionDays: 14, isBusy: false, onAction: {}, onDismiss: {})
        .padding().frame(width: 440)
}
