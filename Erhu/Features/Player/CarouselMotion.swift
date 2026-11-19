import Observation
import SwiftUI

/// One finite animation for position and layout. Rendering only samples this state; it never
/// dispatches a state change back into the animation that is currently being rendered.
@MainActor
@Observable
final class CarouselMotion {
    private(set) var focus: CGFloat = 0
    private(set) var stack: CGFloat = 0
    private(set) var frontOrdinal = 0
    private(set) var moving = false
    @ObservationIgnored let meter = CarouselPresentationMeter()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var settlement: Task<Void, Never>?
    @ObservationIgnored private var origin: CarouselPresentationSample?

    static let duration = CarouselSettlementTiming.standardDuration

    func hold() {
        settlement?.cancel(); settlement = nil
        generation = UUID()
        moving = true
    }

    func drag(translation: CGFloat, page: CGFloat, center: Int, canPrevious: Bool, canNext: Bool) {
        guard translation.isFinite, page.isFinite, page > 0 else { return }
        if origin == nil {
            hold()
            origin = meter.sample(fallback: CarouselPresentationSample(focus: focus, stack: stack))
        }
        guard let origin else { return }
        let distance = -translation / page
        var instant = Transaction(); instant.disablesAnimations = true
        withTransaction(instant) {
            focus = CarouselDragLimit.focus(origin.focus + distance, center: center, canPrevious: canPrevious, canNext: canNext)
            // A depth-deck swipe remains a depth-deck swipe; only the layout button spreads it.
            stack = origin.stack
            // Retain the spread layout's order anchor. The depth renderer exchanges order
            // only after its rotating card edges have separated, without replacing native hosts.
        }
    }

    func settle(center: Int, stacked: Bool, reduceMotion: Bool, velocity: CGFloat? = nil, completion: @escaping () -> Void = {}) {
        origin = nil
        settlement?.cancel()
        let token = UUID(); generation = token
        let targetStack: CGFloat = stacked ? 1 : 0
        let timing = CarouselSettlementTiming(delta: CGFloat(center) - focus, layoutDelta: targetStack - stack,
                                             velocity: velocity, reduceMotion: reduceMotion, depth: stacked)
        // A track change settles with a critically damped spring (about 0.3 s from rest) that
        // keeps a running motion's velocity when the next skip retargets it.
        let moves = abs(CGFloat(center) - focus) > 0.001 && !reduceMotion
        let animation = moves ? CarouselSettlementTiming.trackSpring(delta: CGFloat(center) - focus, velocity: velocity) : timing.animation
        let duration = moves ? CarouselSettlementTiming.trackCleanupDuration : timing.duration
        withAnimation(animation) {
            moving = true
            focus = CGFloat(center)
            stack = targetStack
        }
        // Cleanup is bounded independently of SwiftUI's render/visibility completion callbacks.
        // Native interpolation still draws every frame; this task only releases interaction state.
        settlement = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.settlement = nil
            self.meter.record(self.focus, stack: self.stack)
            self.frontOrdinal = center
            self.moving = false
            completion()
        }
    }

    func snap(center: Int, stacked: Bool) {
        cancel()
        var instant = Transaction(); instant.disablesAnimations = true
        withTransaction(instant) {
            focus = CGFloat(center)
            stack = stacked ? 1 : 0
            frontOrdinal = center
            moving = false
        }
        meter.record(focus, stack: stack)
    }

    func endGesture() { origin = nil }
    func cancel() { settlement?.cancel(); settlement = nil; generation = UUID(); origin = nil; moving = false }
}

/// Buttons traverse a whole page. A released finger only has the remaining travel to cover,
/// and the initial curve slope follows its measured velocity instead of starting a new fling.
struct CarouselSettlementTiming {
    static let standardDuration: TimeInterval = 0.28
    let duration: TimeInterval
    let firstX: Double
    let firstY: Double
    let secondX: Double

    init(delta: CGFloat, layoutDelta: CGFloat = 0, velocity: CGFloat?, reduceMotion: Bool, depth: Bool = false) {
        let fullDuration: TimeInterval = depth ? 0.40 : Self.standardDuration
        guard let velocity, !reduceMotion else {
            duration = reduceMotion ? 0.16 : fullDuration
            firstX = 0.22; firstY = 0.8; secondX = 0.25
            return
        }
        let distance = Double(abs(delta))
        let travel = min(max(distance, Double(abs(layoutDelta))), 1)
        let speed = velocity.isFinite ? max(Double(velocity) * (delta < 0 ? -1 : 1), 0) : 0
        var time = (fullDuration * sqrt(travel)).clamped(0.10, fullDuration)
        if distance > 0.001, speed > 0, abs(layoutDelta) < 0.01 {
            time = min(time, 2 * distance / speed).clamped(0.10, fullDuration)
        }
        duration = time
        firstX = 0.25
        firstY = distance > 0.001 ? (speed * time / distance * firstX).clamped(0, 0.9) : 0
        secondX = 0.6
    }

    var animation: Animation { .timingCurve(firstX, firstY, secondX, 1, duration: duration) }

    /// Stiffness of the track-change spring (critically damped, unit mass).
    static let trackStiffness: Double = 400
    /// When a track change releases interaction state (the spring is within 2% of rest).
    static let trackCleanupDuration: TimeInterval = 0.3
    /// How long after a skip the background and colours wait before changing, so they don't
    /// repaint while the cards are still moving.
    static let trackSettleDuration: TimeInterval = 0.5

    /// The track-change spring. [velocity] is the finger's speed in pages per second; only motion
    /// towards the destination is kept, capped at sqrt(stiffness) x distance so the card never
    /// overshoots, and at four pages a second against batched-input spikes.
    static func trackSpring(delta: CGFloat, velocity: CGFloat?) -> Animation {
        let distance = Double(abs(delta))
        let toward = velocity.map { Double($0) * (delta < 0 ? -1 : 1) } ?? 0
        let limit = min(distance * trackStiffness.squareRoot(), 4)
        let speed = toward.isFinite ? toward.clamped(0, limit) : 0
        return .interpolatingSpring(mass: 1, stiffness: trackStiffness, damping: 2 * trackStiffness.squareRoot(),
                                    initialVelocity: distance > 0.001 ? speed / distance : 0)
    }
}

enum CarouselSwipeIntent {
    /// The gesture's own travel determines direction, even when it interrupts a previous slide.
    static func direction(translation: CGFloat, predicted: CGFloat, page: CGFloat) -> Int {
        guard translation.isFinite, predicted.isFinite, page.isFinite, page > 0 else { return 0 }
        let projected = predicted - translation
        if abs(projected) > 180 { return projected < 0 ? 1 : -1 }
        guard abs(translation) > page * 0.25 else { return 0 }
        return translation < 0 ? 1 : -1
    }
}
