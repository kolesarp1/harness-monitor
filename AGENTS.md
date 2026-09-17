# Harness Monitor

A macOS app that shows how much Claude and Codex quota you have left. Cursor and opencode code is
retained but disabled. One dark-glass notch welded to the right screen edge, with a ring per account and
a usage card on hover or click. Usage tracking only — no agent or session tracking.

## Build & Dev Commands

```
make build       # swift build
make dev         # debug build, run in the foreground (Ctrl-C to quit)
make mock        # run against MockData/ fixtures — no real harnesses needed
make test        # swift test
make lint        # swift format lint --strict --recursive Sources Tests
make app         # full release: format + lint + test + universal build + .app + sign + dmg
make install     # make app, then install into /Applications and relaunch
make uninstall   # remove the installed app
make clean       # rm -rf .build build
make clean-dev   # wipe ALL state (both defaults domains + ~/.harness-usage) and relaunch
make env         # create .env from .env.example
```

CLI flags: `--dump` (one engine tick, printed), `--mock`, `--show-settings`, and `--no-login` (a
terminating CLI action that clears launch-at-login).

## Architecture

Two production SwiftPM targets, and the boundary is load-bearing:

- **`HarnessUsageCore`** — models, parsers, per-provider monitor actors, the engine, the stores.
  Foundation + Observation + system C libraries (`SQLite3`) only. **No AppKit, no SwiftUI, no
  third-party code.**
- **`HarnessUsage`** — the executable. AppKit/SwiftUI glue: the notch panel, the glass, the settings
  UI, brand rendering. Every per-provider decision it makes is read from a Core descriptor.

The engine is signal-driven: FSEvents marks watched roots dirty, settings and detection updates wake
immediately, and a 60s heartbeat handles time-driven bookkeeping. Mock mode keeps a short polling signal
because it has no watched roots. A tick with nothing due touches nothing. The global Update every
setting selects 1, 5 or 15 minutes (default 5) for both local reads and app-owned usage requests.
Engine retains dirty events until due; `UsageReloadPolicy` carries the same cadence into each actor.
`Engine.refreshNow()` bypasses app cadence and local scan floors, never server Retry-After.

Adding a provider is an `Integration` case + a folder under `Integrations/<name>/` (descriptor +
monitor) + one registry line. The descriptor owns identity, capabilities and branding; the monitor
reports whatever windows its provider has. No Core type, enum case or switch changes for a plan shape
nobody has modelled yet. Detection uses the descriptor's home-relative path, and the notch's rings and
the settings panes both iterate `Integration.supportedCases`. Initialization and detection use this
same subset; `allCases` remains complete for descriptor registration and settings persistence.

## Project Structure

```
Sources/HarnessUsageCore/
  Engine/        Engine (tick loop), FileWatcher (FSEvents), PerfLog
  Integrations/  IntegrationDescriptor + registry, MockMonitor, BrandSVG
    Claude/      Profile (one per config folder), Credentials, OAuth usage, UsageProvider,
                 LocalUsageEstimator, UsageIndex (SQLite parse cache), Descriptor
    Codex/       CodexAuth (auth.json, read-only), CodexUsageClient (live endpoint), Rollout, Monitor
    Cursor/      Credentials (state.vscdb), UsageClient (dashboard RPC), UsageLogic, Monitor
    OpenCode/    Monitor (opencode.db), Logic
  Logic/         UsageSelection, UsageFormat, UsageMath, IntegrationProbe, ModelPricing
  Models/        Integration, Settings, Usage, IntegrationMonitor
  Stores/        SettingsStore, UsageStore, IntegrationStore, SubscriptionAccountStore
Sources/HarnessUsage/
  main.swift, AppDelegate, Dump
  Windows/       WindowManager, GlassKit (the one glass + the cs* palette), UsageWindow,
                 SettingsWindow, AccountIdentity (labels, tile, card header),
                 AccountNameWindow (the rename dialog), BrandRender, LoginItem,
                 AccountLoginController, AccountLoginWindow, OAuthCallbackListener
  Notch/         NotchWindowController (panel, hit regions, fold), NotchViewModel, NotchRootView,
                 NotchLayout/Geometry/Placement/Edge/Motion + SideNotchShape (the geometry),
                 ProviderRing, SettingsOrb, NotchDesignSystem (the frame-scale maths),
                 NotchUsageCard + NotchCardMetrics (the hover card), NotchProvider (ring adapter)
Tests/HarnessUsageCoreTests/
Tests/HarnessUsageTests/  Non-rendering login controller, callback and presentation logic tests
MockData/        <provider>/fixtures.json
Resources/       icon-light.png, icon-dark.png
```

## Key Design Decisions

- **The notch is the app's only surface.** A dark-glass pill welded to the right screen edge that
  unfolds on hover into one ring per provider, its geometry ported from Codenotch (MIT,
  `vinzdg/codenotch`). Nothing in the menu bar. Settings is reached by
  clicking the notch's orb, by its right-click menu, or by relaunching the app
  (`applicationShouldHandleReopen`) — the escape hatch if the notch is ever not on screen.
  `NotchProvider` is the only adapter for the rings: it reads the same snapshots, the same
  per-provider `scope` through `UsageSelection.resolved`, and the same `warningAt`/`criticalAt` as the
  card, so a ring and the card it opens cannot quote different numbers for one harness. **Hovering a
  ring shows `UsageSection`**, in whichever layout Settings selects; `NotchCardMetrics` lays it out
  off screen to measure it, because its height depends on the layout, the window count and the token
  strip, and that one measured figure feeds both the panel's reserved room and the hover region. The
  geometry works in stack space (`along`/`across`) and `NotchPlacement` is the only place that maps it
  onto a screen edge. Everything the port left behind — session tracking, per-vendor block states, the
  black tooltip and its tail, the edge picker, the visibility modes — was dropped deliberately, not
  missed.
- **One glass and one palette, or it is a bug.** Every surface — the notch, its hover card, the
  Settings window — draws `GlassKit`'s single material: `.hudWindow` vibrancy blended behind the
  window, a 55% black tint and a 10% white rim. Only the mask differs (a shape path for the notch,
  which folds; a mask image for the windows, whose drop shadow is derived from it). Severity is
  `UsageStyle.color` for meters and rings alike. There is no theme: `AppDelegate` pins `darkAqua` on
  `NSApp` once at launch, so the `cs*` palette holds its dark values as plain constants and no window
  pins an appearance of its own. Adding a second tint, a second severity ramp or a per-window
  appearance is the regression this rule exists to catch.
- **External credentials are read-only.** Never write, refresh, copy or delete Pi/CLI credentials.
  Browser logins created by this app are independently owned and refreshed, with private atomic files
  under `~/.harness-usage/accounts/`. Cross-process refresh intent prevents replaying an ambiguously
  consumed refresh token; reconnect is required instead. See `docs/usage.md` §1.
- **Availability includes remembered accounts.** A detected folder or stored subscription makes a
  supported integration available. App-only accounts never trigger absent local credential probes.
  Deduplicate by provider identity, never email. Prefer healthy owned login, then matching local
  credentials, then a retained reading. Settings metadata says login, local or both for recorded methods;
  health is separate. Disconnected readings retain their age, with grey dashed rings; passed resets
  show Reset without a percentage. General's Hide inactive accounts hides disconnected rings only;
  Settings keeps their management rows. Accounts without a current local source can be forgotten;
  active local credentials are never removed. No account-data migrations are required.
- **Claude has two usage tiers.** OAuth supplies the 5h, weekly, and Fable windows. The local transcript
  estimator supplies today's tokens and cost. The last successful OAuth reading is retained across
  refreshes so the meters don't flap inside the selected cadence.
- **Detected Claude and Codex accounts come from config folders.** Independent subscriptions can also
  be connected from Settings. Claude's `/login` replaces the one login a folder holds. Detection reads
  `~/.claude`, and any `~/.claude-<name>` whose
  `.claude.json` has an `oauthAccount` (signed in through `CLAUDE_CONFIG_DIR`). Each is a
  `ClaudeProfile` with its own Keychain item, cache, parse index and ring. Codex similarly reads
  `~/.codex` plus signed-in `~/.codex-<name>` homes created through `CODEX_HOME`; each
  `CodexProfile` has its own `auth.json`, rollout files and live meter. Pi's account-unidentified token
  estimate is not attributed to any subscription. Readings use `UsageKey` with canonical account keys
  after identity resolution, and ring order persists those keys. A harness reporting more
  than one login letters its rings and heads its cards with the account. Names live in
  `Settings.accountNames` keyed by account id. A new account is named from its subscription profile,
  falling back to the email prefix, and can be renamed from its Settings pane. The avatar letters from
  that assigned name.
- **Plan labels use provider-specific presentation.** `Integration.planDisplayName` delegates to the
  descriptor's policy. Known codes become readable labels such as Max 5x and Pro 5x; unknown names
  remain visible. Apply this at presentation too, so saved raw names need no migration.
- **Account metadata shares one layout.** `MetadataRow` separates nonempty items with muted `|` glyphs.
  Settings puts name and plan together, then email, detected paths and provenance below. Card headers
  show avatar, name, plan and optional email only. Rename shows plan, paths and provenance. Healthy
  rows omit redundant Live text; fallback status replaces normal second-line metadata. Disconnected
  rows retain email, detected paths and provenance, followed by compact age on that same left line;
  any error appears separately below.
  One native ellipsis menu holds Rename, contextual removal and applicable Reconnect. Only actionable
  reconnect also gets an inline button. Add account is a quiet full-width row with a dashed plus tile.
- **Per-provider config** (`visible`, `scope`, `showExtraCaps`, `showTokenEstimate`) persists sparsely
  as `provider.<provider>.<field>`; Extra governs model caps in the card, the "Notch shows" picker and
  Most urgent selection. An absent provider reads `ProviderConfig.defaults`.
- **Every tier that declines to fire says why** via `UsageSnapshot.note`, surfaced in that provider's
  Settings row.
- **`SMAppService` is the only store of launch-at-login.** There is no persisted `Settings` field for
  it — a copy could only ever drift from what System Settings ▸ Login Items actually holds.
- **The app never writes outside `~/.harness-usage`** (plus its two `UserDefaults` domains).
  `make uninstall` removes the installed app and unregisters launch-at-login, deliberately keeping
  the usage cache and preferences; `make clean-dev` is the one that wipes all state.

## Configuration

- Preferences: `UserDefaults`. Installed builds use the bundle id `com.mikeben.harness-widget`;
  unbundled dev builds use the process-name domain `HarnessUsage`. Anything that wipes preferences
  must clear both.
- State: `~/.harness-usage/` — the usage cache, the SQLite parse index, and a `settings.json` version
  stamp. The app never writes outside this directory.
- Build config: `.env` (from `.env.example`), sourced by `build.sh`. Signing degrades to ad-hoc and
  notarization is skipped when the credentials are absent.
- Formatting: `.swift-format`, `lineLength: 240`, applied to `Sources` and `Tests`.

## Docs

`docs/` is gitignored, maintainer-local, and absent from a fresh clone. When present: `docs/usage.md`
(how each provider's meters are read, and the auth posture — read this first), `docs/glass-widgets.md`
(the glass and panel gotchas), `docs/gotchas.md` (cross-cutting traps), `docs/decisions.md` (the log).
