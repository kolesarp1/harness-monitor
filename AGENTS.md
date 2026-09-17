# Harness Controller

Harness Controller is a macOS app that presents Claude, Codex, Cursor, and
opencode quota in a dark-glass edge notch and, for supported providers, can
explicitly control operational profiles. It never generates code or sends
prompts to a provider as an agent; its controller role includes exchanging
existing logins between two profile directories on one machine and managing
the resulting CLI-session handoff.

## Development commands

```sh
make build       # debug compile
make dev         # debug build and foreground launch
make mock        # run with MockData fixtures
make test        # Swift test suite
make lint        # strict Swift formatting check
make app         # release app and DMG
make install     # build, install into /Applications, and relaunch
```

`make app` requires full Xcode for tests and a universal build. On a
Command-Line-Tools-only Mac, use `SKIP_TESTS=1 NATIVE_ONLY=1 ./build.sh` only
for a local native-architecture build.

## Architecture

SwiftPM has two production targets. Keep their boundary strict:

- `HarnessUsageCore` contains models, account configuration, provider
  descriptors and monitors, the refresh engine, stores, parsing, remote probes,
  and the provider-neutral controller protocol. It uses Foundation, Observation,
  and system libraries only—no AppKit, SwiftUI, or third-party UI dependencies.
- `HarnessUsage` is the executable and owns AppKit/SwiftUI presentation: the
  notch, settings and usage windows, login-item integration, and rendering.
  Provider-specific decisions come from Core descriptors and snapshots.

Key folders:

```
Sources/HarnessUsageCore/
  Engine/        refresh scheduling, file watching, diagnostics
  Integrations/  descriptors, monitors, and controller support; Remote/ runs SSH probes/actions
  Logic/         presentation-independent usage calculations and formatting
  Models/        account, integration, settings, and usage value types
  Stores/        accounts.json plus settings, integration, and usage persistence
Sources/HarnessUsage/
  Notch/         notch geometry, interaction, and usage card UI
  Windows/       settings, usage, remote-login, glass, and login-item UI
Tests/HarnessUsageCoreTests/
MockData/
Resources/
```

## Account and data rules

- One ring represents one lane. A LANE is a directory a provider CLI runs
  against; an ACCOUNT is a login that owns quota. No account belongs to a lane:
  a login can be swapped in, copied into both lanes, or parked, so a lane is
  named by its letter and directory (`Lane`) and an account by the login email
  the provider itself reports. A user-typed label must never stand in for
  either — it cannot follow a login when it moves. Lanes are stored in
  `~/.harness-usage/accounts.json`; `AccountConfig` and `AccountsFile` own that
  format.
- A controller action must be initiated by the user, name its source and target
  profile in the UI, and be recorded in the app's own audit state. Never
  automatically switch because a quota is exhausted.
- Local controller actions may select an existing local profile and restart its
  provider CLI session. Remote controller actions use the system `ssh` in batch
  mode and act only on the configured SSH host and profile directory.
- Tokens are read, used, refreshed, or written only on the machine that owns
  the profile. A raw token, refresh token, credential blob, account ID, or
  provider secret must never be copied to this Mac, sent between hosts, logged,
  surfaced in UI, or placed in a process argument. Prefer invoking the
  provider's own CLI on the owning machine over manipulating credential files.
- Claude credential exchange or sharing is an explicit exception when two
  existing lanes on the same SSH host need to trade or share a login. Park both
  credential files and their `oauthAccount` profile metadata privately on that
  host before replacing anything, and load them back if asked.
  Preserve unrelated provider settings, plugins, projects, and transcripts.
- A parked pair is stored positionally, and which lane each position meant is
  known only from the local audit record. Anything that reads or loads a parked
  pair must resolve that orientation first and refuse when it is unknown —
  guessing puts a login in a lane it never came from.
- The app may write its own state under `~/.harness-usage` and its `UserDefaults`
  domains. Provider-state writes are allowed only as the direct, user-confirmed
  result of a controller action on that provider profile's owning machine.
- Cursor and opencode are single-login-per-machine. Keep account-specific
  controller behavior limited to integrations that support it.

## Change guidelines

- Add a provider through an `Integration` case, a descriptor, a monitor, and
  the registry. Keep branding and provider capability decisions in descriptors.
- Keep the notch and usage card consistent by deriving both from the same
  `UsageSnapshot` and `UsageSelection` logic.
- Add controller capabilities through a Core protocol and provider descriptor;
  do not place provider-specific SSH scripts or credential behavior in SwiftUI.
- Controller actions must have a dry-run/confirmation path, bounded timeout,
  structured outcome, and a focused test covering success, refusal, and remote
  transport failure.
- Add focused Core tests for parsing, monitor behavior, account persistence, or
  remote transport changes. Run `make lint` and the relevant tests before
  shipping when the local toolchain supports them.
- Do not commit `.env`, build artifacts, app state, or provider credentials.
