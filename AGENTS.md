# Harness Usage

Harness Usage is a macOS app that presents Claude, Codex, Cursor, and opencode
quota in a dark-glass edge notch. It is usage tracking only: it must never act
as a coding agent or write, refresh, copy, or delete a provider's credentials.

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
  descriptors and monitors, the refresh engine, stores, parsing, and remote
  probes. It uses Foundation, Observation, and system libraries only—no AppKit,
  SwiftUI, or third-party UI dependencies.
- `HarnessUsage` is the executable and owns AppKit/SwiftUI presentation: the
  notch, settings and usage windows, login-item integration, and rendering.
  Provider-specific decisions come from Core descriptors and snapshots.

Key folders:

```
Sources/HarnessUsageCore/
  Engine/        refresh scheduling, file watching, diagnostics
  Integrations/  descriptors and provider monitors; Remote/ runs SSH probes
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

- One ring represents one account. Accounts are stored in
  `~/.harness-usage/accounts.json`; `AccountConfig` and `AccountsFile` own that
  format.
- Local accounts may read their own configuration directory. Remote accounts
  use the system `ssh` in batch mode and return only live meter results. Tokens
  are read and used on the remote machine and must never be copied locally or
  placed in a process argument.
- The app may write only its own state under `~/.harness-usage` and its
  `UserDefaults` domains. Preserve this rule in every provider and UI change.
- Cursor and opencode are single-login-per-machine. Keep account-specific
  behavior limited to integrations that support it.

## Change guidelines

- Add a provider through an `Integration` case, a descriptor, a monitor, and
  the registry. Keep branding and provider capability decisions in descriptors.
- Keep the notch and usage card consistent by deriving both from the same
  `UsageSnapshot` and `UsageSelection` logic.
- Add focused Core tests for parsing, monitor behavior, account persistence, or
  remote transport changes. Run `make lint` and the relevant tests before
  shipping when the local toolchain supports them.
- Do not commit `.env`, build artifacts, app state, or provider credentials.
