# Privileged helper plan (v1.0.0)

## Goal

Ship MyCooler so an ordinary user installs the DMG, double-clicks the app,
approves one password prompt, and from then on can take control of fans
from the menu bar without ever opening Terminal — same UX as Macs Fan
Control or TG Pro.

## Why it's needed

On Apple Silicon the `AppleSMC` user client lets `IOServiceOpen` and
reads succeed as any user but rejects writes with
`kIOReturnNotPrivileged` (`0xE00002C1`, `-536870207`) unless the calling
process's EUID is `0`. Today the app only works when launched via
`sudo open /Applications/MyCooler.app`. That isn't a release — it's a
developer demo.

## Architecture

```
┌──────────────────────────────────────┐
│ MyCooler.app           (your user)   │
│  ─ SwiftUI menu-bar popover          │
│  ─ FanController (reads + XPC client)│
│  ─ SMC.swift — reads only            │
│  ─ XPCClient ─────────────┐          │
└───────────────────────────│──────────┘
                            │ NSXPCConnection
                            │ Mach service:
                            │ com.andrii-kud.my-cooler.helper
                            ▼
┌──────────────────────────────────────┐
│ com.andrii-kud.my-cooler.helper      │
│ (on-demand by launchd, EUID 0)       │
│  ─ XPCServer + audit-token gate      │
│  ─ SMCWriter — Ftst, F{N}Md, F{N}Tg  │
└──────────────────────────────────────┘
```

- The helper is a small command-line binary embedded inside
  `MyCooler.app/Contents/MacOS/com.andrii-kud.my-cooler.helper`.
- Its launchd plist is embedded at
  `MyCooler.app/Contents/Library/LaunchDaemons/com.andrii-kud.my-cooler.helper.plist`.
- The main app registers it via
  `SMAppService.daemon(plistName:).register()` on first launch.
- Reads stay in the main app. Only SMC **writes** go through the helper.
- `launchd` spawns the helper on the first XPC connection and reaps it
  shortly after the connection closes, so it does not run in the
  background while MyCooler is quit.

## XPC interface

```swift
// HelperProtocol.swift — shared by both targets
@objc protocol HelperProtocol {
    func ping(reply: @escaping (Bool) -> Void)
    func takeControl(fanCount: Int,
                     initialEnabled: Bool,
                     initialTargetRPM: Float,
                     reply: @escaping (String?) -> Void)
    func setFanRPM(fanIndex: Int,
                   rpm: Float,
                   reply: @escaping (String?) -> Void)
    func releaseControl(fanCount: Int,
                        reply: @escaping (String?) -> Void)
}
```

`reply` is `(String?)` where `nil` means success and a non-nil string is
an error to surface in the popover. The interface is operation-level,
not single-SMC-key-level, so the entire Ftst unlock dance (write `Ftst`,
poll `F{N}Md`, retry `F{N}Md=1`, pin `F{N}Tg`) runs server-side as one
call — no round trips, no half-completed states.

## Code-signing requirements

- Main app and helper must be signed by the **same identity**.
- The helper validates each incoming XPC connection by reading the
  caller's `audit_token_t`, deriving a `SecCode`, and checking it
  against a designated requirement string. Rejected connections are
  invalidated before any exported object is set.
- With a paid Apple Developer Team ID the requirement is:
  `identifier "com.andrii-kud.my-cooler" and anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>"`.
- For "Sign to Run Locally" (no Team ID) we substitute the local
  signing identity's certificate hash. The requirement string is
  baked into the helper at build time via a Run Script phase that
  reads `CODE_SIGN_IDENTITY` and writes the hash into a generated
  Swift constant.
- Sandbox stays off in both targets. Hardened Runtime on for the
  helper.

## File layout after the work

```
my-cooler/
├── my-cooler/                       (main app sources)
│   ├── my_coolerApp.swift
│   ├── ContentView.swift
│   ├── FanController.swift          (reads + XPC client only)
│   ├── SMC.swift                    (reads only)
│   ├── XPCClient.swift              ← new
│   ├── HelperProtocol.swift         ← new (shared)
│   ├── Assets.xcassets/
│   └── AppIcon.icon/
├── helper/                          ← new target source folder
│   ├── main.swift
│   ├── XPCServer.swift
│   ├── SMCWriter.swift              (Ftst unlock + writes)
│   ├── HelperProtocol.swift         (shared sources)
│   ├── helper.plist                 (launchd plist)
│   └── helper.entitlements
└── my-cooler.xcodeproj
```

## Step-by-step plan

### Phase 1 — Xcode scaffolding (your hands on the wheel)

1. **Add a new target** in Xcode: macOS → Command Line Tool, name
   `com.andrii-kud.my-cooler.helper`, language Swift, no tests.
2. Set the helper target's `PRODUCT_BUNDLE_IDENTIFIER` to
   `com.andrii-kud.my-cooler.helper`.
3. On the **main app** target, add a **Copy Files** build phase:
   destination *Executables*, drag the helper product in. This embeds
   the helper binary inside `MyCooler.app/Contents/MacOS/`.
4. Add a second **Copy Files** build phase on the main app: destination
   *Wrapper*, subpath `Contents/Library/LaunchDaemons`. Drag
   `helper/helper.plist` in (we'll create it next).
5. Set both targets to use the same Team / signing identity. Sandbox
   off in both. Hardened Runtime on for the helper.

### Phase 2 — launchd plist and entitlements

6. Create `helper/helper.plist` with:
   - `Label = com.andrii-kud.my-cooler.helper`
   - `BundleProgram = Contents/MacOS/com.andrii-kud.my-cooler.helper`
   - `MachServices = { "com.andrii-kud.my-cooler.helper": true }`
   - `RunAtLoad = false`
   - `AssociatedBundleIdentifiers = ["com.andrii-kud.my-cooler"]`
7. Create `helper/helper.entitlements` — empty `<dict/>` for now; no
   sandbox entitlements, no IOKit allowlist needed because EUID 0 is
   the only thing AppleSMC actually checks.

### Phase 3 — XPC plumbing

8. **`HelperProtocol.swift`** — shared between both targets via Xcode
   "Target Membership" on the single file (synchronized folder groups
   make this easy).
9. **`helper/main.swift`** — open
   `NSXPCListener(machServiceName: "com.andrii-kud.my-cooler.helper")`,
   set delegate, `RunLoop.current.run()`.
10. **`helper/XPCServer.swift`** — `NSXPCListenerDelegate`:
    - `listener(_:shouldAcceptNewConnection:)` reads
      `newConnection.auditToken`, builds a `SecCode` with
      `SecCodeCopyGuestWithAttributes`, calls
      `SecCodeCheckValidity` against the baked-in designated
      requirement.
    - If valid, set `exportedInterface` and `exportedObject`, call
      `newConnection.resume()`, return `true`.
    - Otherwise `newConnection.invalidate()`, return `false`.
11. **`my-cooler/XPCClient.swift`** — wrap
    `NSXPCConnection(machServiceName:, options: .privileged)`. Expose
    typed async methods that call the remote proxy.

### Phase 4 — move SMC writes into the helper

12. Copy `SMC.swift` into `helper/SMCWriter.swift`; strip to write
    methods (`writeFloat`, `writeUInt8`) plus the
    `kIOReturnNotPrivileged`-handling already in there.
13. Move the full Ftst unlock sequence out of
    `FanController.takeControl` into a single helper method
    `SMCWriter.takeControl(fanCount:initialEnabled:initialTargetRPM:)`.
14. Same for `releaseControl` and `applyManual` → `setFanRPM`.
15. `FanController` keeps the poll loop (reads) and its
    `@Observable` state. Its `takeControl` / `releaseControl` /
    `applyManual` become thin XPC calls into `XPCClient`.

### Phase 5 — registration UX

16. On app launch call
    `SMAppService.daemon(plistName: "com.andrii-kud.my-cooler.helper.plist").register()`.
    Inspect the resulting `status`:
    - `.enabled` → ready, no UI needed.
    - `.requiresApproval` → show a popover note ("Approve MyCooler
      Helper in **System Settings → Login Items**") with a button that
      opens `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`.
    - `.notRegistered` / `.notFound` → show an error.
17. *Take control* in the UI is disabled until `XPCClient.ping`
    returns successfully.

### Phase 6 — verification

18. Smoke test: launch helper manually with `launchctl bootstrap` and
    confirm the XPC handshake works.
19. Run the main app, take control, slide, release. Confirm no
    `kIOReturnNotPrivileged`.
20. Quit MyCooler and verify the helper exits within ~10 s
    (`launchctl list | grep my-cooler`).
21. Reboot. Helper should not be running. Launch MyCooler, take
    control — helper spawns on demand.

### Phase 7 — release prep

22. Bump `MARKETING_VERSION` to `1.0.0`,
    `CURRENT_PROJECT_VERSION` to `2`.
23. Update README — remove any sudo notes, add a one-line mention of
    the first-launch password prompt.
24. Build Release, sign, package DMG, tag `v1.0.0`, publish GitHub
    release.

## Open questions / risks

- **"Sign to Run Locally" requirement string**: the local identity
  hash changes per machine. The Run Script that bakes it in needs
  to read `$CODE_SIGN_IDENTITY` from the build environment; for ad-hoc
  signing we may need to special-case to "any locally signed binary
  matching the bundle ID" which is weaker. The right long-term answer
  is a paid Developer account with a stable Team ID.
- **Helper update flow**: when the user installs a new version of
  `MyCooler.app`, the embedded launchd plist may need to be
  re-registered. `SMAppService.register()` is idempotent, so calling
  it on every launch is safe and handles the upgrade case.
- **Concurrent writes**: only one XPC connection should ever be
  active. The audit-token check guarantees only `MyCooler.app` can
  connect, and the main app holds a single long-lived connection.

## What stays the same

- `FanController` stays `@MainActor` and `@Observable`. Its public
  interface to `ContentView` is unchanged — the only difference is
  that mutating methods now await XPC replies instead of calling
  `SMC` directly.
- `SMC.swift` stays in the main app but its write methods are
  unused. We can delete them later for cleanliness.
- The Ftst unlock contract is unchanged. It just runs in the helper.
- Status bar UI, popover, animations, slider behaviour — all
  untouched.
