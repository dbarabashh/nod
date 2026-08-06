import SwiftUI

/// Renders whichever `DemoStage` the director is on.
///
/// Every card here is built from the same three pieces — a titled head, a list
/// of sourced rows, a row of actions — so the eye learns the layout once in the
/// first eight seconds and reads the rest without effort.
struct DemoStageView: View {
    let stage: DemoStage
    @ObservedObject var director: DemoDirector
    let geometry: NotchGeometry

    var body: some View {
        switch stage {
        case let .listening(label):
            DemoRestingBar(label: label, director: director, geometry: geometry)
        case let .transcript(line):
            DemoSpokenLine(line: line)
        case let .searching(label):
            DemoSearchingLine(label: label)
        case let .acknowledgement(line):
            DemoAcknowledgement(line: line)
        case .ended:
            DemoEndedLine()
        case let .context(context):
            DemoContextCard(context: context)
        case let .insight(insight):
            DemoInsightCard(insight: insight)
        case let .workflow(workflow):
            DemoWorkflowCard(workflow: workflow)
        case let .workflowResult(result):
            DemoWorkflowResultCard(result: result)
        case let .brief(brief):
            DemoBriefCard(brief: brief)
        case let .summary(summary):
            DemoSummaryCard(summary: summary)
        }
    }
}

// MARK: - Resting

/// The state the demo returns to between cards: a waveform, what Nod is doing,
/// and the meeting clock — laid out around the hardware cut-out.
private struct DemoRestingBar: View {
    let label: String
    @ObservedObject var director: DemoDirector
    let geometry: NotchGeometry

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                DemoWaveform(level: director.level)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if geometry.hasCutout {
                Color.clear.frame(width: geometry.cutoutWidth)
            }

            Text(DemoClock.string(director.elapsed))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.Palette.ink)
                .monospacedDigit()
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, geometry.flare + 12)
    }
}

enum DemoClock {
    static func string(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// A scripted waveform. Taller in the middle and driven by one shared level, so
/// it moves in phrases the way speech does.
struct DemoWaveform: View {
    let level: Float
    var barWidth: CGFloat = 2
    var span: CGFloat = 10

    private static let weights: [CGFloat] = [0.42, 0.72, 1.0, 0.84, 0.56, 0.3]
    private static let floorHeight: CGFloat = 3

    var body: some View {
        let eased = pow(CGFloat(min(1, max(0, level))), 0.55)

        return HStack(spacing: barWidth) {
            ForEach(Array(Self.weights.enumerated()), id: \.offset) { index, weight in
                Capsule()
                    .fill(Theme.Palette.brand)
                    .frame(
                        width: barWidth,
                        height: Self.floorHeight + span * weight * phase(eased, index)
                    )
            }
        }
        .animation(.easeOut(duration: 0.16), value: level)
    }

    /// Offsets each bar slightly so the row ripples rather than pumping as one
    /// block — the difference between "audio" and "loading indicator".
    private func phase(_ eased: CGFloat, _ index: Int) -> CGFloat {
        let offset = CGFloat(index) * 0.18
        return max(0.12, min(1, eased * (0.78 + 0.32 * sin(Double(eased) * 6 + Double(offset)))))
    }
}

// MARK: - Lines

/// A sentence from the room. Quoted, muted, and gone in a couple of seconds —
/// it is context for what Nod does next, never a transcript panel.
private struct DemoSpokenLine: View {
    let line: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Palette.muted)
            Text(line)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Theme.Palette.graphite)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Nod looking something up, with the shimmer that says it is working.
private struct DemoSearchingLine: View {
    let label: String
    @State private var sweep = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.brand)
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Palette.ink)
                .opacity(sweep ? 1 : 0.55)
            Spacer(minLength: 0)
        }
        .onAppear { sweep = true }
        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: sweep)
    }
}

private struct DemoAcknowledgement: View {
    let line: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.brand)
            Text(line)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 0)
        }
    }
}

private struct DemoEndedLine: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.muted)
            Text("Meeting ended")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Shared card pieces

/// A card's opening line: an accent glyph and the one thing the card is saying.
private struct DemoCardHead: View {
    let systemImage: String
    let title: String
    var tint: Color = Theme.Palette.brand

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 0)
        }
    }
}

/// The compact secondary buttons a card offers. Never the primary action of the
/// app — these are "look at what I did", not "do it".
private struct DemoCardActions: View {
    let actions: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(actions, id: \.self) { action in
                Text(action)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous).fill(Theme.Palette.surfaceStrong)
                    )
            }
            Spacer(minLength: 0)
        }
    }
}

/// One line of evidence or attachment: a real tool mark and what it is.
private struct DemoEvidenceRow: View {
    let evidence: DemoEvidence

    var body: some View {
        HStack(spacing: 8) {
            DemoToolIcon(tool: evidence.tool, size: 15)
            Text(evidence.label)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(Theme.Palette.graphite)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Context

private struct DemoContextCard: View {
    let context: DemoContext

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            DemoCardHead(systemImage: "link", title: context.lead)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(context.sources) { source in
                    HStack(alignment: .top, spacing: 9) {
                        DemoToolIcon(tool: source.tool, size: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(source.reference)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Theme.Palette.ink)
                                if let status = source.status {
                                    DemoStatusChip(text: status)
                                }
                            }
                            Text(source.detail)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(Theme.Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            DemoCardActions(actions: context.actions)
        }
    }
}

private struct DemoStatusChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(Theme.Palette.brand)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous).fill(Theme.Palette.brand.opacity(0.16))
            )
    }
}

// MARK: - Insight

/// The demo's strongest beat. Everything is staggered in — title, explanation,
/// evidence, quote — so the viewer's eye is led through the argument rather
/// than handed a finished block.
private struct DemoInsightCard: View {
    let insight: DemoInsight
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            DemoCardHead(systemImage: "sparkles", title: insight.title)
                .reveal(revealed, order: 0)

            Text(insight.explanation)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.graphite)
                .fixedSize(horizontal: false, vertical: true)
                .reveal(revealed, order: 1)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(insight.evidence.enumerated()), id: \.element.id) { index, evidence in
                    DemoEvidenceRow(evidence: evidence)
                        .reveal(revealed, order: 2 + index)
                }
            }

            DemoQuote(text: insight.quote)
                .reveal(revealed, order: 2 + insight.evidence.count)

            DemoCardActions(actions: [insight.action])
                .reveal(revealed, order: 3 + insight.evidence.count)
        }
        .onAppear { revealed = true }
    }
}

private struct DemoQuote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(Theme.Palette.brand.opacity(0.55))
                .frame(width: 2)
            Text(text)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(Theme.Palette.ink.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private extension View {
    /// Staggered entrance — each element a beat behind the last.
    func reveal(_ shown: Bool, order: Int) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
            .animation(
                .spring(response: 0.42, dampingFraction: 0.82)
                    .delay(0.06 * Double(order)),
                value: shown
            )
    }
}

// MARK: - Workflow

private struct DemoWorkflowCard: View {
    let workflow: DemoWorkflow

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            DemoCardHead(systemImage: "wand.and.stars", title: workflow.title)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(workflow.steps) { step in
                    DemoWorkflowRow(step: step)
                }
            }
        }
    }
}

/// One integration, loading or done. Compact on purpose — three of these are on
/// screen at once and the card must stay readable at a glance.
private struct DemoWorkflowRow: View {
    let step: DemoWorkflowStep

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            DemoToolIcon(tool: step.tool, size: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(step.currentLabel)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(step.isDone ? Theme.Palette.ink : Theme.Palette.muted)
                        .id(step.currentLabel)
                        .transition(.opacity)

                    if step.isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.Palette.success)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        DemoSpinner()
                    }
                }

                if step.isDone {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(step.details, id: \.self) { detail in
                            Text(detail)
                                .font(.system(size: 10.5, weight: .regular))
                                .foregroundStyle(Theme.Palette.muted)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: step.isDone)
        .animation(.easeInOut(duration: 0.22), value: step.currentLabel)
    }
}

private struct DemoSpinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Theme.Palette.muted.opacity(0.8), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear { spinning = true }
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
    }
}

// MARK: - Workflow result

private struct DemoWorkflowResultCard: View {
    let result: DemoWorkflowResult

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            DemoCardHead(systemImage: "checkmark.seal.fill", title: result.title, tint: Theme.Palette.success)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(result.outcomes) { outcome in
                    HStack(spacing: 9) {
                        DemoToolIcon(tool: outcome.tool, size: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(outcome.headline)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Theme.Palette.ink)
                            Text(outcome.detail)
                                .font(.system(size: 10.5, weight: .regular))
                                .foregroundStyle(Theme.Palette.muted)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            DemoTickList(items: result.confirmations)
            DemoCardActions(actions: result.actions)
        }
    }
}

/// Short confirmations, two to a row — a column of nine ticks would be the
/// "long technical checklist" the demo is meant to avoid.
private struct DemoTickList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.Palette.success)
                    Text(item)
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(Theme.Palette.muted)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Brief

private struct DemoBriefCard: View {
    let brief: DemoBrief
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            DemoCardHead(systemImage: "doc.text.magnifyingglass", title: brief.title)
                .reveal(revealed, order: 0)

            Text(brief.explanation)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.graphite)
                .fixedSize(horizontal: false, vertical: true)
                .reveal(revealed, order: 1)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(brief.attachments.enumerated()), id: \.element.id) { index, attachment in
                    DemoEvidenceRow(evidence: attachment)
                        .reveal(revealed, order: 2 + index)
                }
            }

            DemoCardActions(actions: [brief.action])
                .reveal(revealed, order: 2 + brief.attachments.count)
        }
        .onAppear { revealed = true }
    }
}
