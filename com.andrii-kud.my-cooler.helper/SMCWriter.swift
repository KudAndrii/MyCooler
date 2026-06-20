//
//  SMCWriter.swift
//  com.andrii-kud.my-cooler.helper
//
//  AppleSMC IOKit wrapper, write paths only. Runs inside the
//  privileged helper as EUID 0 so `IOConnectCallStructMethod` with
//  kSMCWriteKey is allowed instead of returning kIOReturnNotPrivileged.
//

import Foundation
import IOKit

enum SMCError: Error, CustomStringConvertible {
    case driverNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case keyNotFound
    case unsupportedType(String)
    case smcError(UInt8)

    var description: String {
        switch self {
        case .driverNotFound: return "AppleSMC service not found"
        case .openFailed(let kr): return "IOServiceOpen failed (\(kr))"
        case .callFailed(let kr): return "IOConnectCallStructMethod failed (\(kr))"
        case .keyNotFound: return "SMC key not found"
        case .unsupportedType(let t): return "Unsupported SMC type '\(t)'"
        case .smcError(let code): return "SMC error code \(code)"
        }
    }
}

private let kSMCHandleYPCEvent: UInt32 = 2
private let kSMCKeyNotFound: UInt8 = 132

private let kSMCReadKey: UInt8 = 5
private let kSMCWriteKey: UInt8 = 6
private let kSMCGetKeyInfo: UInt8 = 9

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

private func fourCharCode(_ s: String) -> UInt32 {
    var v: UInt32 = 0
    var count = 0
    for byte in s.utf8.prefix(4) {
        v = (v << 8) | UInt32(byte)
        count += 1
    }
    while count < 4 {
        v = (v << 8) | UInt32(0x20)
        count += 1
    }
    return v
}

private func string(from code: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "????"
}

private let kTypeFloat: UInt32 = fourCharCode("flt ")
private let kTypeUInt8: UInt32 = fourCharCode("ui8 ")
private let kTypeFPE2: UInt32 = fourCharCode("fpe2")

final class SMCWriter {
    private var connection: io_connect_t = 0

    init() throws {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { throw SMCError.driverNotFound }
        defer { IOObjectRelease(service) }

        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == KERN_SUCCESS else { throw SMCError.openFailed(kr) }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    // MARK: - Operation-level API

    /// Run the full Ftst unlock dance and pin every fan to `initialTargetRPM`.
    func takeControl(fanCount: Int,
                     initialEnabled: Bool,
                     initialTargetRPM: Float) throws {
        // Phase 1: enter diagnostic mode so thermalmonitord yields.
        try writeUInt8(1, key: "Ftst")

        guard fanCount > 0 else { return }

        // Phase 2: wait for each fan mode key to leave the system value (3).
        let waitDeadline = Date().addingTimeInterval(10)
        var released = Set<Int>()
        while released.count < fanCount, Date() < waitDeadline {
            for i in 0..<fanCount where !released.contains(i) {
                if let mode = try? readUInt8("F\(i)Md"), mode != 3 {
                    released.insert(i)
                }
            }
            if released.count < fanCount {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        guard released.count == fanCount else {
            throw SMCError.smcError(0)
        }

        // Phase 3: flip into manual mode and pin the initial target.
        let target = initialEnabled ? initialTargetRPM : 0
        for i in 0..<fanCount {
            let retryDeadline = Date().addingTimeInterval(6)
            var ok = false
            while !ok, Date() < retryDeadline {
                do {
                    try writeUInt8(1, key: "F\(i)Md")
                    ok = true
                } catch {
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
            guard ok else { throw SMCError.smcError(0) }
            try? writeFloat(target, key: "F\(i)Tg")
        }
    }

    func setFanRPM(fanIndex: Int, rpm: Float) throws {
        try writeFloat(rpm, key: "F\(fanIndex)Tg")
    }

    func releaseControl(fanCount: Int) throws {
        var firstError: Error?
        for i in 0..<fanCount {
            do {
                try writeUInt8(0, key: "F\(i)Md")
            } catch SMCError.smcError(130) {
                // Expected on M3 Pro/Max — Md isn't writable while still in
                // manual. Clearing Ftst below transitions the daemon back
                // to system mode and forces F{N}Md = 3 anyway.
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        do {
            try writeUInt8(0, key: "Ftst")
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    // MARK: - Low-level read/write

    func readUInt8(_ key: String) throws -> UInt8 {
        let (_, bytes) = try read(key: key)
        return bytes.first ?? 0
    }

    func writeFloat(_ value: Float, key: String) throws {
        let info = try keyInfo(for: key)
        let bytes = try encodeFloat(value, type: info.dataType, size: Int(info.dataSize))
        try write(key: key, info: info, bytes: bytes)
    }

    func writeUInt8(_ value: UInt8, key: String) throws {
        let info = try keyInfo(for: key)
        var bytes = [UInt8](repeating: 0, count: Int(info.dataSize))
        if !bytes.isEmpty { bytes[0] = value }
        try write(key: key, info: info, bytes: bytes)
    }

    // MARK: - Private

    private func read(key: String) throws -> (SMCKeyInfoData, [UInt8]) {
        let info = try keyInfo(for: key)
        var input = SMCParamStruct()
        input.key = fourCharCode(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = kSMCReadKey
        let output = try call(input: input)
        let size = Int(info.dataSize)
        var out = [UInt8](repeating: 0, count: size)
        withUnsafeBytes(of: output.bytes) { raw in
            for i in 0..<min(size, 32) {
                out[i] = raw[i]
            }
        }
        return (info, out)
    }

    private func write(key: String, info: SMCKeyInfoData, bytes: [UInt8]) throws {
        var input = SMCParamStruct()
        input.key = fourCharCode(key)
        input.keyInfo = info
        input.data8 = kSMCWriteKey
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for i in 0..<min(bytes.count, 32) {
                raw[i] = bytes[i]
            }
        }
        _ = try call(input: input)
    }

    private func keyInfo(for key: String) throws -> SMCKeyInfoData {
        var input = SMCParamStruct()
        input.key = fourCharCode(key)
        input.data8 = kSMCGetKeyInfo
        let output = try call(input: input)
        return output.keyInfo
    }

    private func call(input: SMCParamStruct) throws -> SMCParamStruct {
        var input = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride

        let kr = IOConnectCallStructMethod(
            connection,
            kSMCHandleYPCEvent,
            &input, MemoryLayout<SMCParamStruct>.stride,
            &output, &outputSize
        )
        guard kr == KERN_SUCCESS else { throw SMCError.callFailed(kr) }
        if output.result == kSMCKeyNotFound { throw SMCError.keyNotFound }
        if output.result != 0 { throw SMCError.smcError(output.result) }
        return output
    }

    private func encodeFloat(_ value: Float, type: UInt32, size: Int) throws -> [UInt8] {
        switch type {
        case kTypeFloat where size == 4:
            var v = value
            var bytes = [UInt8](repeating: 0, count: 4)
            withUnsafeBytes(of: &v) { src in
                for i in 0..<4 { bytes[i] = src[i] }
            }
            return bytes
        case kTypeFPE2 where size == 2:
            let clamped = max(0, min(Float(UInt16.max) / 4, value))
            let scaled = UInt16(clamped * 4)
            return [UInt8(scaled >> 8), UInt8(scaled & 0xFF)]
        default:
            throw SMCError.unsupportedType(string(from: type))
        }
    }
}
