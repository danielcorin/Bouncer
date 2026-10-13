# Bouncer agent guide

Use `project.yml` as the only Xcode source of truth and regenerate with
`mise exec -- xcodegen generate`. Keep domain/persistence and generated API types
in `Sources/Shared`, Mac-only socket/TOML code in `Sources/Core`, and platform UI
in `Sources/App` or `Sources/Mobile`.

`API/openapi.yaml` is the public operation contract. Run `scripts/generate-api.sh`
after changing it, implement the required Swift service method, and add meaningful
GUI/CLI/HTTP verification. Custom behavior belongs in `Sources/CLI/Custom` Swift.
Never edit generated files or add a parallel handwritten route/command catalog.
Read [Keeping the UI, CLI, and HTTP API consistent](docs/interface-consistency.md)
when adding capabilities or changing UI/service boundaries. Apply its generic
feature-authoring loop to this app's domain.

The app owns mutable domain data. Both transports use the same service; the CLI
never opens a second mutable store. Commands are non-interactive, accept `--json`,
print results to stdout and errors to stderr, and require `--force` for destructive
actions. Use the shared TOML store for all non-secret runtime settings; no
`UserDefaults` or `@AppStorage`. There is no HTTP server.

Bouncer-specific: blocking is done by the root helper (`Sources/Helper`), which runs
a DNS filter on 127.0.0.1:53 and swaps every network service's DNS. Invariant: blocks
must never outlive the app — the helper tears down when the controlling connection
closes, on SIGTERM, and restores any leftover backup at startup. Keep that true for
any change. `Sources/Filter` is compiled into both Core and the helper; keep it free
of app dependencies. Never run `bouncer on` or install the helper without the user:
it shows an admin password prompt and changes system DNS. Test DNS behavior with the
unprivileged helper mode in README.md, and `InMemoryFilterBackend` in tests.

Run `scripts/verify.sh` before handoff; CI executes the same deterministic gate.
UI persistence writes must use generated operations via Swift services. Add a
meaningful Swift scenario with every operation; exact declared coverage and all
three execution paths are enforced by the test runner. Use `*ReadAccess` protocols
for public read surfaces; keep underlying mutation methods internal to Core and
extend compiler probes for new stores. Test native action delegation and read-model
refresh after CLI/API mutations. Presentation state can stay local to views.

Verify the bundled helper, graceful shutdown, and no coverage instrumentation before
installation or release. CloudKit checks require real provisioning and the same
long-lived container on both platforms. Report unavailable CI enforcement or device
verification explicitly; the gate uses compiler results and assertions, with no
LLM pass/fail step.
