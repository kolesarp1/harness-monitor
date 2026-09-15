import HarnessUsageCore
import SwiftUI

// The inline login states inside a provider's Settings pane: waiting for the browser callback, or a
// sanitized failure. Waiting shows what is happening and offers the only honest action (cancel, which
// closes the loopback listener and cancels the Core login). Failures name the cause and the next
// step; provider bodies, codes and callback queries never reach these strings — see
// `AccountLoginController.message(for:)`.
struct LoginStatusView: View {
    let integration: Integration
    let controller: AccountLoginController

    var body: some View {
        switch controller.state {
        case .waiting(let pending) where pending == integration:
            waitingRow
        case .failed(let failedIntegration, let message) where failedIntegration == integration:
            failureRow(message)
        default:
            EmptyView()
        }
    }

    var isVisible: Bool {
        switch controller.state {
        case .waiting(let pending): pending == integration
        case .failed(let failedIntegration, _): failedIntegration == integration
        default: false
        }
    }

    private var waitingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for the browser…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.csTitle)
                Text("Finish signing in to \(integration.displayName), then return here.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.csFaint)
            }
            Spacer(minLength: 8)
            DialogButton(title: "Cancel") {
                Task { await controller.cancel() }
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
    }

    private func failureRow(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.csAmber)
            VStack(alignment: .leading, spacing: 2) {
                Text("Login did not finish")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.csTitle)
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.csFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            DialogButton(title: "Dismiss") { controller.dismissError() }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
    }
}

// The freshness line under an account row: live accounts name their active source; a fallback says
// whose numbers these are; a disconnected account shows the last reading's age, which is the one
// honest thing a frozen reading can still say.
struct AccountStateLine: View {
    let snapshot: UsageSnapshot
    var now: Date = Date()

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Color.csFaint)
            .lineLimit(1)
    }

    private var text: String {
        switch snapshot.freshness {
        case .fresh where snapshot.activeAccountSource == .owned:
            "Live · Harness Monitor"
        case .fresh:
            "Live"
        case .fallback:
            "Harness Monitor unavailable — showing the detected login"
        case .disconnected:
            "Last reading \(AccountAge.text(since: snapshot.lastUpdated, now: now))"
        }
    }
}
