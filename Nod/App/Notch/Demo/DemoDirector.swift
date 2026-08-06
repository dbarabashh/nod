import Combine
import Foundation

/// Plays a `DemoScenario` against the clock and publishes the stage the notch
/// should be showing.
///
/// Deterministic by construction: one task walks the beats, sleeping the gap
/// between each, so a recording made twice is the same recording twice. Nothing
/// here touches audio, the network, or the real `MeetingSession`.
@MainActor
final class DemoDirector: ObservableObject {
    @Published private(set) var stage: DemoStage?
    /// The meeting clock the demo shows. Starts mid-meeting so the recording
    /// opens on a conversation already in progress.
    @Published private(set) var elapsed: Int = 0
    @Published private(set) var isRunning = false

    private(set) var scenario: DemoScenario = .productEngineering

    private var playback: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    /// The workflow currently on screen, kept so `advance` and `complete` beats
    /// can mutate one row without the script restating the other two.
    private var workflow: DemoWorkflow?

    /// A scripted level for the waveform. Real capture isn't running, and a flat
    /// meter through the whole recording is the one thing that would give the
    /// demo away instantly.
    @Published private(set) var level: Float = 0

    func start(_ scenario: DemoScenario, pace: Double = 1.0) {
        stop()
        self.scenario = scenario
        elapsed = scenario.startingElapsed
        isRunning = true
        runClock()
        runBeats(scenario.beats, pace: max(0.1, pace))
    }

    func stop() {
        playback?.cancel()
        playback = nil
        clock?.cancel()
        clock = nil
        workflow = nil
        stage = nil
        level = 0
        isRunning = false
    }

    // MARK: - Playback

    private func runBeats(_ beats: [DemoBeat], pace: Double) {
        playback = Task { @MainActor [weak self] in
            var previous: TimeInterval = 0
            for beat in beats {
                let gap = (beat.at - previous) * pace
                if gap > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
                }
                guard let self, !Task.isCancelled else { return }
                previous = beat.at
                perform(beat.action)
            }
        }
    }

    private func perform(_ action: DemoBeat.Action) {
        switch action {
        case let .stage(stage):
            if case let .workflow(started) = stage {
                workflow = started
            }
            self.stage = stage

        case let .advance(tool):
            mutateWorkflow(tool) { step in
                guard let index = step.progressIndex else { return }
                step.progressIndex = min(index + 1, step.progress.count - 1)
            }

        case let .complete(tool):
            mutateWorkflow(tool) { step in
                step.progressIndex = nil
            }
        }
    }

    private func mutateWorkflow(_ tool: DemoTool, _ change: (inout DemoWorkflowStep) -> Void) {
        guard var workflow, let index = workflow.steps.firstIndex(where: { $0.tool == tool }) else {
            return
        }
        change(&workflow.steps[index])
        // The revision is what gives the row a new identity, so SwiftUI animates
        // the change instead of swapping the label in place.
        workflow.revision += 1
        self.workflow = workflow
        stage = .workflow(workflow)
    }

    // MARK: - Clock and waveform

    private func runClock() {
        clock = Task { @MainActor [weak self] in
            // Fast enough to move the waveform, and every tenth tick advances
            // the second — one task rather than two.
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled else { return }
                ticks += 1
                level = Self.scriptedLevel(at: ticks)
                if ticks.isMultiple(of: 10), !isEnded {
                    elapsed += 1
                }
            }
        }
    }

    private var isEnded: Bool {
        if case .ended = stage { return true }
        if case .summary = stage { return true }
        return false
    }

    /// A speech-shaped level: a slow envelope with a faster tremor on top, so
    /// the meter breathes in phrases rather than pulsing like a metronome.
    private nonisolated static func scriptedLevel(at tick: Int) -> Float {
        let seconds = Double(tick) / 10
        let phrase = (sin(seconds * 1.7) + 1) / 2
        let tremor = (sin(seconds * 11.3) + 1) / 2
        let shaped = 0.18 + 0.55 * phrase * (0.65 + 0.35 * tremor)
        return Float(min(1, max(0, shaped)))
    }
}
