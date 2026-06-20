//
//  FanController.swift
//  my-cooler
//

import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.andrii-kud.my-cooler", category: "FanController")

@MainActor
@Observable
final class FanController {
    struct Fan: Identifiable, Equatable {
        let id: Int
        var actual: Float = 0
        var minRPM: Float = 0
        var maxRPM: Float = 0
    }

    enum HelperStatus: Equatable {
        case unknown
        case enabled
        case requiresApproval
        case notRegistered
        case failed(String)
    }

    private(set) var fans: [Fan] = []
    private(set) var readError: String?
    private(set) var writeError: String?
    private(set) var isUnlocking: Bool = false
    var helperStatus: HelperStatus = .unknown
    var lastError: String? { writeError ?? readError }

    var sharedMin: Float { fans.map(\.minRPM).max() ?? 0 }
    var sharedMax: Float { fans.map(\.maxRPM).min() ?? 6000 }

    /// Reflects whether any fan is currently spinning when `controlEnabled` is
    /// off; mirrors user intent when `controlEnabled` is on.
    var displayFanEnabled: Bool {
        controlEnabled ? fanEnabled : fans.contains { $0.actual > 0 }
    }

    var controlEnabled: Bool = false {
        didSet {
            guard oldValue != controlEnabled else { return }
            if controlEnabled {
                Task { await takeControl() }
            } else {
                Task { await releaseControl() }
            }
        }
    }

    var fanEnabled: Bool = false {
        didSet {
            guard oldValue != fanEnabled, controlEnabled, !suppressWrites else { return }
            Task { await applyManual() }
        }
    }

    var targetRPM: Float = 0 {
        didSet {
            guard oldValue != targetRPM, controlEnabled, fanEnabled, !suppressWrites else { return }
            Task { await applyManual() }
        }
    }

    private let smc: SMC?
    private let xpc = XPCClient()
    private var pollTask: Task<Void, Never>?
    private var suppressWrites = false

    init() {
        do {
            self.smc = try SMC()
        } catch let error as SMCError {
            self.smc = nil
            log.error("SMC init failed: \(String(describing: error), privacy: .public)")
            self.writeError = "SMC init: \(error)"
        } catch {
            self.smc = nil
            log.error("SMC init failed: \(String(describing: error), privacy: .public)")
            self.writeError = "SMC init: \(error)"
        }
        startPolling()
    }

    func clearError() {
        readError = nil
        writeError = nil
    }

    // MARK: - Take / release control via privileged helper

    private func takeControl() async {
        isUnlocking = true
        defer { isUnlocking = false }
        writeError = nil

        guard !fans.isEmpty else { return }

        // Decide initial state before the unlock so the helper can pin
        // the target immediately — otherwise the SMC briefly ramps to
        // its default RPM between F{N}Md=1 and the first F{N}Tg write.
        let initialEnabled = fans.contains { $0.actual > 0 }
        let avgActual = fans.map(\.actual).reduce(0, +) / Float(max(fans.count, 1))
        let initialTarget: Float = initialEnabled ? clampedTarget(avgActual) : 0

        if let error = await xpc.takeControl(fanCount: fans.count,
                                             initialEnabled: initialEnabled,
                                             initialTargetRPM: initialTarget) {
            report(write: error)
            return
        }

        suppressWrites = true
        fanEnabled = initialEnabled
        targetRPM = clampedTarget(initialEnabled ? avgActual : sharedMin)
        suppressWrites = false

        await applyManual()
    }

    private func releaseControl() async {
        let count = fans.count
        if let error = await xpc.releaseControl(fanCount: count) {
            report(write: error)
        } else {
            writeError = nil
        }
    }

    private func applyManual() async {
        guard controlEnabled else { return }
        let value: Float = fanEnabled ? clampedTarget(targetRPM) : 0
        var firstError: String?
        for i in fans.indices {
            if let error = await xpc.setFanRPM(fanIndex: i, rpm: value) {
                if firstError == nil { firstError = "F\(i)Tg write: \(error)" }
            }
        }
        if let firstError {
            log.error("\(firstError, privacy: .public)")
            writeError = firstError
        } else {
            writeError = nil
        }
    }

    private func clampedTarget(_ rpm: Float) -> Float {
        let lo = sharedMin
        let hi = max(sharedMax, lo)
        return min(max(rpm, lo), hi)
    }

    private func report(write message: String) {
        log.error("\(message, privacy: .public)")
        writeError = message
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func poll() {
        guard let smc else { return }
        do {
            let count = Int(try smc.readUInt8("FNum"))
            if fans.count != count {
                fans = (0..<count).map { Fan(id: $0) }
            }
            for i in 0..<count {
                fans[i].actual = try smc.readFloat("F\(i)Ac")
                if !controlEnabled {
                    // Track natural min/max only when we're not the ones writing.
                    fans[i].minRPM = try smc.readFloat("F\(i)Mn")
                    fans[i].maxRPM = try smc.readFloat("F\(i)Mx")
                }
            }
            readError = nil
        } catch {
            let msg = "Read: \(error)"
            log.error("\(msg, privacy: .public)")
            readError = msg
        }
    }
}
