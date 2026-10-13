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
- **Indicator**: when a lookup is blocked, the menu bar icon turns into a red hand
  and shows the blocked domain for a couple of seconds.
- **First use**: the first time you turn blocking on, macOS asks for an
  administrator password to install Bouncer's DNS helper. After that, toggling
  never prompts. The helper is replaced (one more prompt) when a new build ships a
  changed helper.

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
bouncer on | off | toggle            # blocking (first `on` may show the admin prompt)
bouncer status                       # phase, rule count, helper state, hotkey
bouncer rules add reddit.com
bouncer rules add '/(^|\.)tiktok\.com$/'
bouncer rules add old.reddit.com --action allow
bouncer rules list
bouncer rules update old.reddit.com --enabled false   # ID, ID prefix, or exact pattern
bouncer rules remove 71BE9CD1
bouncer test www.reddit.com          # which rule (if any) applies
bouncer activity --limit 10          # recently blocked domains
bouncer helper install | helper uninstall --force true
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
| `block-bypass-canaries` | `true` | While blocking, tell Firefox DoH and iCloud Private Relay to use system DNS |
| `upstream-dns` | *(empty)* | Comma-separated resolvers; empty follows the network's DHCP/RA servers |

## How it works

Domain matching (especially regex) can't be done with `/etc/hosts`, so Bouncer
filters DNS itself:

1. A root LaunchDaemon (`llc.wvlen.Bouncer.helper`, installed to
   `/Library/PrivilegedHelperTools`) runs a resolver on `127.0.0.1:53`.
2. Turning blocking on points every network service's DNS at `127.0.0.1` (after
   saving the originals to `/Library/Application Support/Bouncer/dns-backup.json`)
   and flushes the DNS cache. Blocked names get NXDOMAIN with a zero TTL; everything
   else is relayed unchanged (UDP and TCP) to the network's real resolvers.
3. Blocking lives exactly as long as the app's connection to the helper. Quit,
   crash, force-quit, `launchctl bootout`, or SIGTERM all restore the saved DNS
   settings; a backup left by a power loss is restored at the next boot.
4. The helper's control socket is mode 0600 for the installing user, and it also
   checks that the peer is Bouncer signed by the same Team ID as the helper.

### Limits

- Sites already open may keep working until the browser reconnects: existing
  connections don't do new DNS lookups. Reload, or restart the browser.
- **iCloud Private Relay bypasses Bouncer.** While Private Relay is on, macOS sends
  every app's DNS through Apple's encrypted relay and ignores the configured DNS
  server. The canary answer only matters when Private Relay re-evaluates a network
  (e.g. on joining it), so in practice turn Private Relay off for the networks where
  you want blocking: System Settings › Wi-Fi › Details… › iCloud Private Relay.
  Bouncer detects this: after turning on, it resolves a self-test name
  (`<nonce>.selftest.bouncer.internal`) through the system resolver, and if the answer
  didn't come from its filter, the menu shows **Bypassed** with an orange warning and
  `bouncer status` reports `BYPASSED` (`dnsVerified: false` in JSON).
- Browsers with a hard-coded DNS-over-HTTPS provider (Chrome/Edge "Secure DNS"
  set to a specific provider, Firefox "Max Protection") bypass system DNS. Firefox's
  default mode is handled by the canary setting above.
- VPNs that push their own DNS resolvers can take precedence over Bouncer.
- Verify while blocking with `scutil --dns | grep nameserver` (expect `127.0.0.1`).
- Helper logs: `/var/log/llc.wvlen.Bouncer.helper.log`.

## Development

```sh
mise install
scripts/generate-api.sh      # after editing API/openapi.yaml
scripts/verify.sh            # the full gate: generation, boundaries, tests, scenarios
scripts/try-signed.sh        # Developer ID build → /Applications, relaunch
```

`project.yml` is the Xcode source of truth; set `DEVELOPMENT_TEAM` in the ignored
`Configuration/Local.xcconfig`. Targets:

- `Sources/Filter` — rule matching, DNS packets, helper wire protocol (app + helper)
- `Sources/Helper` — the root daemon: control socket, DNS server, system DNS swap
- `Sources/Core` — `BlockingStore`, `BouncerService` (every operation), helper client/installer, TOML settings
- `Sources/App` — status item, popover, settings window, Carbon hotkey
- `Sources/CLI` — generated commands plus renderers in `Custom/`

Run the helper unprivileged for experiments (no system DNS changes):

```sh
build/Build/Products/Debug/BouncerHelper --owner-uid $(id -u) --no-system-dns \
  --dns-port 5399 --socket /tmp/bouncer.sock --state-dir /tmp/bouncer-state --allow-unsigned-clients
dig @127.0.0.1 -p 5399 example.com
```

Follow [docs/interface-consistency.md](docs/interface-consistency.md) when adding a
feature: contract in `API/openapi.yaml`, implementation in `BouncerService`, a
scenario in `TestsSupport/AppScenarios.swift`, UI calling the same service.
