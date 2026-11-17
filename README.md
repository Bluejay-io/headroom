# Headroom

Your Claude and Codex limits in the macOS menu bar.

Headroom shows how much is left in each limit window (5-hour, weekly, model-specific and monthly), whether you're using it faster than an even pace, and when each window resets. It reads the logins Claude Code and the Codex CLI already saved and never changes them.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/bluejay-io/headroom/main/install.sh | bash
```

Requires macOS 14 or newer, plus [Claude Code](https://claude.com/claude-code) and/or the [Codex CLI](https://github.com/openai/codex) signed in. Run the same command again to update.

The first time Headroom reads Claude Code's login, macOS may ask for Keychain access. Choose **Always Allow**.

## Where the numbers come from

- **Claude:** Claude Code's saved login (Keychain item `Claude Code-credentials`) and the usage endpoint behind Claude Code's `/usage` command. Headroom never refreshes the token, so it can't sign Claude Code out. If the login has expired, open Claude Code once.
- **Codex:** the Codex CLI's local app server (`codex app-server`, `account/rateLimits/read`).

Neither is a documented public API, so a provider update can break a source. Each provider fails on its own and shows why in the panel.

## Build

```sh
./scripts/bundle.sh          # universal dist/Headroom.app, ad-hoc signed
./scripts/make-icon.sh       # regenerate Resources/AppIcon.icns
```

Pushing a `v*` tag builds the app on GitHub Actions and publishes `Headroom.zip` to Releases, which is what `install.sh` downloads.
