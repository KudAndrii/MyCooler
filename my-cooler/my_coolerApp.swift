//
//  my_coolerApp.swift
//  my-cooler
//

import SwiftUI
import AppKit

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
    private var labelTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeft
        }
        statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 280, height: 260)
        pop.contentViewController = NSHostingController(
            rootView: ContentView(controller: controller)
        )
        popover = pop

        startLabelUpdates()
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

    // MARK: - Status bar label

    private func startLabelUpdates() {
        labelTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshLabel()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refreshLabel() {
        guard let button = statusItem?.button else { return }
        // When the user has explicitly disabled the fan in manual mode, mirror
        // intent rather than hardware so transient ramp-ups during the mode
        // flip don't blip the status bar.
        let primary: Float
        if controller.controlEnabled && !controller.fanEnabled {
            primary = 0
        } else {
            primary = controller.fans.first?.actual ?? 0
        }
        let spinning = primary > 0
        button.image = NSImage(
            systemSymbolName: spinning ? "fan.fill" : "fan",
            accessibilityDescription: spinning ? "Fan running" : "Fan idle"
        )
        button.title = controller.fans.isEmpty ? "" : " \(Int(primary))"
    }
}
