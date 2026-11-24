import Foundation

/// Which pictures a time-lapse keeps, like Apple's camera: at first two a second; whenever the
/// video would get longer than 40 seconds (at 30 frames a second), half as many. So however long
/// it runs, the video ends up between 20 and 40 seconds. With a fixed interval, every
/// `interval` seconds, however long it gets.
public struct TimeLapsePlan: Sendable, Equatable {
    /// Frames a second in the finished video.
    public static let outputRate = 30.0
    /// Longest finished video before the interval doubles.
    public static let longest = 40.0
    public static let firstInterval = 0.5

    /// A stretch of frames taken at one interval.
    public struct Stretch: Sendable, Equatable {
        public var firstFrame: Int
        public var interval: Double
    }

    public let fixed: Double?
    public private(set) var stretches: [Stretch]
    public private(set) var kept = 0
    private var nextAt = 0.0

    /// `fixed`: seconds between pictures; `nil` for the automatic interval.
    public init(fixed: Double? = nil) {
        self.fixed = fixed.flatMap { $0 > 0 ? $0 : nil }
        stretches = [Stretch(firstFrame: 0, interval: self.fixed ?? Self.firstInterval)]
    }

    public var interval: Double { stretches[stretches.count - 1].interval }

    /// Whether the picture taken `seconds` after the start is kept. Ask for every picture, in
    /// order.
    public mutating func keep(at seconds: Double) -> Bool {
        guard seconds + 0.0001 >= nextAt else { return false }
        // At this interval the video would get too long: half as many from now on.
        if fixed == nil, seconds / (interval * Self.outputRate) > Self.longest {
            stretches.append(Stretch(firstFrame: kept, interval: interval * 2))
        }
        kept += 1
        nextAt = max(nextAt + interval, seconds + interval * 0.5)
        return true
    }

    /// How long the finished video is once every stretch plays at the speed of the last one.
    public var finishedSeconds: Double {
        stretches.enumerated().reduce(0) { total, item in
            let (index, stretch) = item
            let end = index + 1 < stretches.count ? stretches[index + 1].firstFrame : kept
            let frames = Double(end - stretch.firstFrame)
            return total + frames / Self.outputRate * stretch.interval / interval
        }
    }

    /// For each stretch (by frame number in the written video): how much faster it has to play
    /// so the whole video runs at one speed. 1 for the last stretch.
    public var speedUps: [(firstFrame: Int, frames: Int, factor: Double)] {
        stretches.enumerated().map { index, stretch in
            let end = index + 1 < stretches.count ? stretches[index + 1].firstFrame : kept
            return (stretch.firstFrame, end - stretch.firstFrame, interval / stretch.interval)
        }
    }
}

/// The slow part of a slow-motion video: from, to (milliseconds into the video) and how slow
/// (1/8 is eight times slower). Kept next to the original, which stays as it was recorded, so
/// it can be changed any time; the server keeps it as the asset's `playback`.
public struct SlowMotion: Codable, Sendable, Equatable {
    public var slowFromMs: Int64
    public var slowToMs: Int64
    public var rate: Double

    public init(slowFromMs: Int64, slowToMs: Int64, rate: Double) {
        self.slowFromMs = slowFromMs
        self.slowToMs = slowToMs
        self.rate = rate
    }

    /// Like Apple's camera: slow from a little after the start to a little before the end,
    /// at 30 frames a second (1/8 for 240 fps, 1/4 for 120 fps).
    public static func standard(durationMs: Int64, frameRate: Double) -> SlowMotion {
        let edge = min(max(durationMs / 7, 250), durationMs / 3)
        let rate = frameRate > 30 ? min(max(30 / frameRate, 0.125), 1) : 0.25
        return SlowMotion(slowFromMs: edge, slowToMs: max(edge, durationMs - edge), rate: rate)
    }

    /// Within the video, at least a tenth of a second slow, the rate between 1/8 and 1.
    public func fitted(to durationMs: Int64) -> SlowMotion {
        let from = min(max(slowFromMs, 0), max(durationMs - 100, 0))
        let to = min(max(slowToMs, from + 100), durationMs)
        return SlowMotion(slowFromMs: from, slowToMs: to, rate: min(max(rate, 0.125), 1))
    }

    /// How long the video plays with the slow part.
    public func playedMs(of durationMs: Int64) -> Int64 {
        let fitted = fitted(to: durationMs)
        let slow = Double(fitted.slowToMs - fitted.slowFromMs)
        return durationMs - Int64(slow) + Int64((slow / fitted.rate).rounded())
    }
}
