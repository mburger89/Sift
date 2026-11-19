import MetalUI

/// What is wrong with the selected connection, and what the user can do about it. Nothing when it is fine.
struct ConnectionBanner: Component {
    let model: AppModel
    let key: ConnectionKey

    var content: some ElementGroup {
        if let session = model.sessions[key], let message = Self.message(for: session.state) {
            HStack(spacing: Pixels(12)) {
                Text(message).font(size: 12)
                    .accessibilityLabel(message)
                    .accessibilityIdentifier("session.banner")
                Spacer()
                if Self.canRetry(session.state) {
                    Button("Reconnect now") { Task { @MainActor in await session.reconnectNow() } }
                        .disabled(!Self.isWaiting(session.state))
                }
                if Self.canRetry(session.state) {
                    Button("Stop trying") { session.stopTrying() }
                }
                if Self.canTryAgain(session.state) {
                    Button("Try again") { Task { @MainActor in await model.open(key) } }
                }
            }
            .padding(inset(12, 8))
            .frame(maxWidth: .infinity)
            .background(.bannerFill)
        }
    }

    static func message(for state: DatabaseSession.State) -> String? {
        switch state {
        case .ready: return nil
        case .connecting: return "Connecting…"
        case .lost(let reason): return "Connection lost: \(reason). Trying again soon."
        case .reconnecting(let attempt): return "Connection lost. Reconnecting (attempt \(attempt))…"
        case .failed(let reason): return reason
        case .stopped: return "Connection closed. Connect again to continue."
        }
    }

    static func canRetry(_ state: DatabaseSession.State) -> Bool {
        switch state {
        case .lost, .reconnecting: return true
        default: return false
        }
    }

    static func isWaiting(_ state: DatabaseSession.State) -> Bool {
        if case .lost = state { return true }
        return false
    }

    static func canTryAgain(_ state: DatabaseSession.State) -> Bool {
        switch state {
        case .failed, .stopped: return true
        default: return false
        }
    }
}
