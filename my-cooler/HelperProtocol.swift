//
//  HelperProtocol.swift
//  my-cooler
//
//  XPC contract between MyCooler.app and the privileged helper.
//
//  The same file is compiled into both targets. The wire format is
//  defined by the @objc protocol selectors, so as long as the two
//  copies stay in sync, the runtime is happy.
//

import Foundation

/// Mach service name advertised by the helper's launchd plist and
/// used by the app to open `NSXPCConnection`.
public let MyCoolerHelperMachServiceName = "com.andrii-kud.my-cooler.helper"

@objc public protocol MyCoolerHelperProtocol {
    /// Round-trip probe — returns `true` once the helper is reachable.
    func ping(reply: @escaping (Bool) -> Void)

    /// Run the full Ftst unlock sequence: write `Ftst=1`, wait for each
    /// fan mode key to leave the system-controlled value, flip
    /// `F{N}Md=1`, and pin `F{N}Tg` to the chosen initial target.
    ///
    /// `reply` carries `nil` on success or a human-readable error.
    func takeControl(fanCount: Int,
                     initialEnabled: Bool,
                     initialTargetRPM: Float,
                     reply: @escaping (String?) -> Void)

    /// Pin a single fan to the given RPM. Caller must have already
    /// invoked `takeControl` in the same session.
    func setFanRPM(fanIndex: Int,
                   rpm: Float,
                   reply: @escaping (String?) -> Void)

    /// Hand control back to the system: write `F{N}Md=0` for every
    /// fan and `Ftst=0` to wake the thermal daemon.
    func releaseControl(fanCount: Int,
                        reply: @escaping (String?) -> Void)
}
