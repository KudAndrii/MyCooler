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

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Take control", isOn: $controller.controlEnabled)
                .toggleStyle(.switch)
                .disabled(controller.isUnlocking)
            Toggle("Fan enabled", isOn: fanEnabledBinding)
                .toggleStyle(.switch)
                .disabled(!controller.controlEnabled || controller.isUnlocking)
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
                .disabled(!(controller.controlEnabled && controller.fanEnabled) || controller.isUnlocking)
                HStack {
                    Text("\(Int(controller.sharedMin))")
                    Spacer()
                    Text("\(Int(controller.sharedMax))")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
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
