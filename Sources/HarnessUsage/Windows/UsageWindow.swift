import HarnessUsageCore
import SwiftUI

// Which provider the usage card shows. An observable of its own rather than view state: the notch
// preselects the provider whose ring the pointer is on, and a `@State` inside the view would survive
// the root-view update and ignore it. nil → the card's own most-drained default.
@MainActor @Observable final class ProviderSelection {
    var integration: Integration?
}

// The Usage section: the account meters for one provider. Same data, four selectable looks (deck
// concepts) chosen by `settings.usageLayout`: linear bars, bare bars, a dot-matrix band, or a
// single-window spotlight. Severity thresholds flow in from Settings so every layout colors and pulses
// identically. The host `NotchUsageCard` owns the width + glass chrome; the card itself carries no
// controls at all — the notch is the provider switcher, one ring each, and its orb is the gear.
struct UsageSection: View {
    let usage: UsageStore
    let settings: SettingsStore
    let selection: ProviderSelection
    /// The tracked accounts, in `accounts.json` order. The card needs the ORDER as well as the set:
    /// its fallback provider is picked from this list, and a set alone would let it change between
    /// renders. Passed in rather than read from `Accounts`, so `--mock` draws the mock accounts.
    let accounts: [Integration]

    var body: some View {
        // The ring under the pointer is the provider the card is about, whatever it has to show — a
        // signed-out provider gets its own empty state, never another provider's meters. Only with no
        // ring hovered (Settings previews, measurement before a hover) does the card fall back to the
        // most-drained provider that has something to report.
        let shown =
            selection.integration
            ?? UsageSelection.chosenProvider(
                UsageSelection.availableProviders(
                    accounts, usage: usage.byIntegration, settings: settings.settings),
                usage: usage.byIntegration, settings: settings.settings)
        content(shown: shown)
    }

    private func snapshot(for i: Integration) -> UsageSnapshot? {
        usage[i]
    }

    // The meters block on top (when the provider has real % data), optionally with the local
    // token-estimate strip below it. The strip shows only when the user enabled it (Settings) — so a
    // no-plan provider (API-key Codex / opencode / signed-out Claude) is blank with a prompt to enable
    // it, instead of silently showing tokens the user opted out of. The estimated $ is passed only
    // alongside meters: a subscription's flat fee isn't comparable to API list price.
    @ViewBuilder private func content(shown: Integration?) -> some View {
        if let shown {
            let snap = snapshot(for: shown)
            let provider = settings.settings.provider(for: shown)
            let hasMeters = !(snap?.windows(includingExtras: provider.showExtraCaps).isEmpty ?? true)
            let hasTokens = (snap?.todayInput != nil) && (snap?.todayOutput != nil)
            let showTokens = hasTokens && provider.showTokenEstimate
            VStack(spacing: 0) {
                if shown.harness == .claude || shown.harness == .codex,
                    let account = Accounts.config(for: shown)
                {
                    AccountIdentityRow(
                        account: snap?.accountEmail ?? account.label,
                        source: account.host.sshAlias ?? "This Mac")
                    if hasMeters || showTokens { GlassDivider() }
                }
                if hasMeters {
                    meters(snap, for: shown)
                    if showTokens {
                        GlassDivider()
                        TokenEstimateStrip(snapshot: snap)
                    }
                } else if showTokens {
                    TokenEstimateStrip(snapshot: snap)
                } else {
                    EmptyUsage()
                }
            }
        } else {
            // No provider qualifies. If enabling the estimate would show something, prompt to enable
            // it; otherwise (Cursor-only, signed out, nothing ran yet) report it's unavailable.
            if tokensHiddenBySettings && someDetectedOffersTokens() {
                TokenEstimateDisabled(names: tokenEstimateDisabledProviderNames)
            } else {
                EmptyUsage()
            }
        }
    }

    // Whether enabling the token estimate would render something for a detected integration — decides
    // if the "estimate disabled" prompt is truthful rather than a tease. Codex/opencode expose token
    // data cheaply, so `todayInput` is populated even while the estimate is off. Claude's estimate is
    // exactly what the setting gates (we skip its scan when off, so its `todayInput` is nil), so a
    // detected Claude always "offers" tokens — without this it would flip from the prompt to a
    // misleading "unavailable" once the first gated refresh clears the totals.
    private var tokenEstimateDisabledProviderNames: [String] {
        accounts.compactMap { integration -> String? in
            guard usage.byIntegration[integration] != nil,
                integration.reportsTokens,
                !settings.settings.provider(for: integration).showTokenEstimate
            else { return nil }
            return integration.displayName
        }
    }

    private var tokensHiddenBySettings: Bool {
        !tokenEstimateDisabledProviderNames.isEmpty
    }

    private func someDetectedOffersTokens() -> Bool {
        UsageSelection.offersTokens(usage: usage.byIntegration)
    }

    // The meters block. Linear/simple/dotMatrix share ONE view type (MeterRows) so SwiftUI never sees
    // a type change when switching between them. Spotlight is structurally different (hero + compact
    // rows) so it stays its own type, but it renders the same rows in the same order
    // (`spotlightRows(showingExtras:)` only splits the array). The slide-free layout switch is handled at the panel root via
    // `.animation(nil, value: usageLayout)` — see the comment there for why it must be at the root.
    @ViewBuilder private func meters(_ snap: UsageSnapshot?, for shown: Integration) -> some View {
        let warningAt = settings.settings.warningAt
        let criticalAt = settings.settings.criticalAt
        let layout = settings.settings.usageLayout
        let showExtraCaps = settings.settings.provider(for: shown).showExtraCaps
        switch layout {
        case .spotlight:
            let spotlight = snap?.spotlightRows(showingExtras: showExtraCaps)
            SpotlightMeters(
                hero: spotlight?.hero, compact: spotlight?.compact ?? [],
                warningAt: warningAt, criticalAt: criticalAt)
        default:
            MeterRows(
                rows: snap?.windows(includingExtras: showExtraCaps) ?? [], warningAt: warningAt,
                criticalAt: criticalAt, layout: layout)
        }
    }
}

// Login identity is deliberately a quiet line in the hover card: it confirms which subscription the
// meters belong to without competing with the limits themselves.
private struct AccountIdentityRow: View {
    let account: String
    let source: String

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                identityLine(label: "Account", value: account.isEmpty ? "Default" : account)
                identityLine(label: "Source", value: source)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func identityLine(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(Color.csFaint)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.csLabel)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// The local token-estimate strip rendered below the usage meters (design F · token subline). A hero
// "Total token spend" line (Input + Output — cache excluded, so it tracks real work, not the
// cache-read-inflated grand total) over a dim "in/out" subline, then the optional local extras: the
// cost lines directly under the total (real "$X" for opencode today, approximate "≈ $X" for our
// own estimate) and the weekly token total.
private struct TokenEstimateStrip: View {
    let snapshot: UsageSnapshot?

    var body: some View {
        let input = snapshot?.todayInput ?? 0
        let output = snapshot?.todayOutput ?? 0
        VStack(spacing: 5) {
            row {
                Text("Total token spend").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.csLabel)
            } value: {
                Text(UsageFormat.tokens(input + output))
                    .font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Color.csTitle)
            }
            row {
                Text("In/Out").font(.system(size: 11.5)).foregroundStyle(Color.csFaint)
            } value: {
                Text("\(UsageFormat.tokens(input)) / \(UsageFormat.tokens(output))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.csFaint)
            }
            if let cost = snapshot?.estimatedCostUSD {
                // Approximate API-list-price value — never what a flat-fee subscriber actually pays.
                // The "≈" rides on the number, not the label: it qualifies the amount, and the label
                // then reads the same as the real cost row beside it.
                faintRow(label: "Cost today", value: "≈ " + usd(cost))
            }
            if let cost = snapshot?.costTodayUSD {
                faintRow(label: "Cost today", value: usd(cost))
            }
            if let week = snapshot?.localTokensWeek {
                faintRow(label: "This week", value: UsageFormat.tokens(week))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // "$12.30" for readable amounts; more precision under a dime so a small session cost isn't "$0.00".
    private func usd(_ v: Double) -> String {
        if v >= 1 { return String(format: "$%.2f", v) }
        if v >= 0.1 { return String(format: "$%.3f", v) }
        return String(format: "$%.4f", v)
    }

    @ViewBuilder private func faintRow(label: String, value: String) -> some View {
        row {
            Text(label).font(.system(size: 11)).foregroundStyle(Color.csFaint)
        } value: {
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.csFaint)
        }
    }

    @ViewBuilder private func row(@ViewBuilder _ label: () -> some View, @ViewBuilder value: () -> some View)
        -> some View
    {
        HStack(spacing: 8) {
            label()
            Spacer(minLength: 8)
            value()
        }
    }
}

// Shown when no provider reports usage yet (signed out, or before the first request).
private struct EmptyUsage: View {
    var body: some View {
        CompactEmptyState(label: "Usage data unavailable")
    }
}

// Shown when a provider has local token data but the user opted out of the estimate: enabling it
// would render the token strip, so point them at the provider's Settings toggle.
private struct TokenEstimateDisabled: View {
    let names: [String]

    var body: some View {
        CompactEmptyState(label: "Turn on Show token estimate for \(names.formatted(.list(type: .and)))")
    }
}

// MARK: - Shared severity styling

// One source of truth for how a meter's level maps to colors, gradient, and the reset line, so all four
// layouts and the notch's rings read identically. Thresholds always flow in from Settings.
enum UsageStyle {
    static func level(_ util: Double, warningAt: Double, criticalAt: Double) -> UsageLevel {
        UsageStatus.level(util, warningAt: warningAt, criticalAt: criticalAt)
    }

    static func color(_ l: UsageLevel) -> Color {
        switch l {
        case .safe: return .csOk
        case .warn: return .csAmber
        case .critical: return .csCrit
        }
    }

    static func gradient(_ l: UsageLevel) -> [Color] {
        switch l {
        case .safe: return [.csOkDeep, .csOk]
        case .warn: return [.csAmberDeep, .csAmber]
        case .critical: return [.csCritDeep, .csCrit]
        }
    }

    // Always "resets in <countdown> · <stamp>" while the reset is ahead (the countdown is the part
    // that moves, the stamp is the part you can plan around — both at any distance); for an already-
    // past reset (stale snapshot) just the moment, no "in 0m". The whole line is one colour — the bar
    // and the percentage already carry the severity, so the values separate from the "resets" prefix
    // by weight alone.
    static func resetText(_ r: Date, now: Date) -> Text {
        let secs = Int(r.timeIntervalSince(now))
        let stamp = Text(UsageFormat.resetStamp(r, now: now)).fontWeight(.semibold)
        let line: Text =
            if secs <= 0 {
                Text("resets ") + stamp
            } else {
                Text("resets in ") + Text(UsageFormat.countdown(secs)).fontWeight(.semibold)
                    + Text(" · ") + stamp
            }
        return line.foregroundStyle(Color.csLabel)
    }
}

// The reset line shared by the meter layouts: the formatted countdown to the window's reset.
private struct ResetLine: View {
    let usage: UsageWindow?
    var size: CGFloat = 11

    var body: some View {
        if let r = usage?.resetsAt {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                UsageStyle.resetText(r, now: ctx.date)
                    .font(.system(size: size))
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Meter rows (linear / simple / dotMatrix)

// ONE view type for three layouts so SwiftUI never sees a view-type change when switching between
// them — only parameter changes, which apply instantly. (Any `.animation` left in this subtree slides
// the whole window on a layout switch — see glass-widgets.md.)
//
// `linear`: full meter per row (label + % + bar + reset line), divider between rows.
// `simple`: bare bars only — no labels, no reset, no divider; 13pt spacing between the two bars.
// `dotMatrix`: like linear but the bar is a dot band.
private struct MeterRows: View {
    let rows: [UsageWindow]
    let warningAt: Double
    let criticalAt: Double
    let layout: UsageLayout

    private var isSimple: Bool { layout == .simple }
    private var isDotMatrix: Bool { layout == .dotMatrix }
    private var barVariant: ProgressBar.Variant {
        isDotMatrix ? .dotMatrix : .capsule(height: 7)
    }

    var body: some View {
        VStack(spacing: isSimple ? 13 : 16) {
            // One row per element, so a provider gaining a limit gains a bar and nothing else moves.
            // Labels are unique within a snapshot (the two account windows, the cycle, one per model).
            ForEach(rows, id: \.id) { row($0) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, isSimple ? 16 : 12)
    }

    @ViewBuilder private func row(_ named: UsageWindow) -> some View {
        let util = named.utilization
        let level = UsageStyle.level(util, warningAt: warningAt, criticalAt: criticalAt)
        VStack(alignment: .leading, spacing: 9) {
            if !isSimple {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(named.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.csTitle)
                    if let caption = caption(named) {
                        Text(caption).font(.system(size: 11)).foregroundStyle(Color.csFaint)
                    }
                    Spacer(minLength: 8)
                    Text("\(UsageFormat.percent(util))%")
                        .font(.system(size: isDotMatrix ? 15 : 17, weight: .bold, design: .monospaced))
                        .foregroundStyle(UsageStyle.color(level))
                }
            }
            ProgressBar(fraction: min(1, max(0, util / 100)), level: level, variant: barVariant)
            if !isSimple {
                ResetLine(usage: named, size: isDotMatrix ? 10.5 : 11)
            }
        }
    }

    // Show a compact span for short account windows. Model caps stay bare, and a monthly cycle's
    // title already names its cadence, matching the existing rows without knowing a provider's ids.
    private func caption(_ row: UsageWindow) -> String? {
        guard row.kind.isAccount, let period = row.period else { return nil }
        let hours = period / 3_600
        if hours < 24, hours.rounded() == hours { return "\(Int(hours))h" }
        let days = period / 86_400
        if days < 30, days.rounded() == days { return "\(Int(days))d" }
        return nil
    }
}

// A single progress bar component with two visual variants — capsule (the standard severity-tinted
// bar) and dotMatrix (the matrix-glyph band). Unifying them lets SwiftUI see the same view type
// across layout switches (no insert/remove transitions), and keeps the bar logic in one place.
private struct ProgressBar: View {
    enum Variant {
        case capsule(height: CGFloat)
        case dotMatrix
    }
    let fraction: CGFloat
    let level: UsageLevel
    let variant: Variant

    var body: some View {
        switch variant {
        case .capsule(let height):
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.csWell)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: UsageStyle.gradient(level), startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: height)
            .modifier(CriticalGlow(active: level == .critical, color: .csCrit))
        case .dotMatrix:
            let side: CGFloat = 9
            let gap: CGFloat = 3
            Canvas { gc, size in
                let fillColor = UsageStyle.color(level)
                let spacing = side + gap
                let cols = max(1, Int((size.width + gap) / spacing))
                let gridW = CGFloat(cols) * side + CGFloat(cols - 1) * gap
                let x0 = (size.width - gridW) / 2
                let y = (size.height - side) / 2
                let filled = Int((fraction * CGFloat(cols)).rounded())
                let radius = side * 0.18
                for col in 0..<cols {
                    let rect = CGRect(x: x0 + CGFloat(col) * spacing, y: y, width: side, height: side)
                    let color = col < filled ? fillColor : Color.csFaint.opacity(0.3)
                    gc.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(color))
                }
            }
            .frame(height: side)
        }
    }
}

// MARK: - Spotlight (concept 06)

// The first row as a HERO block (big % over a severity-tinted gradient + bar), every other row as a
// compact line with a trailing sparkbar. This layout trades breadth for one dominant number, but it
// drops nothing and reorders nothing: a row the provider reports and this layout never drew would read
// as a window the plan does not have.
private struct SpotlightMeters: View {
    let hero: UsageWindow?
    let compact: [UsageWindow]
    let warningAt: Double
    let criticalAt: Double

    var body: some View {
        VStack(spacing: 0) {
            heroBlock
            // Labels are unique within a snapshot (the two account windows, the cycle, one per model).
            ForEach(compact, id: \.id) { compactRow($0) }
        }
    }

    // Whatever the provider reports first is printed big: a plan with no 5-hour window (Codex
    // weekly-only, Cursor's billing cycle) would otherwise put a big "—" above its one real number.
    private var heroBlock: some View {
        let window = hero
        let util = window?.utilization ?? 0
        let level = UsageStyle.level(util, warningAt: warningAt, criticalAt: criticalAt)
        let severity = UsageStyle.color(level)
        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 14) {
                bigPercent(util, hasData: window != nil, color: severity, value: 46, unit: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(hero?.title ?? "Usage") limit")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.csLabel)
                    ResetLine(usage: window, size: 10.5)
                }
                Spacer(minLength: 0)
            }
            ProgressBar(fraction: min(1, max(0, util / 100)), level: level, variant: .capsule(height: 6))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactRow(_ row: UsageWindow) -> some View {
        let util = row.utilization
        let level = UsageStyle.level(util, warningAt: warningAt, criticalAt: criticalAt)
        let severity = UsageStyle.color(level)
        return HStack(spacing: 12) {
            bigPercent(util, hasData: true, color: severity, value: 28, unit: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.csTitle)
                ResetLine(usage: row, size: 10)
            }
            Spacer(minLength: 8)
            ProgressBar(fraction: min(1, max(0, util / 100)), level: level, variant: .capsule(height: 5))
                .frame(width: 80)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // The big number with a smaller "%" glyph beside it, both in the severity color. "—" when no data.
    @ViewBuilder private func bigPercent(_ util: Double, hasData: Bool, color: Color, value: CGFloat, unit: CGFloat)
        -> some View
    {
        if hasData {
            (Text(UsageFormat.percent(util)).font(.system(size: value, weight: .bold, design: .monospaced))
                + Text("%").font(.system(size: unit, weight: .bold, design: .monospaced)))
                .foregroundStyle(color)
        } else {
            Text("—")
                .font(.system(size: value, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}

// A soft, breathing glow applied to the critical meter's bar. Implemented with TimelineView (a
// display-link-driven time source) rather than phaseAnimator: phaseAnimator wraps its view in a
// continuous animation context that propagates UP to siblings in the parent VStack, so a layout
// switch while critical animated the weekly bar's position (the slide bug). TimelineView renders
// frames without creating an animation environment, so structural changes in sibling views stay
// instant regardless of whether the meter is critical.
private struct CriticalGlow: ViewModifier {
    let active: Bool
    let color: Color

    func body(content: Content) -> some View {
        if active {
            // 30 fps cap: a 2.2s glow breath reads identically, at a quarter of the frame cost.
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let phase = (sin(t * 2 * .pi / 2.2) + 1) / 2  // 2.2s period, 0→1→0
                content.shadow(color: color.opacity(phase * 0.55), radius: phase * 7)
            }
        } else {
            content
        }
    }
}
