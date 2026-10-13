---
name: try-it
description: Build the current macOS app project and install it to /Applications so the user can try it as a real app — replaces any running copy and relaunches it. Use when the user wants to try, run, or install a locally built Mac app, or after app changes that should land on the machine. Follows the Reco install conventions (graceful quit, staged atomic replace in /Applications, launch verification). For notarized public releases use the project's publish-release.sh instead.
---

# Try it (install a local macOS app build to /Applications)

Build the app in the current project directory and install it at
`/Applications/<App>.app`, the canonical place for apps the user actually
uses (Dock, Spotlight, Launch Services, and drag-onto-icon all behave normally).

## Steps

1. From the project root, run the installer bundled with this project:

   ```sh
   .agents/skills/try-it/scripts/try-it.sh
   ```

   Options: `--scheme NAME`, `--configuration NAME` (default Release),
   `--project PATH`, `--app PATH` (skip the build, install an existing `.app`),
   and `--skip-launch`.

2. The script:
   - generates the Xcode project first when only `project.yml` exists (XcodeGen);
   - builds with a scrubbed environment and ad-hoc signing for local use;
   - quits a running instance gracefully (AppleScript quit, then SIGTERM);
   - stages the new copy inside `/Applications`, atomically replaces the old
     app, launches it, and verifies it is running.

3. Confirm to the user that the app launched. Remove stale copies outside
   `/Applications` only when their exact paths are known and the user requested
   installation or replacement.

## Notes

- Ad-hoc signed builds run locally but are not distributable; use
  `scripts/publish-release.sh` for notarized releases.
- If the app owns a companion CLI symlink, recheck that it targets
  `<App>.app/Contents/Helpers/<cli>` under `/Applications` after installation.
