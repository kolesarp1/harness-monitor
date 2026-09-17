import HarnessUsageCore
import SwiftUI

// The pane that answers "which accounts am I signed into, and where are they right now".
//
// It is built on one distinction the rest of the app now keeps: an ACCOUNT owns the quota and can
// move; a LANE is the directory a CLI runs against and never owns anything. So accounts are named
// by the email the provider itself reports, lanes are named by a letter and a path, and no
// user-typed label is allowed to stand in for either — a label cannot follow a login when it moves,
// which is exactly how "Personal" came to sit on an account that was not personal.
@MainActor struct LanesPane: View {
    let accounts: [AccountConfig]
    var usage: UsageStore?
    var onAccountsChanged: @MainActor () async -> Void

    /// One controller per harness, on the pair of lanes that can trade logins.
    @State private var sessions: [Harness: CredentialControllerSession]

    init(
        accounts: [AccountConfig], usage: UsageStore?, controllerAudit: ControllerAuditStore,
        onAccountsChanged: @escaping @MainActor () async -> Void
    ) {
        self.accounts = accounts
        self.usage = usage
        self.onAccountsChanged = onAccountsChanged
        var built: [Harness: CredentialControllerSession] = [:]
        for harness in accounts.multiLaneHarnesses {
            for lane in accounts.lanes(of: harness) {
                let session = CredentialControllerSession(
                    account: lane.account, accounts: accounts, audit: controllerAudit)
                if !session.candidates.isEmpty {
                    built[harness] = session
                    break
                }
            }
        }
        _sessions = State(initialValue: built)
    }

    private var harnesses: [Harness] { accounts.multiLaneHarnesses }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if harnesses.isEmpty {
                Text("Every provider here has a single login, so there are no lanes to keep straight.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.csLabel)
            }
            ForEach(harnesses, id: \.self) { harness in
                harnessSection(harness)
            }
        }
        .confirmationDialog(
            pendingTitle,
            isPresented: Binding(
                get: { pendingSession != nil },
                set: { if !$0 { pendingSession?.cancel() } })
        ) {
            Button(pendingButton, role: .destructive) {
                guard let session = pendingSession else { return }
                Task {
                    // The lanes now hold different accounts, so every ring reading them is stale.
                    if await session.confirm() { await onAccountsChanged() }
                }
            }
        } message: {
            Text(pendingMessage)
        }
    }

    // MARK: one harness

    @ViewBuilder private func harnessSection(_ harness: Harness) -> some View {
        let lanes = accounts.lanes(of: harness)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                BrandMark(
                    integration: lanes[0].integration, size: 16,
                    tint: lanes[0].integration.descriptor.brandColor)
                Text(harness.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.csTitle)
            }
            SettingsGroup("Accounts signed in") {
                let groups = accountGroups(lanes)
                if groups.isEmpty {
                    plainRow("No login has reported an account yet.")
                }
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { GlassDivider() }
                    accountRow(group)
                }
            }
            SettingsGroup("Lanes") {
                ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                    if index > 0 { GlassDivider() }
                    laneRow(lane)
                }
            }
            if let session = sessions[harness] {
                moveGroup(session, lanes: lanes)
                parkedGroup(session, lanes: lanes)
            }
        }
    }

    // MARK: accounts

    /// The distinct accounts reporting in, each with every lane currently holding it. Grouping by
    /// the account rather than by the ring is what makes "both lanes are the same login" visible
    /// instead of appearing as two identical rings.
    private func accountGroups(_ lanes: [Lane]) -> [(email: String, lanes: [Lane])] {
        var order: [String] = []
        var byEmail: [String: [Lane]] = [:]
        for lane in lanes {
            guard let email = usage?[lane.integration]?.accountEmail, !email.isEmpty else { continue }
            if byEmail[email] == nil { order.append(email) }
            byEmail[email, default: []].append(lane)
        }
        return order.map { ($0, byEmail[$0] ?? []) }
    }

    private func accountRow(_ group: (email: String, lanes: [Lane])) -> some View {
        let snapshot = group.lanes.compactMap { usage?[$0.integration] }.first
        let meters = (snapshot?.windows ?? [])
            .filter { $0.kind.modelName == nil }
            .prefix(3)
            .map { "\($0.title) \(Int($0.utilization.rounded()))%" }
            .joined(separator: "   ")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(group.email)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.csTitle)
                Spacer(minLength: 8)
                Text(group.lanes.map(\.name).joined(separator: ", "))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.csAccent)
            }
            if !meters.isEmpty {
                Text(meters)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.csLabel)
            }
            if group.lanes.count > 1 {
                // Not a fault: putting one login in several lanes is a deliberate move. It is called
                // out because those lanes then share one quota, and their rings read identically.
                Text("In \(group.lanes.count) lanes — they share this account's quota, so their rings match.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.csFaint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: lanes

    private func laneRow(_ lane: Lane) -> some View {
        let snapshot = usage?[lane.integration]
        let email = snapshot?.accountEmail
        return HStack(alignment: .top, spacing: 10) {
            Text(lane.letter)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.csOnAccent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.csAccent))
            VStack(alignment: .leading, spacing: 3) {
                Text(email ?? "No account loaded")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(email == nil ? Color.csFaint : Color.csTitle)
                Text("\(lane.machine) · \(lane.directory)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.csLabel)
                if let note = snapshot?.note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.csRed)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: moving logins

    @ViewBuilder private func moveGroup(_ session: CredentialControllerSession, lanes: [Lane]) -> some View {
        if let own = lane(for: session.account, in: lanes), let other = session.partner,
            let partnerLane = lane(for: other, in: lanes)
        {
            SettingsGroup("Move logins between lanes") {
                SettingsRow(
                    "Swap",
                    subtitle: "\(own.name) and \(partnerLane.name) trade logins. Both are saved first."
                ) {
                    Button(session.isRunning ? "Working…" : "Swap \(own.letter) ⇄ \(partnerLane.letter)") {
                        Task { await session.prepare(.swap) }
                    }
                    .disabled(session.isRunning)
                }
                GlassDivider()
                SettingsRow("Use one login in both", subtitle: "For working past one account's limit.") {
                    HStack(spacing: 6) {
                        Button("\(own.letter)'s in both") { Task { await session.prepare(.useOwnInBoth) } }
                            .disabled(session.isRunning)
                        Button("\(partnerLane.letter)'s in both") {
                            Task { await session.prepare(.usePartnerInBoth) }
                        }
                        .disabled(session.isRunning)
                    }
                }
                if !session.message.isEmpty {
                    GlassDivider()
                    plainRow(session.message)
                }
            }
        }
    }

    @ViewBuilder private func parkedGroup(_ session: CredentialControllerSession, lanes: [Lane]) -> some View {
        SettingsGroup("Parked logins") {
            if session.parked.isEmpty {
                plainRow("Nothing parked on this machine yet. Every swap saves the pair it replaces.")
            }
            ForEach(session.parked) { entry in
                parkedRow(entry, session: session, lanes: lanes)
                GlassDivider()
            }
            SettingsRow("Refresh", subtitle: "Ask the machine what it has saved.") {
                Button(session.isRunning ? "Working…" : "Check") {
                    Task { await session.refreshParked() }
                }
                .disabled(session.isRunning)
            }
        }
        // One ssh round trip when the pane opens, so what is parked is on screen without being
        // asked for — this is the list the user comes here to read.
        .task { await session.refreshParked() }
    }

    private func parkedRow(
        _ entry: ParkedLogin, session: CredentialControllerSession, lanes: [Lane]
    ) -> some View {
        // Which lane each half came from is read from the session, not from the order of the two
        // fields: the pair was parked by whichever lane started that change.
        let origin = session.origin(of: entry)
        let holdings = origin.map { origin in
            [
                (lane(for: origin.first, in: lanes), entry.firstEmail),
                (lane(for: origin.second, in: lanes), entry.secondEmail),
            ]
            .compactMap { pair -> String? in
                guard let lane = pair.0 else { return nil }
                return "\(lane.name): \(pair.1 ?? "unknown")"
            }
            .joined(separator: "   ")
        }
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(holdings ?? "Saved before this app recorded lane positions")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(holdings == nil ? Color.csFaint : Color.csTitle)
                if let savedAt = entry.savedAt {
                    Text("saved \(savedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.csFaint)
                }
                if holdings == nil {
                    Text("Loading it could put each login in the other lane, so it is not offered.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.csFaint)
                }
            }
            Spacer(minLength: 8)
            if holdings != nil {
                Button("Load") { Task { await session.prepareLoad(entry) } }
                    .disabled(session.isRunning)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func lane(for account: AccountConfig, in lanes: [Lane]) -> Lane? {
        lanes.first { $0.integration == account.integration }
    }

    private func plainRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Color.csLabel)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: confirmation

    private var pendingSession: CredentialControllerSession? {
        harnesses.compactMap { sessions[$0] }.first { $0.pending != nil }
    }

    private var pendingTitle: String {
        guard let session = pendingSession, let pending = session.pending else { return "" }
        let lanes = accounts.lanes(of: session.account.harness)
        let own = lane(for: session.account, in: lanes)?.name ?? "this lane"
        let other = lane(for: pending.partner, in: lanes)?.name ?? "the other lane"
        if pending.loading != nil { return "Load this parked pair into \(own) and \(other)?" }
        switch pending.action {
        case .swap: return "Swap the logins in \(own) and \(other)?"
        case .useOwnInBoth: return "Put \(own)'s login in both lanes?"
        case .usePartnerInBoth: return "Put \(other)'s login in both lanes?"
        }
    }

    private var pendingButton: String {
        pendingSession?.pending?.loading == nil ? "Change the lanes" : "Load into lanes"
    }

    private var pendingMessage: String {
        guard let session = pendingSession else { return "" }
        let machine = session.account.host.sshAlias ?? "this Mac"
        return
            "Both logins are saved on \(machine) first, and stay there until you load them again. Restart any Claude session running in these lanes afterwards, or it will write its old login back."
    }
}
