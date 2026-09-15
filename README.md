# Harness Monitor

A macOS app that shows how much Claude and Codex quota you have left. A dark-glass notch sits on the
right screen edge with one ring per account. Hover or click a ring to see its usage card: the 5-hour
and weekly windows, when they reset, and today's token estimate.

It reads the accounts already signed in through Claude Code (`~/.claude`, `~/.claude-<name>`) and
Codex (`~/.codex`, `~/.codex-<name>`), and it can connect more subscriptions from Settings. It never
writes to those CLI credentials. Its own state lives in `~/.harness-usage`.

## Requirements

macOS 14 or later, and a Swift 6 toolchain (Xcode 16 or newer) to build.

## Build

```
make dev       # debug build, runs in the foreground
make mock      # run against the fixtures in MockData/, no accounts needed
make test      # run the test suite
make install   # release build, installed into /Applications
```

`make app` builds the signed `.app` and `.dmg`. Signing and notarization read `.env` (`make env`
creates it from `.env.example`). Without those credentials the build falls back to an ad-hoc
signature.

## License

MIT. See [LICENSE](LICENSE).

## Credits

The notch design and ideas come from [Codenotch](https://github.com/vinzdg/codenotch) by
[@vinzdg](https://github.com/vinzdg).
