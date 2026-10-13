# Tunnel proof of concept

Question: can Bouncer insert itself so blocks apply whether or not iCloud Private
Relay is on? Answer so far: **yes, with a Network Extension packet tunnel that claims
only DNS.** macOS sends every resolver query (including the ones Private Relay
would otherwise carry) to the tunnel's virtual DNS server, 198.18.0.1, and normal
traffic keeps using the real network.

Build and use (development-signed; Xcode provisions the NE capability):

```sh
mise exec -- xcodegen generate
xcodebuild -project BouncerTunnelPOC.xcodeproj -scheme BouncerTunnelPOC -derivedDataPath build -allowProvisioningUpdates build
ditto build/Build/Products/Debug/BouncerTunnelPOC.app /Applications/BouncerTunnelPOC.app
POC=/Applications/BouncerTunnelPOC.app/Contents/MacOS/BouncerTunnelPOC
$POC install --mode dns-only   # first time: macOS asks to allow the VPN configuration
$POC start | stats | stop | remove
```

Rules are hard-coded: block `ycombinator.com` (domain) and `/tiktok/` (regex).

## Results (2026-10-13, macOS 26, Private Relay on, Helium default browser)

| State | Relay up | Self-test via system resolver | System/curl HN | Headless Helium HN | example.com |
| --- | --- | --- | --- | --- | --- |
| Tunnel off | yes | no answer | resolves, 200 | loads | 200 |
| `dns-only` | yes | **127.0.0.53 (tunnel)** | **blocked** | **blocked** | 200 |
| `nominal-default` | yes | 127.0.0.53 | blocked | blocked | 200, but 34 non-DNS packets were swallowed |
| After stop | yes | no answer | resolves, 200 | loads | 200 |

- The tunnel saw DNS from every app (Apple services, 1Password, Spotify, …), so it is
  the system's resolver while up; Private Relay's DNS path defers to it.
- `nominal-default` adds risk (traffic leaks into the tunnel) for no extra coverage.
- Teardown is immediate: stopping the tunnel restores the previous resolvers.
- Not yet verified: Safari (its page loads travel inside Private Relay), the user's
  real Helium profile, and Firefox.
