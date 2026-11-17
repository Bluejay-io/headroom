# Headroom

Your Claude and Codex limits in the macOS menu bar.

Headroom shows how much is left in each limit window (5-hour, weekly, model-specific and monthly), whether you're using it faster than an even pace, and when each window resets. It reads the logins Claude Code and the Codex CLI already saved and never changes them.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/bluejay-io/headroom/main/install.sh | bash
```

Requires macOS 14 or newer, plus [Claude Code](https://claude.com/claude-code) and/or the [Codex CLI](https://github.com/openai/codex) signed in. From 0.3.0 on, Headroom checks GitHub for new releases and shows an **Update** button in the panel. Older versions update by running the same command again.

The first time Headroom reads Claude Code's login, macOS may ask for Keychain access. Choose **Always Allow**.

## Resets

Claude and Codex sometimes grant free limit resets. Headroom shows how many you have next to each provider, what each one refills and when it expires. **Use…** opens a confirmation first, and nothing is spent until you press **Use reset**. Each attempt carries a one-time request ID, so retrying after a network error can't spend a second reset.

Spending a reset is the only thing Headroom ever changes on your account.

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
