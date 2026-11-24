import AVFoundation
import Foundation
import Testing

@testable import HaldenKit

@Suite struct TimeLapseTests {
    /// Pictures at 30 a second for `seconds`; returns the plan.
    func run(_ plan: inout TimeLapsePlan, seconds: Double) {
        var t = 0.0
        while t <= seconds {
            _ = plan.keep(at: t)
            t += 1.0 / 30
        }
    }

    /// Two a second at first; however long it runs, the video is between 20 and 40 seconds.
    @Test func theVideoStaysBetweenTwentyAndFortySeconds() {
        var short = TimeLapsePlan()
        run(&short, seconds: 60)
        #expect(short.kept == 121 && short.interval == 0.5 && short.stretches.count == 1)
        for minutes in [11.0, 25, 60, 180] {
            var plan = TimeLapsePlan()
            run(&plan, seconds: minutes * 60)
            #expect(
                plan.finishedSeconds >= 20 && plan.finishedSeconds <= 40.1, "\(minutes) min: \(plan.finishedSeconds)")
        }
        var hour = TimeLapsePlan()
        run(&hour, seconds: 3600)
        #expect(hour.interval == 4)
        #expect(hour.speedUps.map(\.factor) == [8, 4, 2, 1])
        #expect(hour.speedUps.map(\.frames).reduce(0, +) == hour.kept)
    }

    @Test func aFixedIntervalStays() {
        var plan = TimeLapsePlan(fixed: 2)
        run(&plan, seconds: 3600)
        #expect(plan.stretches.count == 1 && plan.kept == 1801)
        #expect(abs(plan.finishedSeconds - 1801.0 / 30) < 0.001)
        #expect(TimeLapsePlan(fixed: 0).fixed == nil)
    }
}

@Suite struct SlowMotionTests {
    @Test func theStandardSlowPartIsInTheMiddle() {
        let slow = SlowMotion.standard(durationMs: 7000, frameRate: 240)
        #expect(slow == SlowMotion(slowFromMs: 1000, slowToMs: 6000, rate: 0.125))
        #expect(SlowMotion.standard(durationMs: 7000, frameRate: 120).rate == 0.25)
        #expect(slow.playedMs(of: 7000) == 2000 + 40_000)
        let tiny = SlowMotion.standard(durationMs: 600, frameRate: 240)
        #expect(tiny.slowFromMs == 200 && tiny.slowToMs == 400)
    }

    @Test func aSlowPartIsKeptInsideTheVideo() {
        let wild = SlowMotion(slowFromMs: -5, slowToMs: 99_999, rate: 0.01).fitted(to: 3000)
        #expect(wild == SlowMotion(slowFromMs: 0, slowToMs: 3000, rate: 0.125))
        let backwards = SlowMotion(slowFromMs: 2000, slowToMs: 1000, rate: 2).fitted(to: 3000)
        #expect(backwards == SlowMotion(slowFromMs: 2000, slowToMs: 2100, rate: 1))
    }
}

@Suite struct RetimingTests {
    func sample(seconds: Double) async throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("v.mov")
        try await SampleMedia.video(at: url, seed: 4, seconds: seconds)
        return (folder, url)
    }

    /// Two seconds with one second slowed to a quarter: five seconds played, also written out.
    @Test func aSlowPartPlaysLonger() async throws {
        let (folder, url) = try await sample(seconds: 2)
        defer { try? FileManager.default.removeItem(at: folder) }
        let played = try await Retiming.slowMotion(
            AVURLAsset(url: url), slow: SlowMotion(slowFromMs: 500, slowToMs: 1500, rate: 0.25))
        #expect(abs(try await played.load(.duration).seconds - 5) < 0.05)
        let written = folder.appendingPathComponent("played.mov")
        try await Retiming.export(played, to: written)
        #expect(abs(try await AVURLAsset(url: written).load(.duration).seconds - 5) < 0.1)
    }

    /// A time-lapse's earlier, denser stretch plays faster, so the whole runs at one speed.
    @Test func aTimeLapsePlaysAtOneSpeed() async throws {
        let (folder, url) = try await sample(seconds: 3)
        defer { try? FileManager.default.removeItem(at: folder) }
        // 90 frames: the first 60 taken twice as often as the last 30.
        let played = try await Retiming.timeLapse(
            AVURLAsset(url: url), stretches: [(0, 60, 2), (60, 30, 1)], frameRate: 30)
        #expect(abs(try await played.load(.duration).seconds - 2) < 0.05)
    }
}
