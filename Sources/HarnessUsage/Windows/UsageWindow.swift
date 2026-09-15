import HarnessUsageCore
import SwiftUI

// Which login the usage card shows. An observable of its own rather than view state: the notch
// preselects the login whose ring the pointer is on, and a `@State` inside the view would survive
// the root-view update and ignore it. nil → the card's own most-drained default.
@MainActor @Observable final class ProviderSelection {
    var key: UsageKey?
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

    var body: some View {
        // The ring under the pointer is the provider the card is about, whatever it has to show — a
        // signed-out provider gets its own empty state, never another provider's meters. Only with no
        // ring hovered (Settings previews, measurement before a hover) does the card fall back to the
        // most-drained provider that has something to report.
        let shown = selection.key ?? defaultReadingKey
        content(shown: shown)
    }

    private var defaultReadingKey: UsageKey? {
        usage.readings.keys.filter {
            settings.settings.provider(for: $0.integration).visible
        }.max { left, right in
            let leftConfig = settings.settings.provider(for: left.integration)
            let rightConfig = settings.settings.provider(for: right.integration)
            let leftValue =
                usage[left].flatMap {
                    UsageSelection.resolved($0, scope: leftConfig.scope, includingExtras: leftConfig.showExtraCaps)
                }?.utilization ?? -1
            let rightValue =
                usage[right].flatMap {
                    UsageSelection.resolved($0, scope: rightConfig.scope, includingExtras: rightConfig.showExtraCaps)
                }?.utilization ?? -1
            return leftValue < rightValue
        }
    }

    // The meters block on top (when the provider has real % data), optionally with the local
    // token-estimate strip below it. The strip shows only when the user enabled it (Settings) — so a
    // no-plan provider (API-key Codex / opencode / signed-out Claude) is blank with a prompt to enable
    // it, instead of silently showing tokens the user opted out of. The estimated $ is passed only
    // alongside meters: a subscription's flat fee isn't comparable to API list price.
    @ViewBuilder private func content(shown: UsageKey?) -> some View {
        if let shown {
            let snap = usage[shown]
            let provider = settings.settings.provider(for: shown.integration)
            let hasMeters = !(snap?.windows(includingExtras: provider.showExtraCaps).isEmpty ?? true)
            let hasTokens = (snap?.todayInput != nil) && (snap?.todayOutput != nil)
            let showTokens = hasTokens && provider.showTokenEstimate
            // Explicit freshness, never parsed prose: only a disconnected snapshot (no current
            // source) gets the stale projection. A fallback reading is live detected numbers.
            let stale = snap?.freshness == .disconnected
            VStack(spacing: 0) {
                if let account = snap?.account {
                    // The header carries the last reading's age while stale — a TimelineView so the
                    // line stays truthful without a tick, at a 60s cadence the card cache ignores.
                    if stale, let snapshot = snap {
                        TimelineView(.periodic(from: .now, by: 60)) { ctx in
                            AccountHeader(
                                account: account, integration: shown.integration,
                                names: settings.settings.accountNames,
                                stateLine: AccountMetadata.statusText(snapshot: snapshot, now: ctx.date)
                            )
                        }
                    } else {
                        AccountHeader(
                            account: account, integration: shown.integration,
                            names: settings.settings.accountNames)
                    }
                    GlassDivider()
                }
                if hasMeters {
                    meters(snap, for: shown.integration)
                    if showTokens {
                        GlassDivider()
                        TokenEstimateStrip(snapshot: snap)
                    }
                } else if showTokens {
                    TokenEstimateStrip(snapshot: snap)
                } else if stale {
                    StaleEmpty(snapshot: snap)
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
        Integration.supportedCases.compactMap { integration in
            guard usage.keys(for: integration).isEmpty == false,
                integration.descriptor.reportsTokens,
                !settings.settings.provider(for: integration).showTokenEstimate
            else { return nil }
            return integration.displayName
        }
    }

    private var tokensHiddenBySettings: Bool {
        !tokenEstimateDisabledProviderNames.isEmpty
    }

    private func someDetectedOffersTokens() -> Bool {
        Integration.supportedCases.contains { integration in
            guard integration.descriptor.reportsTokens else { return false }
            return usage.keys(for: integration).contains { key in
                let snapshot = usage[key]
                return snapshot?.todayInput != nil || snapshot?.todayOutput != nil
                    || integration == .claude
            }
        }
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
        // One projection for every layout: the ring's `isStale` and these rows read the same flag,
        // so a ring and the card it opens cannot quote different numbers for one harness.
        let stale = snap?.freshness == .disconnected
        switch layout {
        case .spotlight:
            let spotlight = snap?.spotlightRows(showingExtras: showExtraCaps)
            SpotlightMeters(
                hero: spotlight?.hero, compact: spotlight?.compact ?? [],
                warningAt: warningAt, criticalAt: criticalAt, stale: stale)
        default:
            MeterRows(
                rows: snap?.windows(includingExtras: showExtraCaps) ?? [], warningAt: warningAt,
                criticalAt: criticalAt, layout: layout, stale: stale)
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

// A disconnected account with nothing drawable: the snapshot note (the Core copies the account
// status there — reconnect, rate-limit) when it names the cause, otherwise the shared empty line.
// Never a fabricated 0%.
private struct StaleEmpty: View {
    let snapshot: UsageSnapshot?

    var body: some View {
        if let snapshot, let note = snapshot.note, !note.isEmpty {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                CompactEmptyState(
                    label: "\(note) · Last reading \(AccountAge.text(since: snapshot.lastUpdated, now: ctx.date))"
                )
            }
        } else {
            EmptyUsage()
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

// One stale projection shared by all four meter layouts (concept E). A live snapshot draws every
// window in its severity colour. A disconnected snapshot draws old numbers grey — never a severity
// colour on a number the app did not just measure — and a window whose reset has passed since the
// last reading draws as "Reset" with no percent: the one honest thing a frozen reading can say.
// Unknown-reset windows stay visibly stale rather than silently live.
// How one window renders under the stale projection: live numbers, an old number in grey, or a
// reset-passed window with no percent at all. Shared by MeterRows and both Spotlight rows so the
// four layouts cannot disagree.
enum StaleWindowStyle {
    enum Projection: Equatable { case live, staleValue, resetPassed }

    static func projection(window: UsageWindow, stale: Bool, now: Date = Date()) -> Projection {
        guard stale else { return .live }
        if let reset = window.resetsAt, reset <= now { return .resetPassed }
        return .staleValue
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
    /// No current source works: old numbers draw grey, reset-passed windows read "Reset".
    var stale: Bool = false

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
        let projection = StaleWindowStyle.projection(window: named, stale: stale)
        VStack(alignment: .leading, spacing: 9) {
            if !isSimple {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(named.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.csTitle)
                    if let caption = caption(named) {
                        Text(caption).font(.system(size: 11)).foregroundStyle(Color.csFaint)
                    }
                    Spacer(minLength: 8)
                    switch projection {
                    case .live:
                        Text("\(UsageFormat.percent(util))%")
                            .font(.system(size: isDotMatrix ? 15 : 17, weight: .bold, design: .monospaced))
                            .foregroundStyle(UsageStyle.color(level))
                    case .staleValue:
                        Text("\(UsageFormat.percent(util))%")
                            .font(.system(size: isDotMatrix ? 15 : 17, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.csFaint)
                    case .resetPassed:
                        Text("Reset")
                            .font(.system(size: isDotMatrix ? 15 : 17, weight: .bold))
                            .foregroundStyle(Color.csFaint)
                    }
                }
            }
            ProgressBar(
                fraction: projection == .resetPassed ? 0 : min(1, max(0, util / 100)),
                level: level, variant: barVariant, stale: stale)
            if !isSimple, projection != .resetPassed {
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
    /// Stale bars draw in grey: severity colour would claim a fresh measurement.
    var stale: Bool = false

    var body: some View {
        switch variant {
        case .capsule(let height):
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.csWell)
                    Group {
                        if stale {
                            Capsule().fill(Color.csFaint.opacity(0.45))
                        } else {
                            Capsule().fill(
                                LinearGradient(
                                    colors: UsageStyle.gradient(level), startPoint: .leading,
                                    endPoint: .trailing))
                        }
                    }
                    .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: height)
            .modifier(CriticalGlow(active: level == .critical && !stale, color: .csCrit))
        case .dotMatrix:
            let side: CGFloat = 9
            let gap: CGFloat = 3
            Canvas { gc, size in
                let fillColor = stale ? Color.csFaint.opacity(0.45) : UsageStyle.color(level)
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
    /// No current source works: old numbers draw grey, reset-passed windows read "Reset".
    var stale: Bool = false

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
        let projection = window.map { StaleWindowStyle.projection(window: $0, stale: stale) } ?? .live
        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 14) {
                stalePercent(util, hasData: window != nil, projection: projection, value: 46, unit: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(hero?.title ?? "Usage") limit")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.csLabel)
                    if projection != .resetPassed {
                        ResetLine(usage: window, size: 10.5)
                    }
                }
                Spacer(minLength: 0)
            }
            ProgressBar(
                fraction: projection == .resetPassed ? 0 : min(1, max(0, util / 100)), level: level,
                variant: .capsule(height: 6), stale: stale)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactRow(_ row: UsageWindow) -> some View {
        let util = row.utilization
        let level = UsageStyle.level(util, warningAt: warningAt, criticalAt: criticalAt)
        let projection = StaleWindowStyle.projection(window: row, stale: stale)
        return HStack(spacing: 12) {
            stalePercent(util, hasData: true, projection: projection, value: 28, unit: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.csTitle)
                if projection != .resetPassed {
                    ResetLine(usage: row, size: 10)
                }
            }
            Spacer(minLength: 8)
            ProgressBar(fraction: projection == .resetPassed ? 0 : min(1, max(0, util / 100)), level: level, variant: .capsule(height: 5), stale: stale)
                .frame(width: 80)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // The big number with a smaller "%" glyph beside it. Live numbers take the severity color and
    // "—" means no data; on a stale reading old numbers print grey and a reset-passed window reads
    // "Reset" with no percent.
    @ViewBuilder private func stalePercent(
        _ util: Double, hasData: Bool, projection: StaleWindowStyle.Projection, value: CGFloat,
        unit: CGFloat
    ) -> some View {
        if projection == .resetPassed, hasData {
            Text("Reset")
                .font(.system(size: value * 0.55, weight: .bold))
                .foregroundStyle(Color.csFaint)
        } else if hasData {
            let color: Color =
                projection == .live
                ? UsageStyle.color(UsageStyle.level(util, warningAt: warningAt, criticalAt: criticalAt))
                : .csFaint
            (Text(UsageFormat.percent(util)).font(.system(size: value, weight: .bold, design: .monospaced))
                + Text("%").font(.system(size: unit, weight: .bold, design: .monospaced)))
                .foregroundStyle(color)
        } else {
            Text("—")
                .font(.system(size: value, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.csFaint)
        }
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
