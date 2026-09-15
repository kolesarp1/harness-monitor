# Harness Usage — dev entry points. `make <target>` from the project root.
# build.sh stays as the full release pipeline; this is the thin ergonomic layer.
# Signing / notary / version config lives in .env (copy .env.example → .env); build.sh sources it.

.PHONY: build dev mock test lint app release install uninstall clean clean-dev env

LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
APP = /Applications/Harness Usage.app

# Compile only.
build:
	swift build

# Build (debug) and run in the foreground — logs go to the terminal, Ctrl-C to quit.
dev: build
	.build/debug/HarnessUsage

# Mock mode: run with fake fixture data (no real harnesses needed). Good for screenshots + UI dev.
mock: build
	.build/debug/HarnessUsage --mock

# Run the Swift Testing suite.
test:
	swift test

# Lint only (no build).
lint:
	@swift format lint --strict --recursive Sources Tests

# Full release pipeline: format + lint + test + universal build + .app bundle + sign + DMG.
app:
	./build.sh

release: app

# Build and install into /Applications, then relaunch. This is the only way launch-at-login works:
# LoginItem.setEnabled deliberately registers nothing unless the bundle sits under /Applications, so
# a build/ or .build/ copy can never leave a stale login item behind.
#
# Killing the running app is safe and loses nothing durable. The usage cache and SQLite parse index stay
# in ~/.harness-usage. The bundle is removed before copying so stale files from an older build can't
# survive.
#
# Relaunch by path, never `open -a`: the name also matches the freshly registered build/ copy, and
# LaunchServices may pick that one, leaving the wrong binary running. That copy is also why two
# "Harness Usage" entries can show up in Spotlight and the Applications list, so it is unregistered and
# deleted here. It has just been installed to /Applications, and the DMG beside it was already built
# from it.
install: app
	@echo "==> installing (quits the running app; cached usage is untouched)"
	pkill -x HarnessUsage || true
	rm -rf "$(APP)"
	ditto "build/Harness Usage.app" "$(APP)"
	codesign --verify --deep --strict "$(APP)"
	@echo "==> dropping the build copy so only /Applications is listed"
	@$(LSREGISTER) -u "$(CURDIR)/build/Harness Usage.app" || true
	rm -rf "build/Harness Usage.app"
	open "$(APP)"

# Remove the installed app. Leaves ~/.harness-usage and your preferences alone;
# `make clean-dev` is the one that wipes those.
uninstall:
	@if [ -x "$(APP)/Contents/MacOS/HarnessUsage" ]; then \
		"$(APP)/Contents/MacOS/HarnessUsage" --no-login || exit $$?; \
	fi
	pkill -x HarnessUsage || true
	@$(LSREGISTER) -u "$(APP)" || true
	rm -rf "$(APP)"
	@echo "==> removed $(APP) (preferences and ~/.harness-usage kept)"

# Remove build artifacts (debug + release).
clean:
	rm -rf .build build

# Wipe ALL state (UserDefaults + ~/.harness-usage + .build), rebuild from scratch, and launch
# detached. This simulates a first-time user launch. Kills any running dev instance first.
# Both defaults domains are reset: an unbundled dev build persists under its process name, the
# installed bundle under its bundle id.
clean-dev:
	pkill -x HarnessUsage 2>/dev/null || true
	sleep 0.5
	defaults delete HarnessUsage 2>/dev/null || true
	defaults delete com.mikeben.harness-widget 2>/dev/null || true
	rm -rf ~/.harness-usage
	rm -rf .build
	swift build
	nohup .build/debug/HarnessUsage > /dev/null 2>&1 &

# Create .env from the template if it doesn't exist yet.
env:
	@[ -f .env ] && echo ".env already exists" || { cp .env.example .env && echo "created .env from .env.example — fill in your values"; }
