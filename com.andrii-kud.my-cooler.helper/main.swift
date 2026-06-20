//
//  main.swift
//  com.andrii-kud.my-cooler.helper
//
//  launchd spawns this binary on the first XPC connection. We open
//  a Mach listener, hand connections off to XPCServer, and let the
//  runloop park until launchd reaps us.
//

import Foundation
import OSLog

private let log = Logger(subsystem: "com.andrii-kud.my-cooler.helper", category: "main")
log.info("helper starting")

let server = XPCServer()
let listener = NSXPCListener(machServiceName: MyCoolerHelperMachServiceName)
listener.delegate = server
listener.resume()

RunLoop.current.run()
