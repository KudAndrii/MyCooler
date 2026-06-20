//
//  XPCServer.swift
//  com.andrii-kud.my-cooler.helper
//
//  NSXPCListenerDelegate that gates incoming connections on a baked-in
//  code-signing requirement, then forwards calls to a shared SMCWriter.
//

import Foundation
import OSLog

private let log = Logger(subsystem: "com.andrii-kud.my-cooler.helper", category: "XPCServer")

/// Designated requirement the client must satisfy. Disabled under
/// ad-hoc / "Sign to Run Locally" — see XPCClient.swift for the reason.
/// With a paid Team ID, set this to:
///
///     identifier "com.andrii-kud.my-cooler" and anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>"
///
/// and re-enable the call in `listener(_:shouldAcceptNewConnection:)`.
private let clientCodeSigningRequirement: String? = nil

final class XPCServer: NSObject, NSXPCListenerDelegate, MyCoolerHelperProtocol {
    private let writer: SMCWriter?
    private let writerError: String?

    override init() {
        do {
            self.writer = try SMCWriter()
            self.writerError = nil
        } catch {
            self.writer = nil
            self.writerError = "SMCWriter init: \(error)"
            log.error("\(self.writerError ?? "", privacy: .public)")
        }
        super.init()
    }

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: MyCoolerHelperProtocol.self)
        newConnection.exportedObject = self
        if let clientCodeSigningRequirement {
            newConnection.setCodeSigningRequirement(clientCodeSigningRequirement)
        }
        newConnection.resume()
        return true
    }

    // MARK: - MyCoolerHelperProtocol

    func ping(reply: @escaping (Bool) -> Void) {
        reply(writer != nil)
    }

    func takeControl(fanCount: Int,
                     initialEnabled: Bool,
                     initialTargetRPM: Float,
                     reply: @escaping (String?) -> Void) {
        guard let writer else {
            reply(writerError ?? "SMC unavailable")
            return
        }
        do {
            try writer.takeControl(fanCount: fanCount,
                                   initialEnabled: initialEnabled,
                                   initialTargetRPM: initialTargetRPM)
            reply(nil)
        } catch {
            let message = "takeControl: \(error)"
            log.error("\(message, privacy: .public)")
            reply(message)
        }
    }

    func setFanRPM(fanIndex: Int, rpm: Float, reply: @escaping (String?) -> Void) {
        guard let writer else {
            reply(writerError ?? "SMC unavailable")
            return
        }
        do {
            try writer.setFanRPM(fanIndex: fanIndex, rpm: rpm)
            reply(nil)
        } catch {
            let message = "setFanRPM: \(error)"
            log.error("\(message, privacy: .public)")
            reply(message)
        }
    }

    func releaseControl(fanCount: Int, reply: @escaping (String?) -> Void) {
        guard let writer else {
            reply(writerError ?? "SMC unavailable")
            return
        }
        do {
            try writer.releaseControl(fanCount: fanCount)
            reply(nil)
        } catch {
            let message = "releaseControl: \(error)"
            log.error("\(message, privacy: .public)")
            reply(message)
        }
    }
}
