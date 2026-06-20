//
//  XPCClient.swift
//  my-cooler
//
//  Thin async wrapper around NSXPCConnection talking to the privileged
//  helper. The connection is created lazily on first use and re-created
//  if it gets invalidated.
//

import Foundation
import OSLog

private let log = Logger(subsystem: "com.andrii-kud.my-cooler", category: "XPCClient")

/// Designated requirement enforced on the helper end of the connection.
/// Disabled under ad-hoc / "Sign to Run Locally" because a bare
/// `identifier "..."` clause isn't a complete requirement (it lacks an
/// anchor) and macOS invalidates the connection right after delivery —
/// the helper still runs the SMC writes but the client sees a spurious
/// "Couldn't communicate" error.
///
/// With a paid Team ID, set this to:
///
///     identifier "com.andrii-kud.my-cooler.helper" and anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>"
///
/// and re-enable the call in `ensureConnection()` below.
private let helperCodeSigningRequirement: String? = nil

@MainActor
final class XPCClient {
    private var connection: NSXPCConnection?

    deinit {
        connection?.invalidate()
    }

    func ping() async -> Bool {
        let result: String? = await call { proxy, resume in
            proxy.ping { ok in resume(ok ? nil : "ping returned false") }
        }
        return result == nil
    }

    func takeControl(fanCount: Int,
                     initialEnabled: Bool,
                     initialTargetRPM: Float) async -> String? {
        await call { proxy, resume in
            proxy.takeControl(fanCount: fanCount,
                              initialEnabled: initialEnabled,
                              initialTargetRPM: initialTargetRPM) { error in
                resume(error)
            }
        }
    }

    func setFanRPM(fanIndex: Int, rpm: Float) async -> String? {
        await call { proxy, resume in
            proxy.setFanRPM(fanIndex: fanIndex, rpm: rpm) { error in
                resume(error)
            }
        }
    }

    func releaseControl(fanCount: Int) async -> String? {
        await call { proxy, resume in
            proxy.releaseControl(fanCount: fanCount) { error in
                resume(error)
            }
        }
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    // MARK: - Private

    /// Wraps an XPC round trip in a continuation that's guaranteed to resume
    /// exactly once, and retries once on launchd-spawn races. The first call
    /// after `SMAppService.register()` frequently sees a "Couldn't communicate"
    /// error while the helper is still cold-starting; throwing away the dead
    /// connection and asking launchd for a fresh one usually succeeds.
    private func call(
        _ body: @escaping (_ proxy: MyCoolerHelperProtocol,
                           _ resume: @escaping (String?) -> Void) -> Void
    ) async -> String? {
        let first = await callOnce(body)
        guard let first, isTransient(first) else { return first }
        log.info("retrying XPC after transient error: \(first, privacy: .public)")
        invalidate()
        return await callOnce(body)
    }

    private func callOnce(
        _ body: @escaping (_ proxy: MyCoolerHelperProtocol,
                           _ resume: @escaping (String?) -> Void) -> Void
    ) async -> String? {
        await withCheckedContinuation { continuation in
            let state = ContinuationState(continuation: continuation)
            let conn = ensureConnection()
            let raw = conn.remoteObjectProxyWithErrorHandler { error in
                let message = "XPC error: \(error.localizedDescription)"
                log.error("\(message, privacy: .public)")
                state.resume(with: message)
            }
            guard let proxy = raw as? MyCoolerHelperProtocol else {
                state.resume(with: "Helper proxy cast failed")
                return
            }
            body(proxy) { reply in state.resume(with: reply) }
        }
    }

    private func isTransient(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("communicate")
            || lower.contains("interrupt")
            || lower.contains("invalidated")
    }

    /// Thread-safe one-shot continuation. NSXPCConnection's error handler can
    /// fire on an internal queue, so we serialise the resume() under a lock.
    private final class ContinuationState: @unchecked Sendable {
        private let continuation: CheckedContinuation<String?, Never>
        private let lock = NSLock()
        private var resumed = false

        init(continuation: CheckedContinuation<String?, Never>) {
            self.continuation = continuation
        }

        func resume(with value: String?) {
            lock.lock()
            let shouldResume = !resumed
            resumed = true
            lock.unlock()
            if shouldResume {
                continuation.resume(returning: value)
            }
        }
    }

    private func ensureConnection() -> NSXPCConnection {
        if let connection { return connection }
        let conn = NSXPCConnection(
            machServiceName: MyCoolerHelperMachServiceName,
            options: .privileged
        )
        conn.remoteObjectInterface = NSXPCInterface(with: MyCoolerHelperProtocol.self)
        if let helperCodeSigningRequirement {
            conn.setCodeSigningRequirement(helperCodeSigningRequirement)
        }
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        conn.resume()
        connection = conn
        return conn
    }
}
