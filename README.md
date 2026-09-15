# Harness Usage

A macOS app that shows how much of each AI coding harness's quota you have left: Claude, Codex, Cursor and
opencode. It sits as a dark-glass notch on the right screen edge, with one ring per provider and a usage card
on hover or click.

## Requirements

macOS 14 or later and a Swift 6 toolchain (Xcode 16 or newer).

## Build and run

```
make dev         # debug build, run in the foreground (Ctrl-C to quit)
make mock        # run against MockData/ fixtures, no real harnesses needed
make test        # swift test
make app         # release: format + lint + test + universal build + .app + sign + dmg
make install     # make app, then install into /Applications and relaunch
make uninstall   # remove the installed app
```

`make app` signs ad-hoc and skips notarization unless you put signing credentials in `.env` (`make env` creates
it from `.env.example`).

The app only reads harness credentials. It never writes, refreshes or deletes them, and its own state lives in
`~/.harness-usage`.

If you only have Command Line Tools and no Xcode, two steps of the release pipeline cannot run: `swift test`
(CLT ships an incomplete swift-testing — no `_Testing_Foundation`) and the universal build (it goes through
xcbuild). `SKIP_TESTS=1 NATIVE_ONLY=1 ./build.sh` gets you a working local install; the result is arm64-only and
has had nothing but the compiler and the linter look at it.

## Accounts

One ring per **account**, not per harness — a harness signed into two accounts gets two rings. The tracked
accounts live in `~/.harness-usage/accounts.json`, seeded on first launch with one local account per harness
(exactly the shape the app had before accounts existed). Edit it and relaunch to add, remove or rename one.

```json
{
  "accounts": [
    { "harness": "claude", "label": "Personal" },
    { "harness": "claude", "account": "work", "label": "Work",
      "host": "sunny-new",  "configDir": "~/.claude-a" }
  ]
}
```

| field | meaning |
| --- | --- |
| `harness` | `claude`, `codex`, `cursor` or `opencode` |
| `account` | stable slug, unique per harness. Omit for this Mac's default login. Changing it resets that ring's settings. |
| `label` | shown next to the brand mark (`Claude · Work`). Ignored while a harness has only one account. |
| `host` | an alias from your `~/.ssh/config`, for an account signed in on another machine. Omit for this Mac. |
| `configDir` | the harness's config directory. Omit for the default. `~` expands on the account's *own* machine. |

A **local** account is read exactly as the single-account app always did, from its own config directory:
`CLAUDE_CONFIG_DIR` for Claude, `CODEX_HOME` for Codex. Claude Code names the Keychain item for a non-default
config directory `Claude Code-credentials-<first 8 hex of sha256(configDir)>`, and the app reproduces that, so
two Claude logins on one Mac stay separate. Each account gets its own cache and parse index under
`~/.harness-usage/<harness>-<account>/`.

A **remote** account reports its live meters only. The usage query runs over `ssh` *on that machine* and only
the resulting percentages come back — the token is read, used and discarded there, and never crosses to this
Mac. It never reaches an argument list either: `ps` on the remote box shows no credential. The local token and
cost estimates have no remote equivalent, because they mean reading a week of transcripts.

Remote reads use the system `ssh` with your own config, in `BatchMode` — so a host that would prompt for a
passphrase fails rather than hanging a background refresh on a dialog nobody is looking at. Set up key auth for
any host you add. Cursor and opencode are single-login-per-machine and ignore `account`/`configDir`.

### Signing a second account in

Both CLIs key a login to a config directory, so a second account means a second directory. Codex will not
create its own — `CODEX_HOME` pointing at a path that does not exist fails with `Error loading configuration` —
and on a headless box there is no browser to redirect back to, so the login needs the device flow:

```
mkdir -p ~/.codex-2
CODEX_HOME=~/.codex-2 codex login --device-auth

mkdir -p ~/.claude-work
CLAUDE_CONFIG_DIR=~/.claude-work claude       # /login, then pick the account
```

Then point an account entry at that directory. The ring picks the login up on its next refresh (a 300s floor),
or immediately via **Update now**.
