//
//  ContentView.swift
//  my-cooler
//
//  Popover content shown from the menu-bar status item.
//

import SwiftUI

struct ContentView: View {
    @Bindable var controller: FanController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if helperIssue != nil {
                helperBanner
            }
            Divider()
            controls
            if !controller.fans.isEmpty {
                Divider()
                fansList
            }
            if let error = controller.lastError {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .frame(width: 280)
    }

    private var header: some View {
        let anySpinning = controller.fans.contains { $0.actual > 0 }
        return HStack(spacing: 10) {
            Image(systemName: anySpinning ? "fan.fill" : "fan")
                .font(.title2)
                .foregroundStyle(
                    anySpinning ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Fans")
                    .font(.headline)
                Text(anySpinning ? "Running" : "Idle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if controller.isUnlocking {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Helper status

    /// A human-readable reason the helper can't be used, or `nil` when it's
    /// healthy (or still being probed right after launch).
    private var helperIssue: String? {
        switch controller.helperStatus {
        case .enabled:
            return controller.helperReachable == false
                ? "The fan-control helper isn't responding. Tap Reinstall Helper to repair it."
                : nil
        case .requiresApproval:
            return "MyCooler needs approval to run its helper. Tap Open Login Items and switch MyCooler on."
        case .notRegistered:
            return "The fan-control helper isn't installed yet. Tap Reinstall Helper to set it up."
        case .failed(let message):
            // "Operation not permitted" means the user disabled MyCooler in
            // Settings — only re-enabling it there can lift that veto.
            if message.localizedCaseInsensitiveContains("not permitted") {
                return "macOS blocked the helper because MyCooler is switched off in Settings. Tap Open Login Items and switch MyCooler on."
            }
            return "Couldn't set up the fan-control helper. Try Reinstall Helper, or enable MyCooler under Login Items.\n(\(message))"
        case .unknown:
            return nil
        }
    }

    private var helperBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(helperIssue ?? "", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                // Always offer Settings: if the user disabled the helper by hand,
                // macOS refuses programmatic re-registration ("Operation not
                // permitted") and only re-enabling it here can lift that veto.
                Button("Open Login Items") {
                    controller.openLoginItemsSettings()
                }
                .controlSize(.small)
                Button("Reinstall Helper") {
                    Task { await controller.reinstallHelper() }
                }
                .controlSize(.small)
                .disabled(controller.isReinstalling)
                if controller.isReinstalling {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Take control", isOn: $controller.controlEnabled)
                .toggleStyle(.switch)
                .disabled(controller.isUnlocking || helperIssue != nil)
            Toggle("Fan enabled", isOn: fanEnabledBinding)
                .toggleStyle(.switch)
                .disabled(!controller.controlEnabled || controller.isUnlocking)
            if controller.controlEnabled && controller.fanEnabled && !controller.isUnlocking {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Speed")
                            .font(.subheadline)
                        Spacer()
                        Text("\(Int(controller.targetRPM)) RPM")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $controller.targetRPM,
                        in: controller.sharedMin...max(
                            controller.sharedMax,
                            controller.sharedMin + 1
                        )
                    )
                }
            }
        }
    }

    /// When `controlEnabled` is off, the toggle visually mirrors whether any
    /// fan is actually spinning so it never lies about the hardware state.
    private var fanEnabledBinding: Binding<Bool> {
        Binding(
            get: { controller.displayFanEnabled },
            set: { controller.fanEnabled = $0 }
        )
    }

    private var fansList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(controller.fans) { fan in
                HStack {
                    Text("Fan \(fan.id + 1)")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(fan.actual)) RPM")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
