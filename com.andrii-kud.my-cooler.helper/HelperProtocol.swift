//
//  HelperProtocol.swift
//  com.andrii-kud.my-cooler.helper
//
//  Mirror of the app-side HelperProtocol.swift. The two copies must
//  stay byte-for-byte in sync; the wire format is defined by the
//  @objc protocol selectors.
//

import Foundation

public let MyCoolerHelperMachServiceName = "com.andrii-kud.my-cooler.helper"

@objc public protocol MyCoolerHelperProtocol {
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
