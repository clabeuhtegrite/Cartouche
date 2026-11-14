//
//  CartoucheGameLog.swift
//  Cartouche
//
//  What a session of a game was like, read from the log nxnative writes
//  for it: Documents/log.txt of the game's data folder, which becomes
//  log.prev.txt when the game starts again (nxnative's dm/ios/Sources/
//  main.m). Whatever its settings, nxnative writes there, every 300 frames,
//  the frame and GPU times, the frames over their time and dropped, the
//  footprint, the power and the thermal state (dm/gfx/nvn/hle_nvn.c); a
//  line for each frame clearly longer than the ones before it, with the
//  pipelines and textures it waited for; the pipeline preparation before
//  the first frame and memory readings (nvn_mtl.m); the iPhone's thermal
//  state and Low Power Mode as they change, and the layout of the picture
//  and the controls (front_ios.m); audio underruns (hle_audio.c); and the
//  crash line of a game that crashed (crash.c).
//
//  Only numbers come out of it, never a line: the log holds paths, and
//  lines that may look like keys. A line it does not know, or whose numbers
//  it cannot read, is left out, so that a change to nxnative's lines makes
//  the measures emptier, never wrong; `version` says which reading of the
//  log made them.
//
//  Platform-independent: tested on its own by launcher/Package.swift.
//

import Foundation

/// What one session of a game measured. Every value is optional: a log
/// that lacks a line leaves its value out.
struct CartoucheGameMeasures: Codable, Equatable {
    /// Frames per second, over the 300-frame stretches of the session,
    /// weighted by how long each lasted, but a stretch that held a pause:
    /// one of its frames lasted a second or more (CartoucheGameLogReader.pauseMs).
    struct Rate: Codable, Equatable {
        var median: Double
        /// The rate of the slowest 5% of the time played.
        var low5: Double
    }

    /// Milliseconds per frame: the median over the session of each
    /// stretch's own percentiles.
    struct Times: Codable, Equatable {
        var p50: Double
        var p95: Double
        var p99: Double?
    }

    /// Frames clearly longer than the ones before them, by what they waited for.
    struct Stutters: Codable, Equatable {
        var count: Int
        var perMinute: Double?
        /// New pipelines or shader libraries.
        var shaders: Int
        /// Texture uploads, and no new pipeline.
        var textures: Int
        var other: Int
    }

    /// The pipeline preparation before the first frame.
    struct Prepare: Codable, Equatable {
        var seconds: Double
        var lines: Int
    }

    struct CPU: Codable, Equatable {
        var watts: Double?
        /// 100 is one core.
        var percent: Double?
        var performanceCoresPercent: Double?
    }

    /// Minutes in each of the thermal states iOS reports.
    struct Thermal: Codable, Equatable {
        var nominal: Double
        var fair: Double
        var serious: Double
        var critical: Double
        /// When the iPhone first got to serious or critical.
        var seriousAfterMinutes: Double?
    }

    struct Memory: Codable, Equatable {
        /// The highest footprint read, every 300 frames, or the system's
        /// own peak when nxnative ran with its guest file, or when the game
        /// ran behind the console (CartoucheGameProcess).
        var peakMiB: Int?
        var exactPeak: Bool?
        var gpuPeakMiB: Int?
        /// The least memory left before iOS stops the game.
        var lowestHeadroomMiB: Int?
    }

    /// How the picture reaches the screen: MetalFX or the bilinear pass.
    struct Upscaler: Codable, Equatable {
        var kind: String
        var gpuMs: Double
    }

    struct Display: Codable, Equatable {
        /// The picture went to a TV.
        var tv: Bool
        /// The picture and the controls on either side of an iPhone Duo's
        /// fold: nxnative split them at a division UIKit reports. Not the
        /// split of an iPhone without a fold, which nxnative also makes, at
        /// the middle of the screen, in portrait (CartoucheGameLogReader.readLayout).
        var foldSplit: Bool
    }

    /// How the session ended, as far as the log tells.
    struct End: Codable, Equatable {
        /// crash, boot-failed, memory-likely, quit or unknown: an iPhone
        /// stops a game it runs out of memory for, and a player closes one,
        /// without a line in its log. Only a game that ran behind the
        /// console says the player quit it (CartoucheGameProcess).
        var kind: String
        var signal: Int?
        /// Where it crashed, as module+offset: "main+0x1a2b3c".
        var pc: String?
        var lr: String?
    }

    /// The last frame a 300-frame summary counted.
    var frames: Int?
    var fps: Rate?
    /// The frame rate the game asked for: 60, or 30.
    var targetFps: Int?
    var frameMs: Times?
    var gpuMs: Times?
    /// Frames that took longer than one frame at the target rate.
    var overTargetPercent: Double?
    /// Frames shown late or not shown.
    var droppedPercent: Double?
    var stutters: Stutters?
    /// Milliseconds the game's submit thread waited for new pipelines and
    /// shader libraries, per minute.
    var shaderStallMsPerMinute: Double?
    var prepare: Prepare?
    var cpu: CPU?
    var gpuBusyMsPerSecond: Double?
    var thermal: Thermal?
    var lowPowerMinutes: Double?
    var memory: Memory?
    /// nxnative kept the game's memory in a file (DM_GUEST_FILE).
    var guestFile: Bool?
    var upscaler: Upscaler?
    var audioUnderrunsPerMinute: Double?
    var display: Display?
    var dlc: Bool?
    var end: End?
}

/// Reads an nxnative log, line by line, into a session's measures.
struct CartoucheGameLogReader {
    /// This reading of nxnative's log, sent with every report: raised when
    /// a change to nxnative's lines, or to the reading, changes what it
    /// reads. 2 leaves out of the frame rate the stretches that held a
    /// pause (pauseMs); the server counts the slowest 5% from it on
    /// (telemetry/sheets.py, SLOWEST_READER). 3 ties display.foldSplit to
    /// a Duo's fold, and judges the end against the limit the log's memory
    /// lines tell: before it, foldSplit was true for any iPhone upright,
    /// and the end was judged against the limit Cartouche read when it
    /// read the log (telemetry/dashboard, FOLD_READER).
    static let version = 3
    /// A frame this long is a pause, not a slow frame: the game left behind
    /// the console, Cartouche in the background, or a freeze. nxnative
    /// times each stretch of 300 frames by the clock (power_line,
    /// hle_nvn.c), so a stretch that held a pause of a minute came out at
    /// under 5 fps, and the slowest 5% of a twenty-minute session with it.
    /// Its rate says nothing of how the game ran, and is left out.
    static let pauseMs = 1000.0
    /// A log is read up to this size: a long session writes a few megabytes.
    static let maximumBytes = 256 << 20
    /// Headroom under which a game that stopped without a line most likely
    /// ran out of memory.
    static let memoryMarginMiB = 300
    /// A memory reading this large or larger is none.
    private static let largestMiB = 1 << 22

    /// A layout nxnative made: whether it split the picture from the
    /// controls, and the divisions UIKit reported.
    private struct Layout {
        var split: Bool
        var divisions: [Frame]
    }

    /// A frame of the layout line, in points.
    private struct Frame {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var maxY: Double { y + height }
    }

    private var lastFrame: Int?
    private var frameP50: [Double] = []
    private var frameP95: [Double] = []
    private var gpuP50: [Double] = []
    private var gpuP95: [Double] = []
    private var intervalP99: [Double] = []
    private var overFrames = 0
    private var intervalFrames = 0
    private var targetMs: Double?
    private var shownFrames = 0
    private var droppedFrames = 0
    private var footprintPeak: Double?
    private var lastFootprint: Double?
    private var windowFps: [Double] = []
    /// Whether a power line gave a stretch's rate, even one left out.
    private var sawWindowFps = false
    /// The longest frame of the last timing line, and the frame it was up to.
    private var longestFrame: (frame: Int, ms: Double)?
    private var watts: [Double] = []
    private var cpuPercent: [Double] = []
    private var performancePercent: [Double] = []
    private var gpuBusy: [Double] = []
    private var windowThermal: [Int] = []
    private var stallMs = 0.0
    private var sawPipelines = false
    private var longFrames = 0
    private var longShaders = 0
    private var longTextures = 0
    private var latestSeconds = 0.0
    private var prepare: CartoucheGameMeasures.Prepare?
    private var gpuAllocatedPeak: Int?
    private var headroomLowest: Int?
    private var lastHeadroom: Int?
    /// The highest footprint a memory line read, and the limit iOS set then.
    private var memoryPeak: (residentMiB: Int, limitMiB: Int)?
    private var lastLimit: Int?
    private var exactPeakMiB: Double?
    private var guestFile = false
    private var upscalerKind: String?
    private var upscalerMs: [Double] = []
    private var underruns = 0
    private var sawAudio = false
    private var sawFrontEnd = false
    private var tv = false
    private var foldSplit = false
    /// The layout line nxnative is still writing: its divisions take a
    /// line each (readLayout).
    private var layout: Layout?
    private var dlc = false
    private var thermalStart: Int?
    private var thermalChanges: [(seconds: Double, state: Int)] = []
    private var lowPowerStart: Bool?
    private var lowPowerChanges: [(seconds: Double, on: Bool)] = []
    private var crash: CartoucheGameMeasures.End?
    private var bootProblem = false

    init() {}

    /// The memory limit iOS set for the game when its footprint was the
    /// highest a memory line of nxnative read: the limit changes as a game
    /// plays, as Game Mode comes on, and the one Cartouche reads when it
    /// reads the log, later, may not be the game's. Nil without a memory
    /// line that has the headroom: the Mac writes none.
    var limitAtPeakMiB: Int? { memoryPeak?.limitMiB }

    /// Reads the log at URL, or nil if it cannot be opened.
    static func read(contentsOf url: URL) -> CartoucheGameLogReader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var reader = CartoucheGameLogReader()
        var pending = Data()
        var total = 0
        while total < maximumBytes {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            total += chunk.count
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                reader.read(line: pending[start..<newline])
                start = pending.index(after: newline)
            }
            pending.removeSubrange(pending.startIndex..<start)
            // A line of a megabyte is none of the lines read here.
            if pending.count > 1 << 20 { pending.removeAll() }
        }
        if !pending.isEmpty { reader.read(line: pending) }
        return reader
    }

    /// Reads TEXT, a whole log.
    mutating func read(text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            read(String(line))
        }
    }

    mutating func read(line bytes: Data) {
        read(String(decoding: bytes, as: UTF8.self))
    }

    // MARK: Lines

    mutating func read(_ line: String) {
        if layout != nil, readDivision(line) { return }
        if line.contains("[nvn] ") {
            readSummary(line)
        } else if line.contains("[longframe] ") {
            readLongFrame(line)
        } else if line.contains("front end: ") {
            readFrontEnd(line)
        } else if line.contains("memory up to frame ") {
            readMemory(line)
        } else if line.contains("pipeline prepare: ") {
            readPrepare(line)
        } else if line.contains("present command buffer GPU time") {
            readPresent(line)
        } else if line.contains("audio #") {
            readAudio(line)
        } else if line.contains("CRASH sig=") {
            readCrash(line)
        } else if line.contains("guest file: ") {
            readGuestFile(line)
        } else if line.contains("boot: DLC from ") {
            dlc = true
        } else if line.contains("[RED] boot: ") {
            bootProblem = true
        }
    }

    private mutating func readSummary(_ line: String) {
        if line.contains("[nvn] timing up to frame ") {
            var upTo: Int?
            if let groups = Self.groups(Self.timing, line), let frame = Int(groups[0]) {
                noteFrame(frame)
                upTo = frame
            }
            longestFrame = nil
            for segment in Self.allGroups(Self.timingSegment, line) {
                guard let p50 = Self.number(segment[1]), let p95 = Self.number(segment[2]) else { continue }
                if segment[0] == "frame time" {
                    frameP50.append(p50)
                    frameP95.append(p95)
                    if let upTo, let longest = Self.number(segment[3]) { longestFrame = (upTo, longest) }
                } else {
                    gpuP50.append(p50)
                    gpuP95.append(p95)
                }
            }
        } else if let groups = Self.groups(Self.interval, line) {
            guard let target = Self.number(groups[1]), let over = Int(groups[2]), let count = Int(groups[3]),
                  count > 0, over <= count else { return }
            noteFrame(Int(groups[0]))
            targetMs = target
            overFrames += over
            intervalFrames += count
            if let p99 = Self.number(groups[4]) { intervalP99.append(p99) }
        } else if let groups = Self.groups(Self.onScreen, line) {
            guard let frames = Int(groups[1]), let dropped = Int(groups[2]), frames > 0, dropped <= frames else { return }
            noteFrame(Int(groups[0]))
            shownFrames += frames
            droppedFrames += dropped
            if let footprint = Self.number(groups[5]), footprint > 0 {
                footprintPeak = max(footprintPeak ?? 0, footprint)
                lastFootprint = footprint
            }
            if let thermal = Int(groups[7]), (0...3).contains(thermal) { windowThermal.append(thermal) }
        } else if let groups = Self.groups(Self.power, line) {
            noteFrame(Int(groups[0]))
            if let watt = Self.number(groups[1]), watt > 0, watt < 100 { watts.append(watt) }
            if let fps = Self.number(groups[3]), fps > 0, fps <= 480 {
                sawWindowFps = true
                // The timing line of the same stretch comes just before.
                let paused = longestFrame.map { $0.frame == Int(groups[0]) && $0.ms >= Self.pauseMs } ?? false
                if !paused { windowFps.append(fps) }
            }
            if let cpu = Self.number(groups[4]), cpu >= 0, cpu <= 10_000 { cpuPercent.append(cpu) }
            if let share = Self.number(groups[5]), share >= 0, share <= 100 { performancePercent.append(share) }
            if let gpu = Self.number(groups[6]), gpu >= 0, gpu <= 1000 { gpuBusy.append(gpu) }
        } else if let groups = Self.groups(Self.pipelines, line) {
            guard let pipelines = Self.number(groups[1]), let libraries = Self.number(groups[2]) else { return }
            noteFrame(Int(groups[0]))
            sawPipelines = true
            stallMs += pipelines + libraries
        }
    }

    private mutating func readLongFrame(_ line: String) {
        guard let groups = Self.groups(Self.longFrame, line), let pipelines = Int(groups[5]), let libraries = Int(groups[6]),
              let firstUploads = Int(groups[8]), let reuploads = Int(groups[9]) else { return }
        longFrames += 1
        if pipelines + libraries > 0 {
            longShaders += 1
        } else if firstUploads + reuploads > 0 {
            longTextures += 1
        }
        if let seconds = Self.number(groups[1]) { noteTime(seconds) }
    }

    private mutating func readFrontEnd(_ line: String) {
        sawFrontEnd = true
        if let groups = Self.groups(Self.thermalChange, line) {
            guard let state = Int(groups[0]), (0...3).contains(state), let seconds = Self.number(groups[1]) else { return }
            thermalChanges.append((seconds, state))
            noteTime(seconds)
        } else if let groups = Self.groups(Self.lowPowerChange, line) {
            guard let seconds = Self.number(groups[1]) else { return }
            lowPowerChanges.append((seconds, groups[0] == "on"))
            noteTime(seconds)
        } else if let groups = Self.groups(Self.frontEndStart, line) {
            if thermalStart == nil, let state = Int(groups[0]), (0...3).contains(state) { thermalStart = state }
            if lowPowerStart == nil { lowPowerStart = groups[1] == "on" }
        } else if line.contains("front end: TV connected") {
            tv = true
        } else if let start = line.range(of: "front end: layout ") {
            readLayout(line[start.upperBound...])
        }
    }

    /// A layout of the picture and the controls (front_ios.m,
    /// viewDidLayoutSubviews): "split", "overlay" or "pad only", the
    /// divisions UIKit reports, such as an iPhone Duo's fold, then the
    /// picture's frame and the controls'. The divisions are a list that
    /// takes a line each, and a line that begins with ")" for its end:
    ///
    ///     [dm] front end: layout split, hinge 0, divisions (
    ///         "{{0, 437}, {669, 24}} active=0"
    ///     ), picture {{0, 59}, {669, 376}}, controls {{0, 461}, {669, 490}}
    ///
    /// nxnative splits an iPhone without a fold too, in portrait, at the
    /// middle of its screen (DmLayout.h, dm_layout). The split is at the
    /// fold when the controls begin where a division wider than tall ends.
    private mutating func readLayout(_ rest: Substring) {
        layout = nil
        guard let open = rest.range(of: "divisions (") else { return }
        var found = Layout(split: rest.hasPrefix("split,"), divisions: [])
        let list = rest[open.upperBound...]
        guard let close = list.firstIndex(of: ")") else {
            layout = found
            return
        }
        found.divisions = Self.allGroups(Self.division, String(list[..<close])).compactMap(Self.frame)
        endLayout(found, String(list[close...]))
    }

    /// A line of the division list a layout is writing: a division, or the
    /// end of the list, with the picture and the controls. False for any
    /// other line, which another part of nxnative wrote in between: that
    /// layout is left out.
    private mutating func readDivision(_ line: String) -> Bool {
        guard var found = layout else { return false }
        layout = nil
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if trimmed.hasPrefix(")") {
            endLayout(found, String(trimmed))
            return true
        }
        guard let division = Self.groups(Self.division, line).flatMap(Self.frame) else { return false }
        found.divisions.append(division)
        layout = found
        return true
    }

    private mutating func endLayout(_ found: Layout, _ end: String) {
        guard found.split, let controls = Self.groups(Self.controls, end).flatMap(Self.frame) else { return }
        // dm_horizontal_division: wider than tall, over nine tenths of the
        // width; dm_layout puts the controls under it.
        if found.divisions.contains(where: { division in
            division.width > division.height && division.width >= controls.width * 0.9
                && abs(division.maxY - controls.y) < 1
        }) {
            foldSplit = true
        }
    }

    private mutating func readMemory(_ line: String) {
        var resident: Int?
        if let groups = Self.groups(Self.memory, line), let gpu = Int(groups[2]) {
            noteFrame(Int(groups[0]))
            gpuAllocatedPeak = max(gpuAllocatedPeak ?? 0, gpu)
            resident = Int(groups[1])
        }
        if let groups = Self.groups(Self.headroom, line), let headroom = Int(groups[0]) {
            headroomLowest = min(headroomLowest ?? headroom, headroom)
            lastHeadroom = headroom
            // The footprint and the headroom, each rounded down to the MiB,
            // add up to one less than the limit, a whole number of MiB.
            if let resident, resident < Self.largestMiB, headroom < Self.largestMiB {
                let limit = resident + headroom + 1
                lastLimit = limit
                if resident >= memoryPeak?.residentMiB ?? 0 { memoryPeak = (resident, limit) }
            }
        }
    }

    private mutating func readPrepare(_ line: String) {
        guard prepare == nil, let groups = Self.groups(Self.prepareLine, line),
              let lines = Int(groups[0]), let seconds = Self.number(groups[1]) else { return }
        prepare = CartoucheGameMeasures.Prepare(seconds: Self.rounded(seconds, 2), lines: lines)
    }

    private mutating func readPresent(_ line: String) {
        guard let groups = Self.groups(Self.present, line), let p50 = Self.number(groups[1]) else { return }
        upscalerKind = groups[0] == "MetalFX" ? "metalfx" : "bilinear"
        upscalerMs.append(p50)
    }

    private mutating func readAudio(_ line: String) {
        guard let groups = Self.groups(Self.audio, line), let count = Int(groups[1]) else { return }
        sawAudio = true
        underruns += count
    }

    private mutating func readCrash(_ line: String) {
        guard crash == nil, let groups = Self.groups(Self.crashLine, line), let signal = Int(groups[0]) else { return }
        crash = CartoucheGameMeasures.End(kind: "crash", signal: signal,
                                          pc: Self.groups(Self.crashPC, line).flatMap { Self.location($0[0]) },
                                          lr: Self.groups(Self.crashLR, line).flatMap { Self.location($0[0]) })
    }

    private mutating func readGuestFile(_ line: String) {
        guard let groups = Self.groups(Self.guestFileLine, line) else { return }
        guestFile = true
        if let peak = Self.number(groups[0]), peak > 0 {
            exactPeakMiB = max(exactPeakMiB ?? 0, peak * 1024)
        }
    }

    private mutating func noteFrame(_ frame: Int?) {
        guard let frame, frame >= 0 else { return }
        lastFrame = max(lastFrame ?? 0, frame)
    }

    private mutating func noteTime(_ seconds: Double) {
        if seconds.isFinite, seconds > latestSeconds { latestSeconds = seconds }
    }

    // MARK: Measures

    /// The measures of the session. SECONDS is how long it lasted, from its
    /// log's dates; LIMIT the memory limit the game had, in MiB, for a log
    /// whose memory lines do not tell it.
    func measures(seconds: Double?, limitMiB: Int?) -> CartoucheGameMeasures {
        var measures = CartoucheGameMeasures()
        let duration = max(seconds ?? 0, latestSeconds)
        let minutes = duration > 0 ? duration / 60 : nil
        func perMinute(_ count: Double) -> Double? {
            guard let minutes, minutes >= 0.5 else { return nil }
            return Self.rounded(count / minutes, 2)
        }

        measures.frames = lastFrame

        // The rate of each stretch, weighted by how long it lasted: 300
        // frames at 30 fps last twice as long as at 60.
        var rates = windowFps
        if !sawWindowFps {
            rates = frameP50.filter { $0 > 0 }.map { 1000 / $0 }
        }
        let weighted = rates.map { (value: $0, weight: 1 / $0) }
        if let median = Self.percentile(weighted, 0.5), let low = Self.percentile(weighted, 0.05) {
            measures.fps = CartoucheGameMeasures.Rate(median: Self.rounded(median, 1), low5: Self.rounded(low, 1))
        }
        if let targetMs, targetMs > 0 {
            measures.targetFps = Int((1000 / targetMs).rounded())
        }
        if let p50 = Self.median(frameP50), let p95 = Self.median(frameP95) {
            measures.frameMs = CartoucheGameMeasures.Times(p50: Self.rounded(p50, 2), p95: Self.rounded(p95, 2),
                                                           p99: Self.median(intervalP99).map { Self.rounded($0, 2) })
        }
        if let p50 = Self.median(gpuP50), let p95 = Self.median(gpuP95) {
            measures.gpuMs = CartoucheGameMeasures.Times(p50: Self.rounded(p50, 2), p95: Self.rounded(p95, 2), p99: nil)
        }
        if intervalFrames > 0 {
            measures.overTargetPercent = Self.rounded(100 * Double(overFrames) / Double(intervalFrames), 2)
        }
        if shownFrames > 0 {
            measures.droppedPercent = Self.rounded(100 * Double(droppedFrames) / Double(shownFrames), 2)
        }
        if lastFrame != nil || longFrames > 0 {
            measures.stutters = CartoucheGameMeasures.Stutters(
                count: longFrames, perMinute: perMinute(Double(longFrames)), shaders: longShaders,
                textures: longTextures, other: longFrames - longShaders - longTextures)
        }
        if sawPipelines {
            measures.shaderStallMsPerMinute = perMinute(stallMs)
        }
        measures.prepare = prepare
        let cpu = CartoucheGameMeasures.CPU(watts: Self.median(watts).map { Self.rounded($0, 2) },
                                            percent: Self.median(cpuPercent).map { Self.rounded($0, 0) },
                                            performanceCoresPercent: Self.median(performancePercent).map { Self.rounded($0, 0) })
        if cpu.watts != nil || cpu.percent != nil || cpu.performanceCoresPercent != nil {
            measures.cpu = cpu
        }
        measures.gpuBusyMsPerSecond = Self.median(gpuBusy).map { Self.rounded($0, 1) }
        measures.thermal = thermal(duration: duration)
        measures.lowPowerMinutes = lowPowerMinutes(duration: duration)

        var memory = CartoucheGameMeasures.Memory()
        if let exactPeakMiB {
            memory.peakMiB = Int(exactPeakMiB.rounded())
            memory.exactPeak = true
        } else if let footprintPeak {
            memory.peakMiB = Int(footprintPeak.rounded())
            memory.exactPeak = false
        }
        memory.gpuPeakMiB = gpuAllocatedPeak
        memory.lowestHeadroomMiB = headroomLowest
        if memory != CartoucheGameMeasures.Memory() {
            measures.memory = memory
        }
        if guestFile { measures.guestFile = true }
        if let upscalerKind, let gpuMs = Self.median(upscalerMs) {
            measures.upscaler = CartoucheGameMeasures.Upscaler(kind: upscalerKind, gpuMs: Self.rounded(gpuMs, 3))
        }
        if sawAudio {
            measures.audioUnderrunsPerMinute = perMinute(Double(underruns))
        }
        if sawFrontEnd {
            measures.display = CartoucheGameMeasures.Display(tv: tv, foldSplit: foldSplit)
        }
        measures.dlc = dlc
        // The limit as the game last had it: the one Cartouche read later
        // may be another.
        measures.end = end(limitMiB: lastLimit ?? limitMiB)
        return measures
    }

    private func end(limitMiB: Int?) -> CartoucheGameMeasures.End {
        if let crash { return crash }
        if bootProblem && lastFrame == nil {
            return CartoucheGameMeasures.End(kind: "boot-failed")
        }
        if let lastHeadroom, lastHeadroom <= Self.memoryMarginMiB {
            return CartoucheGameMeasures.End(kind: "memory-likely")
        }
        if let limitMiB, let lastFootprint, Int(lastFootprint) >= limitMiB - Self.memoryMarginMiB {
            return CartoucheGameMeasures.End(kind: "memory-likely")
        }
        return CartoucheGameMeasures.End(kind: "unknown")
    }

    /// Minutes in each thermal state: from the state at launch and each
    /// change, or, without them, from the state of each 300 frames.
    private func thermal(duration: Double) -> CartoucheGameMeasures.Thermal? {
        var minutes = [0.0, 0.0, 0.0, 0.0]
        var seriousAt: Double?
        if duration > 0, thermalStart != nil || !thermalChanges.isEmpty {
            var state = thermalStart ?? windowThermal.first ?? 0
            var since = 0.0
            if state >= 2 { seriousAt = 0 }
            for change in thermalChanges.sorted(by: { $0.seconds < $1.seconds }) {
                let at = min(max(change.seconds, since), duration)
                minutes[state] += (at - since) / 60
                since = at
                state = change.state
                if state >= 2, seriousAt == nil { seriousAt = at }
            }
            minutes[state] += max(duration - since, 0) / 60
        } else if !windowThermal.isEmpty, duration > 0 {
            for state in windowThermal {
                minutes[state] += duration / 60 / Double(windowThermal.count)
            }
            if let first = windowThermal.firstIndex(where: { $0 >= 2 }) {
                seriousAt = duration * Double(first) / Double(windowThermal.count)
            }
        } else {
            return nil
        }
        return CartoucheGameMeasures.Thermal(nominal: Self.rounded(minutes[0], 1), fair: Self.rounded(minutes[1], 1),
                                             serious: Self.rounded(minutes[2], 1), critical: Self.rounded(minutes[3], 1),
                                             seriousAfterMinutes: seriousAt.map { Self.rounded($0 / 60, 1) })
    }

    private func lowPowerMinutes(duration: Double) -> Double? {
        guard duration > 0, lowPowerStart != nil || !lowPowerChanges.isEmpty else { return nil }
        var on = lowPowerStart ?? false
        var since = 0.0
        var total = 0.0
        for change in lowPowerChanges.sorted(by: { $0.seconds < $1.seconds }) {
            let at = min(max(change.seconds, since), duration)
            if on { total += at - since }
            since = at
            on = change.on
        }
        if on { total += max(duration - since, 0) }
        return Self.rounded(total / 60, 1)
    }

    // MARK: Numbers

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// The value under which FRACTION of the total weight lies.
    static func percentile(_ values: [(value: Double, weight: Double)], _ fraction: Double) -> Double? {
        let usable = values.filter { $0.value.isFinite && $0.weight.isFinite && $0.weight > 0 }.sorted { $0.value < $1.value }
        let total = usable.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var sum = 0.0
        for item in usable {
            sum += item.weight
            if sum >= fraction * total { return item.value }
        }
        return usable.last?.value
    }

    static func rounded(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }

    private static func number(_ text: String) -> Double? {
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }

    /// The frame the groups of the rectangle expression read.
    private static func frame(_ groups: [String]) -> Frame? {
        let values = groups.prefix(4).compactMap(number)
        guard values.count == 4 else { return nil }
        return Frame(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    /// A crash location nxnative writes as module+offset, such as
    /// main+0x1a2b3c; an address alone tells nothing once the game is gone.
    static func location(_ text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard text.count <= 80, locationPattern.firstMatch(in: text, range: range) != nil else { return nil }
        return text
    }

    // MARK: Expressions

    private static func expression(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants: one that does not compile fails every test.
        try! NSRegularExpression(pattern: pattern)
    }

    private static let timing = expression(#"\[nvn\] timing up to frame ([0-9]+):"#)
    private static let timingSegment = expression(
        #"(?:^|[ ;:])(frame time|GPU) p50 ([0-9.]+) / p95 ([0-9.]+) / max ([0-9.]+) ms \(([0-9]+) frames\)"#)
    private static let interval = expression(
        #"\[nvn\] frame interval up to frame ([0-9]+): >([0-9.]+)ms ([0-9]+) / ([0-9]+) frames, p99 ([0-9.]+) ms"#)
    private static let onScreen = expression(
        #"\[nvn\] on-screen up to frame ([0-9]+): ([0-9]+) frames, dropped ([0-9]+) \(discarded ([0-9]+)\), p99 ([0-9.]+) ms; footprint (-?[0-9.]+) MiB; brightness (-?[0-9.]+); thermal (-?[0-9]+)"#)
    private static let power = expression(
        #"\[nvn\] power up to frame ([0-9]+): CPU energy (-?[0-9.]+) W, (-?[0-9.]+) mJ per frame \(([0-9.]+) fps\); CPU ([0-9.]+)% \(100 = one core\), ([0-9.]+)% of it on performance cores; wakeups [0-9.]+/s \(out of platform idle [0-9.]+\); GPU ([0-9.]+) ms/s"#)
    private static let pipelines = expression(
        #"\[nvn\] pipelines up to frame ([0-9]+): on the submit thread pipelines ([0-9.]+) ms, shader libraries ([0-9.]+) ms"#)
    private static let longFrame = expression(
        #"\[longframe\] frame ([0-9]+) \(([0-9.]+) s\) whole frame ([0-9.]+) ms, submit\+present ([0-9.]+) ms, GPU (-?[0-9.]+) ms; new pipelines ([0-9]+) \+ shader libraries ([0-9]+), ([0-9.]+) ms in all; texture uploads ([0-9]+) first \+ ([0-9]+) re-uploads"#)
    private static let frontEndStart = expression(
        #"front end: thermal state ([0-9]+), brightness -?[0-9.]+, Low Power Mode (on|off)"#)
    private static let thermalChange = expression(#"front end: thermal state → ([0-9]+) \(([0-9.]+) s after launch\)"#)
    private static let lowPowerChange = expression(#"front end: Low Power Mode → (on|off) \(([0-9.]+) s after launch\)"#)
    /// NSStringFromCGRect's {{x, y}, {width, height}}.
    private static let rectangle = #"\{\{(-?[0-9.]+(?:e[-+]?[0-9]+)?), (-?[0-9.]+(?:e[-+]?[0-9]+)?)\}, \{([0-9.]+(?:e[-+]?[0-9]+)?), ([0-9.]+(?:e[-+]?[0-9]+)?)\}\}"#
    private static let division = expression(rectangle + " active=[01]")
    private static let controls = expression("controls " + rectangle)
    private static let memory = expression(#"memory up to frame ([0-9]+): resident ([0-9]+) MB, GPU allocated ([0-9]+) MB"#)
    private static let headroom = expression(#"headroom to the system memory limit ([0-9]+) MB"#)
    private static let prepareLine = expression(
        #"pipeline prepare: ([0-9]+) lines \([0-9]+ shaders, [0-9]+ render pipelines, [0-9]+ compute pipelines\) in ([0-9.]+) s on [0-9]+ workers before the first frame"#)
    private static let present = expression(
        #"present command buffer GPU time over [0-9]+ presents through (MetalFX|the bilinear pass): p50 ([0-9.]+) ms"#)
    private static let audio = expression(#"audio #[0-9]+ device callbacks [0-9]+: .*; in these ([0-9]+), ([0-9]+) underruns"#)
    private static let crashLine = expression(#"CRASH sig=([0-9]+)"#)
    private static let crashPC = expression(#" pc=([^ ]+)"#)
    private static let crashLR = expression(#" lr=([^ ]+)"#)
    private static let locationPattern = expression(#"^[A-Za-z_][A-Za-z0-9_.$]{0,63}\+0x[0-9a-fA-F]{1,16}$"#)
    private static let guestFileLine = expression(
        #"guest file: .*footprint [0-9.]+ GB \(internal [0-9.]+, compressed [0-9.]+, peak so far (-?[0-9.]+)\)"#)

    /// The groups of EXPRESSION's first match in LINE.
    private static func groups(_ expression: NSRegularExpression, _ line: String) -> [String]? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = expression.firstMatch(in: line, range: range) else { return nil }
        return strings(of: match, in: line)
    }

    /// The groups of each of EXPRESSION's matches in LINE.
    private static func allGroups(_ expression: NSRegularExpression, _ line: String) -> [[String]] {
        let range = NSRange(line.startIndex..., in: line)
        return expression.matches(in: line, range: range).map { strings(of: $0, in: line) }
    }

    private static func strings(of match: NSTextCheckingResult, in line: String) -> [String] {
        (1..<match.numberOfRanges).map { index in
            let found = match.range(at: index)
            guard found.location != NSNotFound, let range = Range(found, in: line) else { return "" }
            return String(line[range])
        }
    }
}
