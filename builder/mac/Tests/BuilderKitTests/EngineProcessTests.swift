//
//  EngineProcessTests.swift
//  BuilderKitTests
//
//  A batch the app started that does not run yet, as it waits for the batch
//  lock the engine's look at nxnative holds: Stop ends the engine, and the
//  caffeinate that keeps the Mac awake for it (Engine.stopStarting).
//

import Darwin
import Foundation
import XCTest
@testable import BuilderKit

final class EngineProcessTests: XCTestCase {
    func testABatchStartingStopsWithWhatKeepsTheMacAwake() throws {
        // As startBatch runs the engine: caffeinate -i, then the command.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-i", "/bin/sleep", "60"]
        try process.run()
        Thread.sleep(forTimeInterval: 0.5)
        var children = [pid_t](repeating: 0, count: 8)
        let found = proc_listchildpids(process.processIdentifier, &children, Int32(MemoryLayout<pid_t>.stride * children.count))
        let asked = Date()
        Engine.stopStarting(process)
        process.waitUntilExit()
        XCTAssertLessThan(Date().timeIntervalSince(asked), 10)
        // caffeinate's own process, which held the Mac awake, is gone too.
        Thread.sleep(forTimeInterval: 1)
        for helper in children.prefix(max(0, Int(found))) where helper > 1 {
            XCTAssertNotEqual(kill(helper, 0), 0, "caffeinate \(helper) is still there")
        }
    }

    func testAnEndedProcessIsSentNothing() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        Engine.stopStarting(process)
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
