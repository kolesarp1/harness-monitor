import HarnessUsageCore
import SwiftUI

// How a login is named on screen: its stored automatic or manually assigned name, then its email or folder.
// The notch's chip, the card's first line, the Settings row and the rename dialog all letter from here,
// so they cannot disagree about what an account is called.
enum AccountLabel {
    static func title(_ account: UsageAccount, names: [String: String]) -> String {
        if let name = names[account.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return account.email ?? account.location
    }

    // The avatar always uses the assigned name. `suggestedName` covers the short interval before a new
    // account's automatic name is persisted.
    static func letter(_ account: UsageAccount, names: [String: String]) -> String {
        if let name = names[account.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return initial(of: name)
        }
        return initial(of: account.suggestedName)
    }

    // The first letter or digit, so "~/.claude-work" letters itself "C" rather than "~".
    static func initial(of text: String) -> String {
        text.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
    }
}

// The letter that tells two logins of one harness apart, on the same light tile Settings selects a pane
// with.
struct AccountTile: View {
    let letter: String
    var size: CGFloat = 24
    var muted = false

    var body: some View {
        Text(letter)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(muted ? Color.csLabel : Color.csOnAccent)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(muted ? Color.csWell : Color.csAccent))
    }
}

struct PlanChip: View {
    let plan: String

    var body: some View {
        Text(plan)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.csLabel)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 3)
            .padding(.horizontal, 7)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.csWell))
    }
}

enum AccountSourceKind: String, Equatable {
    case login
    case local
    case both

    // Provenance describes recorded methods, not whether either method works right now.
    static func classify(_ sources: [UsageAccountSource]) -> AccountSourceKind? {
        let hasLogin = sources.contains { $0.kind == .owned }
        let hasLocal = sources.contains { $0.kind == .detected }
        switch (hasLogin, hasLocal) {
        case (true, true): return .both
        case (true, false): return .login
        case (false, true): return .local
        case (false, false): return nil
        }
    }
}

enum AccountProblemTone: Equatable {
    case warning
    case fallback
    case disconnected
    case disconnectedWarning
}

struct AccountProblem: Equatable {
    let text: String
    let tone: AccountProblemTone
}

enum AccountMetadata {
    static func settingsItems(
        account: UsageAccount, title: String, sources: [UsageAccountSource],
        lastReadingAt: Date? = nil, now: Date = Date()
    ) -> [String] {
        MetadataRow.values(
            [title == account.email ? nil : account.email]
                + detectedPaths(sources).map(Optional.some)
                + [
                    AccountSourceKind.classify(sources)?.rawValue,
                    lastReadingAt.map { AccountAge.text(since: $0, now: now) },
                ])
    }

    static func cardItems(account: UsageAccount, title: String) -> [String] {
        MetadataRow.values([title == account.email ? nil : account.email])
    }

    static func renameItems(
        account: UsageAccount, integration: Integration, sources: [UsageAccountSource]
    ) -> [String] {
        MetadataRow.values(
            [integration.planDisplayName(account.plan)]
                + detectedPaths(sources).map(Optional.some)
                + [AccountSourceKind.classify(sources)?.rawValue])
    }

    static func statusText(snapshot: UsageSnapshot, now: Date = Date()) -> String? {
        guard snapshot.freshness == .disconnected else {
            return problem(snapshot: snapshot, now: now)?.text
        }
        let note = MetadataRow.values([snapshot.note]).first
        let age = "Last reading \(AccountAge.text(since: snapshot.lastUpdated, now: now))"
        return note.map { joinedStatus($0, age) } ?? age
    }

    static func problem(snapshot: UsageSnapshot, now: Date = Date()) -> AccountProblem? {
        let note = MetadataRow.values([snapshot.note]).first
        switch snapshot.freshness {
        case .fresh:
            return note.map { AccountProblem(text: $0, tone: .warning) }
        case .fallback:
            let reason = note ?? "Browser login unavailable"
            return AccountProblem(
                text: joinedStatus(reason, "Showing local reading"), tone: .fallback)
        case .disconnected:
            guard let note else { return nil }
            let tone: AccountProblemTone =
                note == SubscriptionAccountError.reconnectRequired.localizedDescription
                ? .disconnectedWarning
                : .disconnected
            return AccountProblem(text: note, tone: tone)
        }
    }

    private static func joinedStatus(_ first: String, _ second: String) -> String {
        let first = first.hasSuffix(".") ? String(first.dropLast()) : first
        return "\(first) · \(second)"
    }

    private static func detectedPaths(_ sources: [UsageAccountSource]) -> [String] {
        MetadataRow.values(sources.filter { $0.kind == .detected }.map { Optional($0.reference) })
    }
}

enum AccountActionPolicy {
    static func removalLabel(
        hasOwnedConnection: Bool, sources: [UsageAccountSource]
    ) -> String? {
        let hasAvailableLocal = sources.contains { $0.kind == .detected && $0.isAvailable }
        if hasAvailableLocal { return hasOwnedConnection ? "Remove browser login" : nil }
        return hasOwnedConnection || sources.contains { $0.kind == .detected }
            ? "Remove account"
            : nil
    }

    static func canReconnect(hasOwnedConnection: Bool, ownedStatus: String?) -> Bool {
        guard hasOwnedConnection,
            let status = MetadataRow.values([ownedStatus]).first
        else { return false }
        return status == SubscriptionAccountError.reconnectRequired.localizedDescription
    }
}

// Shared identity metadata: empty items disappear and each remaining item is separated by its own
// muted glyph, so separators never inherit the row's normal foreground style.
struct MetadataRow: View {
    enum Part: Hashable {
        case text(String)
        case separator(before: String)

        var text: String {
            switch self {
            case .text(let value): value
            case .separator: "|"
            }
        }

        var isSeparator: Bool {
            if case .separator = self { return true }
            return false
        }
    }

    let items: [String?]
    var font: Font = .system(size: 11)
    var foreground: Color = .csLabel
    var keepLastItemVisible = false

    nonisolated static func values(_ items: [String?]) -> [String] {
        var seen = Set<String>()
        return items.compactMap { item in
            guard let value = item?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                seen.insert(value).inserted
            else { return nil }
            return value
        }
    }

    nonisolated static func parts(_ items: [String?]) -> [Part] {
        values(items).enumerated().flatMap { index, value in
            index == 0 ? [.text(value)] : [.separator(before: value), .text(value)]
        }
    }

    var body: some View {
        let parts = Self.parts(items)
        HStack(spacing: 4) {
            ForEach(parts, id: \.self) { part in
                Text(part.text)
                    .foregroundStyle(part.isSeparator ? Color.csFaint : foreground)
                    .accessibilityHidden(part.isSeparator)
                    .layoutPriority(keepLastItemVisible && part == parts.last ? 1 : 0)
            }
        }
        .font(font)
        .lineLimit(1)
        .truncationMode(.middle)
    }
}

// The usage-card identity stays deliberately spare: avatar and assigned name, plan at the far edge,
// and email only below. Folder and source provenance belong in Settings and the rename dialog.
struct AccountHeader: View {
    let account: UsageAccount
    let integration: Integration
    let names: [String: String]
    var stateLine: String? = nil

    var body: some View {
        let title = AccountLabel.title(account, names: names)
        let metadata = AccountMetadata.cardItems(account: account, title: title)
        HStack(alignment: .center, spacing: 10) {
            AccountTile(letter: AccountLabel.letter(account, names: names))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.csTitle)
                    .lineLimit(1)
                if !metadata.isEmpty {
                    MetadataRow(items: metadata.map { Optional($0) }, font: .system(size: 11.5))
                }
                if let stateLine {
                    Text(stateLine)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.csFaint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let plan = integration.planDisplayName(account.plan) { PlanChip(plan: plan) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

// "Last reading 3h ago": the stale card header's age. Coarse buckets, so the line is stable across
// minutes and the card measurement does not chase the clock.
enum AccountAge {
    static func text(since date: Date, now: Date = Date()) -> String {
        let secs = max(0, Int(now.timeIntervalSince(date)))
        if secs < 90 { return "just now" }
        if secs < 3_600 { return "\(secs / 60)m ago" }
        if secs < 86_400 { return "\(secs / 3_600)h ago" }
        return "\(secs / 86_400)d ago"
    }
}
