# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

my-cooler is a status-bar-only macOS SwiftUI app for monitoring and controlling Mac fans. It runs as an `LSUIElement` agent — no dock icon, no main window — exposing a `MenuBarExtra` whose label shows the current fan RPM and an on/off indicator, and whose popover holds a "Take control" toggle plus per-fan controls (read-only by default, editable when control is taken).

Target hardware is **Apple Silicon only** (developed on M3 Pro). Intel Macs are out of scope. The app talks to the `AppleSMC` IOKit service directly for fan reads/writes — there is no privileged helper.

The app is **deliberately not sandboxed**. SMC access via `IOServiceOpen` does not work from inside an App Sandbox container on macOS 26, so the entitlement is off. Don't add it back.

Bundle ID: `andrii-kud.my-cooler`. Scheme/target name: `my-cooler` → `my-cooler.app`. Deployment target: macOS 26.5.

## Commands

This project is opened in Xcode and the user expects you to drive builds and tests through the `xcode-tools` MCP server, not the command line:

- **Build** — `BuildProject`. Always run after non-trivial edits.
- **Run all tests** — `RunAllTests` (once a test target exists; none yet).
- **Run a subset** — `GetTestList` to enumerate, then `RunSomeTests` with the identifiers you want.
- **Fast per-file diagnostics** — `XcodeRefreshCodeIssuesInFile` for live compiler errors on a single Swift file without a full build.
- **List warnings/errors visible in Xcode** — `XcodeListNavigatorIssues` (set `severity: "warning"` to surface non-error issues).

If you need shell tools, `gh` lives at `/opt/homebrew/bin/gh`. The user's shell aliases `cat` to `bat`; heredocs piped through `cat` will fail in non-interactive Bash because `bat` isn't on PATH. Avoid `$(cat <<EOF…EOF)` entirely — for commit messages and PR bodies just pass the text directly to `git commit -m "…"` (multi-line strings work fine) or `gh pr create --body "…"`. Don't write the text to a temp file as an intermediate step; that's wasted round-trips and leftover files in `/tmp`.

## Architecture

The app is intentionally small. Expected layout once filled in:

- **`my_coolerApp.swift`** — `@main` `App` whose only `Scene` is a `MenuBarExtra(.window)`. Sets `NSApp.setActivationPolicy(.accessory)` at launch so no dock icon appears. Owns a single `FanController` instance and injects it into the popover.
- **`SMC.swift`** — thin `AppleSMC` IOKit wrapper. Opens an `io_connect_t` via `IOServiceOpen`, sends `SMCParamStruct` payloads through `IOConnectCallStructMethod` selector 2 (`kSMCHandleYPCEvent`). Exposes typed `readFloat(key:) -> Float`, `readUInt8(key:) -> UInt8`, `writeFloat(_:key:)`, `writeUInt8(_:key:)`. Knows about SMC data types `flt `, `fpe2`, `ui8 `.
- **`FanController.swift`** — `@Observable`, `@MainActor`. Polls SMC on a 1 s timer for `FNum`, then per-fan `F{N}Ac` (actual RPM), `F{N}Mn` (min), `F{N}Mx` (max), `F{N}Tg` (target). Owns a `controlEnabled: Bool` flag — when flipped on, captures the current actual RPMs as the initial slider values and writes them back as `F{N}Tg` + `F{N}Md = 1` (manual). When flipped off, writes `F{N}Md = 0` (auto) so the system reclaims control.
- **`PopoverView.swift`** (currently `ContentView.swift`) — the popover UI: status header with current RPMs and a fan-on/off icon, the "Take control" toggle, and per-fan sliders bound to `FanController` targets. Sliders are `.disabled(!controller.controlEnabled)`.

Concurrency: `SMC` calls are synchronous and not thread-safe (the IOKit connection is a single resource). Treat the controller as `@MainActor` and only hit SMC from the main actor's poll task or user-initiated writes. If SMC work ever becomes a perf problem, wrap it in an `actor` rather than spraying locks.

### SMC keys cheat-sheet (Apple Silicon)

| Key   | Type  | Meaning                          |
|-------|-------|----------------------------------|
| `FNum`| `ui8 `| Number of fans                   |
| `F0Ac`| `flt `| Fan 0 actual RPM                 |
| `F0Mn`| `flt `| Fan 0 minimum RPM                |
| `F0Mx`| `flt `| Fan 0 maximum RPM                |
| `F0Tg`| `flt `| Fan 0 target RPM (write)         |
| `F0Md`| `ui8 `| Fan 0 mode (0 = auto, 1 = manual)|

Replace `0` with the fan index. Writing `F{N}Tg` only takes effect when `F{N}Md = 1`.

## Tests

No test target exists yet. When one is added, use **Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`), not XCTest. SMC reads are hardware-dependent and shouldn't be unit-tested directly — gate any test that hits IOKit behind a protocol so the controller can be exercised with a fake.

## Working preferences

- Don't re-enable App Sandbox.
- The user typically wants you to verify changes with a build pass before reporting done.
- **No AI attribution in git artefacts.** Commit messages, PR titles, and PR descriptions must not include any reference to Claude, Anthropic, or the assistant — no `Co-Authored-By: Claude …` trailer, no `🤖 Generated with Claude Code` footer, no other variant. Write the message as if the user authored it themselves.
