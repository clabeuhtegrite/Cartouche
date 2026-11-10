//
//  CartoucheGameLogTests.swift
//  CartoucheCoreTests
//
//  The measures of a session, read from nxnative's log
//  (Sources/CartoucheGameLog.swift). The lines are written as nxnative's
//  format strings write them (hle_nvn.c, nvn_mtl.m, front_ios.m,
//  hle_audio.c, crash.c, main.m, hle_svc.c at nxnative 6c3aeb3).
//

import Foundation
import XCTest
@testable import CartoucheCore

final class CartoucheGameLogTests: XCTestCase {
    /// Three 300-frame stretches: at 60 fps, at 30, at 60 again, then a crash.
    private let session = """
    boot: DLC from /var/mobile/Containers/Data/Application/0F1E/Documents/Data/Application/5A3C/Documents/DLC
    [dm] build: commit 6c3aeb3d70a1, shader chain 844bf1a5ea8f, profile mkw
    [dm] front end: thermal state 0, brightness 0.50, Low Power Mode off
    [dm] [nvn-mtl] pipeline prepare: 13394 lines (9000 shaders, 13000 render pipelines, 394 compute pipelines) in 21.43 s on 6 workers before the first frame, progress screen shown; bases 100 compiled, 13294 from the archive, 0 reused; 12 specializations
    [dm] front end: layout split, hinge 0, divisions (), picture {{0, 0}, {393, 221}}, controls {{0, 221}, {393, 631}}
    [dm] [nvn] timing up to frame 300: frame time p50 16.67 / p95 18.90 / max 61.00 ms (300 frames); frame work p50 10.00 / p95 12.00 / max 30.00 ms (300 frames); NVN submit+present p50 2.00 / p95 3.00 / max 5.00 ms (300 frames); GPU p50 9.80 / p95 14.20 / max 20.00 ms (292 frames);
    [dm] [nvn] pipelines up to frame 300: on the submit thread pipelines 150.5 ms, shader libraries 0.0 ms, predictions 3 / 1.0 ms; all threads: archive lookups found 10 / 2.0 ms, found none 2 / 0.5 ms, specializations 1 / 0.2 ms, bases compiled 2 / 50.0 ms; draws with a hybrid pipeline 0 (0 pulling pipelines made, 0 misses with no pulling base ready); background builds kicked 0, done 0, made by the draw 0, in flight 0; draws that waited:
    [dm] [nvn] frame interval up to frame 300: >16.7ms 6 / 300 frames, p99 33.40 ms
    [dm] [nvn] on-screen up to frame 300: 300 frames, dropped 5 (discarded 1), p99 33.30 ms; footprint 4100 MiB; brightness 0.50; thermal 0
    [dm] [longframe] frame 412 (21.80 s) whole frame 61.0 ms, submit+present 45.2 ms, GPU 12.0 ms; new pipelines 3 + shader libraries 1, 40.1 ms in all; texture uploads 0 first + 0 re-uploads, 0.0 MB / 0.0 ms; draws with a hybrid pipeline 0
    [dm] [longframe] frame 500 (25.00 s) whole frame 30.0 ms, submit+present 5.0 ms, GPU 25.0 ms; new pipelines 0 + shader libraries 0, 0.0 ms in all; texture uploads 4 first + 1 re-uploads, 12.5 MB / 8.0 ms; draws with a hybrid pipeline 0
    [dm] [longframe] frame 550 (27.00 s) whole frame 40.0 ms, submit+present 5.0 ms, GPU 35.0 ms; new pipelines 0 + shader libraries 0, 0.0 ms in all; texture uploads 0 first + 0 re-uploads, 0.0 MB / 0.0 ms; draws with a hybrid pipeline 0
    [dm] [nvn] timing up to frame 600: frame time p50 33.33 / p95 35.00 / max 70.00 ms (300 frames); frame work p50 20.00 / p95 22.00 / max 40.00 ms (300 frames); GPU p50 20.00 / p95 25.00 / max 30.00 ms (300 frames);
    [dm] [nvn] pipelines up to frame 600: on the submit thread pipelines 29.5 ms, shader libraries 0.0 ms, predictions 0 / 0.0 ms; all threads: archive lookups found 0 / 0.0 ms, found none 0 / 0.0 ms, specializations 0 / 0.0 ms, bases compiled 0 / 0.0 ms; draws with a hybrid pipeline 0 (0 pulling pipelines made, 0 misses with no pulling base ready); background builds kicked 0, done 0, made by the draw 0, in flight 0; draws that waited:
    [dm] [nvn] frame interval up to frame 600: >16.7ms 294 / 300 frames, p99 40.00 ms
    [dm] [nvn] on-screen up to frame 600: 300 frames, dropped 1 (discarded 0), p99 40.00 ms; footprint 4813 MiB; brightness 0.50; thermal 1
    [dm] [nvn] power up to frame 600: CPU energy 4.10 W, 136.7 mJ per frame (30.0 fps); CPU 230% (100 = one core), 85% of it on performance cores; wakeups 1200/s (out of platform idle 300); GPU 610.0 ms/s; thermal 1; top yielders: none
    [dm] [nvn] residency set up to frame 600: 12 objects; draw-pass entry barriers full 0 / saved 0
    [dm] front end: thermal state → 2 (30 s after launch)
    [dm] front end: Low Power Mode → on (40 s after launch)
    [dm] [nvn-mtl] memory up to frame 600: resident 4700 MB, GPU allocated 2910 MB, deferred-release queue 0, residency set 12, serial objects 3; headroom to the system memory limit 1330 MB
    [dm] [nvn-mtl] present command buffer GPU time over 600 presents through MetalFX: p50 1.200 ms, p95 1.500 ms, max 2.000 ms
    [dm] audio #1 device callbacks 4000: 512–512 frames each, 2.5 blocks queued on average at callback; in these 2000, 1 underruns, 10.7 ms zero-padded
    [dm] [nvn] timing up to frame 900: frame time p50 16.67 / p95 18.00 / max 20.00 ms (300 frames); GPU p50 9.00 / p95 13.00 / max 15.00 ms (300 frames);
    [dm] [nvn] pipelines up to frame 900: on the submit thread pipelines 0.0 ms, shader libraries 0.0 ms, predictions 0 / 0.0 ms
    [dm] [nvn] frame interval up to frame 900: >16.7ms 3 / 300 frames, p99 20.00 ms
    [dm] [nvn] on-screen up to frame 900: 300 frames, dropped 0 (discarded 0), p99 20.00 ms; footprint 4500 MiB; brightness 0.50; thermal 2
    [dm] [nvn] power up to frame 900: CPU energy 3.00 W, 50.0 mJ per frame (60.0 fps); CPU 200% (100 = one core), 80% of it on performance cores; wakeups 1100/s (out of platform idle 280); GPU 400.0 ms/s; thermal 2; top yielders: none
    [dm] front end: TV connected (1920x1080 points), the picture moves there at 1920x1080, console mode
    [dm] CRASH sig=11 addr=0x10 pc=main+0x1a2b3c lr=main+0x1a2b00 sp=0x16fdff000
    x0=0x0 x1=0x1 x2=0x2 x3=0x3 x4=0x4 x5=0x5
    """

    private func measures(_ text: String, seconds: Double? = 60, limitMiB: Int? = 6143) -> CartoucheGameMeasures {
        var reader = CartoucheGameLogReader()
        reader.read(text: text)
        return reader.measures(seconds: seconds, limitMiB: limitMiB)
    }

    func testReadsEveryMeasureOfASession() {
        let measures = measures(session)
        XCTAssertEqual(measures.frames, 900)
        XCTAssertEqual(measures.targetFps, 60)
        XCTAssertEqual(measures.frameMs, CartoucheGameMeasures.Times(p50: 16.67, p95: 18.9, p99: 33.4))
        XCTAssertEqual(measures.gpuMs, CartoucheGameMeasures.Times(p50: 9.8, p95: 14.2, p99: nil))
        XCTAssertEqual(measures.overTargetPercent, 33.67)
        XCTAssertEqual(measures.droppedPercent, 0.67)
        XCTAssertEqual(measures.stutters, CartoucheGameMeasures.Stutters(count: 3, perMinute: 3, shaders: 1, textures: 1, other: 1))
        XCTAssertEqual(measures.shaderStallMsPerMinute, 180)
        XCTAssertEqual(measures.prepare, CartoucheGameMeasures.Prepare(seconds: 21.43, lines: 13394))
        XCTAssertEqual(measures.cpu, CartoucheGameMeasures.CPU(watts: 3.55, percent: 215, performanceCoresPercent: 83))
        XCTAssertEqual(measures.gpuBusyMsPerSecond, 505)
        XCTAssertEqual(measures.thermal, CartoucheGameMeasures.Thermal(nominal: 0.5, fair: 0, serious: 0.5, critical: 0,
                                                                       seriousAfterMinutes: 0.5))
        XCTAssertEqual(measures.lowPowerMinutes, 0.3)
        XCTAssertEqual(measures.memory, CartoucheGameMeasures.Memory(peakMiB: 4813, exactPeak: false, gpuPeakMiB: 2910,
                                                                     lowestHeadroomMiB: 1330))
        XCTAssertNil(measures.guestFile)
        XCTAssertEqual(measures.upscaler, CartoucheGameMeasures.Upscaler(kind: "metalfx", gpuMs: 1.2))
        XCTAssertEqual(measures.audioUnderrunsPerMinute, 1)
        XCTAssertEqual(measures.display, CartoucheGameMeasures.Display(tv: true, foldSplit: true))
        XCTAssertEqual(measures.dlc, true)
        XCTAssertEqual(measures.end, CartoucheGameMeasures.End(kind: "crash", signal: 11, pc: "main+0x1a2b3c", lr: "main+0x1a2b00"))
    }

    /// 300 frames at 30 fps last twice as long as at 60: two thirds of the
    /// time went at 30.
    func testTheFrameRateIsWeightedByTime() {
        XCTAssertEqual(measures(session).fps, CartoucheGameMeasures.Rate(median: 30, low5: 30))
        let steady = (1...19).map { "[dm] [nvn] power up to frame \($0 * 300 + 300): CPU energy 3.00 W, 50.0 mJ per frame (60.0 fps); CPU 200% (100 = one core), 80% of it on performance cores; wakeups 1100/s (out of platform idle 280); GPU 400.0 ms/s; thermal 0; top yielders: none" }
        let slow = "[dm] [nvn] power up to frame 6300: CPU energy 3.00 W, 50.0 mJ per frame (20.0 fps); CPU 200% (100 = one core), 80% of it on performance cores; wakeups 1100/s (out of platform idle 280); GPU 400.0 ms/s; thermal 0; top yielders: none"
        let rate = measures((steady + [slow]).joined(separator: "\n")).fps
        XCTAssertEqual(rate?.median, 60)
        // 15 s at 20 fps out of 110 s: the slowest 5% of the time.
        XCTAssertEqual(rate?.low5, 20)
    }

    /// Without power lines, the rate comes from the frame times.
    func testTheFrameRateFallsBackOnFrameTimes() {
        let text = "[dm] [nvn] timing up to frame 300: frame time p50 33.33 / p95 35.00 / max 70.00 ms (300 frames);"
        XCTAssertEqual(measures(text).fps, CartoucheGameMeasures.Rate(median: 30, low5: 30))
    }

    func testAGameThatStoppedNearItsLimitMostLikelyRanOutOfMemory() {
        let low = "[dm] [nvn-mtl] memory up to frame 9000: resident 5900 MB, GPU allocated 3000 MB, deferred-release queue 0; headroom to the system memory limit 120 MB"
        XCTAssertEqual(measures(low).end?.kind, "memory-likely")
        let near = "[dm] [nvn] on-screen up to frame 9000: 300 frames, dropped 0 (discarded 0), p99 17.00 ms; footprint 6000 MiB; brightness 0.50; thermal 0"
        XCTAssertEqual(measures(near).end?.kind, "memory-likely")
        XCTAssertEqual(measures(near, limitMiB: nil).end?.kind, "unknown")
        let far = "[dm] [nvn] on-screen up to frame 9000: 300 frames, dropped 0 (discarded 0), p99 17.00 ms; footprint 3000 MiB; brightness 0.50; thermal 0"
        XCTAssertEqual(measures(far).end?.kind, "unknown")
    }

    func testABootThatFailedBeforeAnyFrame() {
        let failed = "[RED] boot: Documents/romfs.img is not the image this build needs (verdict 2); not used\n[RED] boot: no RomFS for this game"
        XCTAssertEqual(measures(failed).end?.kind, "boot-failed")
        // A warning at boot, then frames: the game ran.
        let warned = failed + "\n[dm] [nvn] timing up to frame 300: frame time p50 16.67 / p95 18.90 / max 61.00 ms (300 frames);"
        XCTAssertEqual(measures(warned).end?.kind, "unknown")
    }

    func testTheGuestFileGivesTheExactPeak() {
        let line = "[dm] [mem] guest file: 2.10 GB allocated on disk, 1.50 GB dirty in memory (12 ms to count, every 10 s), 0.20 GB given back as holes; process read 3.00 GB, 1200 page-ins, logical writes 2.50 GB; footprint 4.20 GB (internal 3.90, compressed 0.30, peak so far 4.75), file pages mapped (external) 1.10 GB; 40.0 GB free on its disk (42.0 with what the system can purge)"
        let measures = measures(line)
        XCTAssertEqual(measures.guestFile, true)
        XCTAssertEqual(measures.memory?.peakMiB, 4864)
        XCTAssertEqual(measures.memory?.exactPeak, true)
    }

    func testACrashKeepsOnlyModuleOffsets() {
        let raw = measures("[dm] CRASH sig=10 (stderr held for 1 s, no dump) pc=0x1048f3a10 lr=subsdk0+0x4c10")
        XCTAssertEqual(raw.end, CartoucheGameMeasures.End(kind: "crash", signal: 10, pc: nil, lr: "subsdk0+0x4c10"))
        XCTAssertNil(CartoucheGameLogReader.location("/var/mobile/x+0x10"))
        XCTAssertNil(CartoucheGameLogReader.location("main+0x"))
        XCTAssertEqual(CartoucheGameLogReader.location("_ZN2nn2os4WaitEv+0x3c"), "_ZN2nn2os4WaitEv+0x3c")
    }

    /// Lines it does not know, and numbers it cannot read, leave the
    /// measures out rather than wrong.
    func testUnknownLinesAndBadNumbersAreLeftOut() {
        let text = """
        [dm] something else entirely
        [dm] [nvn] power up to frame 600: CPU energy 18446744073.71 W, nan mJ per frame (nan fps); CPU 230% (100 = one core), 85% of it on performance cores; wakeups 1/s (out of platform idle 1); GPU 610.0 ms/s; thermal 0
        [dm] [nvn] on-screen up to frame 300: 300 frames, dropped 400 (discarded 0), p99 33.30 ms; footprint -1 MiB; brightness 0.50; thermal 0
        """
        let measures = measures(text, seconds: nil)
        XCTAssertNil(measures.fps)
        XCTAssertNil(measures.cpu)
        XCTAssertNil(measures.droppedPercent)
        XCTAssertNil(measures.memory)
        XCTAssertNil(measures.thermal)
        XCTAssertEqual(measures.end?.kind, "unknown")
        XCTAssertEqual(measures.dlc, false)
    }

    func testAnEmptyLogMeasuresNothing() {
        let measures = measures("", seconds: nil, limitMiB: nil)
        XCTAssertEqual(measures, CartoucheGameMeasures(dlc: false, end: CartoucheGameMeasures.End(kind: "unknown")))
        let json = String(decoding: try! JSONEncoder().encode(measures), as: UTF8.self)
        XCTAssertFalse(json.contains("null"))
    }

    /// Without the state at launch, the state of each 300 frames gives the
    /// share of time in each.
    func testThermalStatesFromTheSummariesAlone() {
        let lines = [0, 0, 1, 2].enumerated().map { index, state in
            "[dm] [nvn] on-screen up to frame \(index * 300 + 300): 300 frames, dropped 0 (discarded 0), p99 17.00 ms; footprint 3000 MiB; brightness 0.50; thermal \(state)"
        }
        let thermal = measures(lines.joined(separator: "\n"), seconds: 240).thermal
        XCTAssertEqual(thermal, CartoucheGameMeasures.Thermal(nominal: 2, fair: 1, serious: 1, critical: 0, seriousAfterMinutes: 3))
    }

    /// A log is read from its file in pieces: lines across the pieces count once.
    func testReadsALongLogFromItsFile() throws {
        let filler = String(repeating: "[dm] [nvn] residency set up to frame 1: nothing of interest here, only padding\n", count: 40_000)
        let text = filler + session + "\n" + filler
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cartouche-log-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try XCTUnwrap(CartoucheGameLogReader.read(contentsOf: url))
        XCTAssertEqual(reader.measures(seconds: 60, limitMiB: 6143), measures(session))
        XCTAssertNil(CartoucheGameLogReader.read(contentsOf: url.appendingPathExtension("missing")))
    }

    func testPercentiles() {
        XCTAssertEqual(CartoucheGameLogReader.median([3, 1, 2]), 2)
        XCTAssertEqual(CartoucheGameLogReader.median([4, 1, 2, 3]), 2.5)
        XCTAssertNil(CartoucheGameLogReader.median([]))
        XCTAssertEqual(CartoucheGameLogReader.percentile([(1, 1), (2, 1), (3, 2)], 0.5), 2)
        XCTAssertEqual(CartoucheGameLogReader.percentile([(1, 1), (2, 1), (3, 2)], 0.75), 3)
        XCTAssertNil(CartoucheGameLogReader.percentile([(1, 0)], 0.5))
        XCTAssertEqual(CartoucheGameLogReader.rounded(16.666, 2), 16.67)
    }
}
