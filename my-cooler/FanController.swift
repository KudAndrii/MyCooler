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

    private(set) var fans: [Fan] = []
    private(set) var readError: String?
    private(set) var writeError: String?
    private(set) var isUnlocking: Bool = false
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
            applyManual()
        }
    }

    var targetRPM: Float = 0 {
        didSet {
            guard oldValue != targetRPM, controlEnabled, fanEnabled, !suppressWrites else { return }
            applyManual()
        }
    }

    private let smc: SMC?
    private var pollTask: Task<Void, Never>?
    private var suppressWrites = false
    private var didSetFtst = false

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

    // MARK: - Take / release control (Apple Silicon Ftst unlock)

    private func takeControl() async {
        guard let smc else { return }
        isUnlocking = true
        defer { isUnlocking = false }
        writeError = nil

        // Phase 1: enter diagnostic mode so thermalmonitord yields.
        do {
            try smc.writeUInt8(1, key: "Ftst")
            didSetFtst = true
        } catch {
            report(write: "Ftst=1 write: \(error)")
            return
        }

        guard !fans.isEmpty else { return }

        // Phase 2: poll each fan's mode key, wait for transition out of 3 (system mode).
        let waitDeadline = Date().addingTimeInterval(10)
        var released = Set<Int>()
        while released.count < fans.count, Date() < waitDeadline {
            for i in fans.indices where !released.contains(i) {
                if let mode = try? smc.readUInt8("F\(i)Md"), mode != 3 {
                    released.insert(i)
                }
            }
            if released.count < fans.count {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard released.count == fans.count else {
            report(write: "Daemon yield timeout (\(released.count)/\(fans.count) fans)")
            return
        }

        // Decide initial state before the mode flip so we can pin the target
        // immediately — otherwise the SMC briefly ramps to its default RPM in
        // the gap between F{N}Md=1 and the first F{N}Tg write.
        let initialEnabled = fans.contains { $0.actual > 0 }
        let avgActual = fans.map(\.actual).reduce(0, +) / Float(max(fans.count, 1))
        let initialTarget: Float = initialEnabled ? clampedTarget(avgActual) : 0

        // Phase 3: switch each fan into manual mode and immediately pin its
        // target. The first Md writes may fail briefly while the daemon is
        // still letting go; retry for a few seconds.
        for i in fans.indices {
            let retryDeadline = Date().addingTimeInterval(6)
            var ok = false
            while !ok, Date() < retryDeadline {
                do {
                    try smc.writeUInt8(1, key: "F\(i)Md")
                    ok = true
                } catch {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            guard ok else {
                report(write: "F\(i)Md=1 write failed after retry")
                return
            }
            try? smc.writeFloat(initialTarget, key: "F\(i)Tg")
        }

        // Phase 4: publish UI state, then apply canonically.
        suppressWrites = true
        fanEnabled = initialEnabled
        targetRPM = clampedTarget(initialEnabled ? avgActual : sharedMin)
        suppressWrites = false

        applyManual()
    }

    private func releaseControl() async {
        guard let smc else { return }
        var failed: String?
        for i in fans.indices {
            do {
                try smc.writeUInt8(0, key: "F\(i)Md")
            } catch SMCError.smcError(130) {
                // Expected on M3 Pro/Max — the mode key isn't writable while
                // still in manual. Releasing Ftst below transitions the daemon
                // back to system mode, which forces F{N}Md back to 3 anyway.
            } catch {
                if failed == nil { failed = "F\(i)Md=0 restore: \(error)" }
            }
        }
        if didSetFtst {
            do {
                try smc.writeUInt8(0, key: "Ftst")
                didSetFtst = false
            } catch {
                if failed == nil { failed = "Ftst=0: \(error)" }
            }
        }
        if let failed {
            log.error("\(failed, privacy: .public)")
            writeError = failed
        } else {
            writeError = nil
        }
    }

    private func applyManual() {
        guard let smc, controlEnabled else { return }
        let value: Float = fanEnabled ? clampedTarget(targetRPM) : 0
        var failed: String?
        for i in fans.indices {
            do {
                try smc.writeFloat(value, key: "F\(i)Tg")
            } catch {
                if failed == nil { failed = "F\(i)Tg write: \(error)" }
            }
        }
        if let failed {
            log.error("\(failed, privacy: .public)")
            writeError = failed
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
