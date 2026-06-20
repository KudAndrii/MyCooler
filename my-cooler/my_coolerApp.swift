//
//  my_coolerApp.swift
//  my-cooler
//

import SwiftUI
import AppKit
import ServiceManagement
import OSLog

private let appLog = Logger(subsystem: "com.andrii-kud.my-cooler", category: "App")

@main
struct my_coolerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // No SwiftUI Scene — the AppDelegate owns the status item and popover.
        // A `Settings` scene with `EmptyView` keeps the App protocol happy
        // without surfacing any window.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = FanController()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerHelper()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            let hosting = NSHostingView(
                rootView: StatusBarFanIcon(controller: controller)
            )
            hosting.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                hosting.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        }
        statusItem = item

        let hostingController = NSHostingController(
            rootView: ContentView(controller: controller)
        )
        hostingController.sizingOptions = .preferredContentSize

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = hostingController
        popover = pop
    }

    // MARK: - Helper registration

    private func registerHelper() {
        let service = SMAppService.daemon(
            plistName: "com.andrii-kud.my-cooler.helper.plist"
        )
        do {
            try service.register()
            controller.helperStatus = mapStatus(service.status)
            appLog.info("Helper registered: status \(String(describing: service.status), privacy: .public)")
        } catch {
            let message = "Helper registration failed: \(error.localizedDescription)"
            appLog.error("\(message, privacy: .public)")
            controller.helperStatus = .failed(message)
        }
    }

    private func mapStatus(_ status: SMAppService.Status) -> FanController.HelperStatus {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .failed("Helper not found in app bundle")
        @unknown default: return .failed("Unknown helper status (\(status.rawValue))")
        }
    }

    // MARK: - Click handling

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Temporarily attach the menu so AppKit pops it on the next click;
        // detach right after so left-click goes back to our action.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private struct StatusBarFanIcon: View {
    let controller: FanController

    private var spinning: Bool {
        // When the user has explicitly disabled the fan in manual mode, mirror
        // intent rather than hardware so transient ramp-ups during the mode
        // flip don't blip the status bar.
        if controller.controlEnabled && !controller.fanEnabled { return false }
        return (controller.fans.first?.actual ?? 0) > 0
    }

    var body: some View {
        Image(systemName: "fan.fill")
            .symbolEffect(.rotate.clockwise, options: .repeat(.continuous), isActive: spinning)
            .accessibilityLabel(spinning ? "Fan running" : "Fan idle")
    }
}
