import Foundation

/// A listener can fail before binding (and be replaced), or after becoming live.
/// Cancellation of a failed attempt is not a second failure of the live server.
final class TransferListenerLifecycle: @unchecked Sendable {
    enum Failure { case startup, listening, ignored }
    private enum Phase { case starting, listening, ended }
    private let lock = NSLock()
    private var phase = Phase.starting

    func becomeReady() -> Bool {
        lock.withLock {
            guard phase == .starting else { return false }
            phase = .listening
            return true
        }
    }

    func end(startupOnly: Bool = false) -> Failure {
        lock.withLock {
            switch phase {
            case .starting: phase = .ended; return .startup
            case .listening where !startupOnly: phase = .ended; return .listening
            case .listening, .ended: return .ignored
            }
        }
    }
}
