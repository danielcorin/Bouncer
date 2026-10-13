# Bouncer

A menu bar app that blocks domains system-wide (every browser and app), with
plain-domain and regex rules, a toggle, a global hotkey, and a `bouncer` CLI.
When Bouncer quits — or crashes, or is force-quit — every block is removed.

## Using it

- **Menu bar**: click the shield to open the menu: the blocking switch, add/remove
  rules, and recently blocked domains. Option-click the shield to toggle blocking
  directly. Double-click a rule to edit it; right-click for more.
- **Hotkey**: ⌃⌥⌘B toggles blocking from anywhere (change it in Settings, or
  `bouncer config set hotkey --value "shift+cmd+f12"`).
- **About**: the ⓘ button in the menu (or Settings › About) shows the version, how
  blocking works, and the shortcuts.
- **Indicator**: when a lookup is blocked, the menu bar icon turns into a red hand
  and shows the blocked domain for a couple of seconds.
- **First use**: the first time you turn blocking on, macOS asks you to allow
  Bouncer's VPN configuration. After that, toggling never prompts. No administrator
  password is needed, and nothing outside the tunnel is changed.

### Rules

| You type | Kind | Matches |
| --- | --- | --- |
| `reddit.com` | domain | `reddit.com` and every subdomain (`old.reddit.com`, …) |
| `*.reddit.com` | domain | subdomains only |
| `https://www.reddit.com/r/x` | domain | reduced to `www.reddit.com` |
| `/news\|tiktok/` | regex | any domain containing `news` or `tiktok` |
| `/^x\.com$/` | regex | exactly `x.com` |

Regexes are case-insensitive and unanchored, tested against the full lowercase
domain (no scheme, path, or trailing dot). **Allow rules beat block rules**, so
`/.*/` (block) plus a few allow rules is an allowlist-only mode.

### CLI

Install it from **Settings → Command line** (symlinks `~/.local/bin/bouncer`).
If the app isn't running, the CLI launches it.

```sh
bouncer on | off | toggle            # blocking (first `on` asks you to allow the VPN configuration)
bouncer status                       # phase, verification, rule count, tunnel state, hotkey
bouncer rules add reddit.com
bouncer rules add '/(^|\.)tiktok\.com$/'
bouncer rules add old.reddit.com --action allow
bouncer rules list
bouncer rules update old.reddit.com --enabled false   # ID, ID prefix, or exact pattern
bouncer rules remove 71BE9CD1
bouncer test www.reddit.com          # which rule (if any) applies
bouncer activity --limit 10          # recently blocked domains
bouncer tunnel install | tunnel remove --force
bouncer config list --all true       # settings live in ~/.config/bouncer/config.toml
bouncer quit                         # removes blocks
```

Every command accepts `--json`. Results go to stdout, errors to stderr as
`{error:{code,message}}`; exit codes are 0 success, 1 operation failure,
2 invalid invocation, 3 app unavailable.

### Settings (`config.toml`)

| Key | Default | Meaning |
| --- | --- | --- |
| `hotkey` | `ctrl+option+cmd+b` | Global toggle; empty disables it |
| `enable-on-launch` | `false` | Turn blocking on at launch |
| `flash-indicator` | `true` | Flash the menu bar on each block |
| `block-bypass-canaries` | `true` | While blocking, tell Firefox's DNS-over-HTTPS to use system DNS |
| `upstream-dns` | *(empty)* | Comma-separated resolvers; empty follows the network's DHCP/RA servers |

## How it works

Domain matching (especially regex) can't be done with `/etc/hosts`, and simply
changing the Mac's DNS server is bypassed by iCloud Private Relay, which encrypts
every app's DNS. So Bouncer filters DNS inside a Network Extension:

1. Turning blocking on starts **Bouncer's packet tunnel** (`Sources/Tunnel`), which
   appears as "Bouncer" in System Settings › VPN. It claims a single route — a
   virtual resolver at `198.18.0.1` — and registers it as the DNS server for every
   domain. All other traffic keeps using the normal network.
2. macOS gives a VPN's DNS settings priority over Private Relay's encrypted DNS, so
   every resolver lookup reaches the tunnel whether or not Private Relay is on
   (Private Relay itself stays connected). Chromium-based browsers' built-in DNS
   clients also follow the system DNS configuration to the tunnel.
3. Blocked names get NXDOMAIN with a zero TTL; everything else is relayed unchanged
   to the network's real resolvers (re-detected every few seconds, so switching
   networks works). Truncated answers are re-fetched over TCP.
4. After turning on, Bouncer resolves a self-test name only the tunnel knows; the
   menu shows **Bypassed** and `bouncer status` reports `BYPASSED` if it doesn't
   come back.
5. Blocks never outlive the app: quitting stops the tunnel, and the app sends the
   tunnel a heartbeat every half second — if it stops (crash, force quit), the
   tunnel shuts itself down within about 12 seconds.

### Limits

- Sites already open may keep working until the browser reconnects: existing
  connections don't do new DNS lookups. Reload, or restart the browser.
- macOS runs one VPN at a time. Starting another VPN disconnects Bouncer's tunnel;
  Bouncer then reports that blocking stopped rather than fighting it.
- Safari with iCloud Private Relay carries page loads inside the relay; whether the
  tunnel's DNS still applies there hasn't been verified yet.
- Browsers with a hard-coded DNS-over-HTTPS provider (Chrome/Edge "Secure DNS" set
  to a specific provider, Firefox "Max Protection") bypass system DNS.
- The tunnel is a development-signed app extension (personal use). Distributing
  Bouncer would mean moving it to a Developer ID system extension (notarized, with
  a one-time approval in System Settings).
- Tunnel logs: `log show --last 10m --predicate 'subsystem == "llc.wvlen.Bouncer.Tunnel"'`.

## Development

```sh
mise install
scripts/generate-api.sh      # after editing API/openapi.yaml
scripts/verify.sh            # the full gate: generation, boundaries, tests, scenarios
scripts/try-dev.sh           # development-signed build (provisions the tunnel) → /Applications
swift scripts/generate-app-icon.swift  # re-render the icon (AppIcon.icon glyph + legacy PNGs)
```

`project.yml` is the Xcode source of truth; set `DEVELOPMENT_TEAM` in the ignored
`Configuration/Local.xcconfig`. Targets:

- `Sources/Filter` — rule matching, DNS packets, the filter engine, tunnel wire protocol (app + tunnel)
- `Sources/Tunnel` — the packet tunnel extension: virtual resolver, forwarding, heartbeat watchdog
- `Sources/Core` — `BlockingStore`, `BouncerService` (every operation), `TunnelFilterBackend`, TOML settings
- `Sources/App` — status item, popover, settings window, Carbon hotkey
- `Sources/CLI` — generated commands plus renderers in `Custom/`

Follow [docs/interface-consistency.md](docs/interface-consistency.md) when adding a
feature: contract in `API/openapi.yaml`, implementation in `BouncerService`, a
scenario in `TestsSupport/AppScenarios.swift`, UI calling the same service.
