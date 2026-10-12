import AppKit

/// Apple-style spring described by response and damping ratio instead of mass/stiffness.
struct Spring: Sendable {
    /// Seconds to approach the target. Lower is snappier.
    var response: Double = 0.35
    /// 1.0 settles without overshoot. Below 1.0 bounces.
    var dampingRatio: Double = 1.0

    struct State: Sendable {
        var value: Double
        var velocity: Double = 0
    }

    func advance(_ state: inout State, toward target: Double, dt: Double) {
        let omega = 2 * Double.pi / response
        let acceleration = -omega * omega * (state.value - target) - 2 * dampingRatio * omega * state.velocity
        state.velocity += acceleration * dt
        state.value += state.velocity * dt
    }

    func isSettled(_ state: State, target: Double, tolerance: Double = 0.5) -> Bool {
        abs(state.value - target) < tolerance && abs(state.velocity) < 4
    }
}

/// Drives a vector of values toward targets with a spring, one step per display refresh.
/// Re-targeting mid-flight keeps the current value and velocity, so motion is interruptible.
final class SpringAnimator {
    var spring = Spring()
    var onFrame: ([Double]) -> Void = { _ in }
    var onSettle: () -> Void = {}

    private(set) var states: [Spring.State] = []
    private var targets: [Double] = []
    private var displayLink: CADisplayLink?
    private weak var view: NSView?

    init(view: NSView) {
        self.view = view
    }

    var isAnimating: Bool { displayLink != nil }

    /// Starts or re-targets the animation. `current` seeds the values only when not already animating.
    func animate(from current: [Double], to targets: [Double]) {
        if !isAnimating || states.count != current.count {
            states = current.map { Spring.State(value: $0) }
        }
        self.targets = targets
        guard displayLink == nil, let view else { return }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let frame = min(max(link.targetTimestamp - link.timestamp, 1.0 / 240), 1.0 / 30)
        // Sub-step for numerical stability at low refresh rates.
        let steps = 4
        let dt = frame / Double(steps)
        for _ in 0..<steps {
            for i in states.indices {
                spring.advance(&states[i], toward: targets[i], dt: dt)
            }
        }
        let settled = states.indices.allSatisfy { spring.isSettled(states[$0], target: targets[$0]) }
        if settled {
            for i in states.indices {
                states[i] = Spring.State(value: targets[i])
            }
            cancel()
            onFrame(targets)
            onSettle()
        } else {
            onFrame(states.map(\.value))
        }
    }
}
