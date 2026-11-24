import Foundation
import GRDB

/// Trips found in the library, for albums made by themselves: home is where most days have
/// photos; a trip is a run of days with photos far from home (gaps of a day or two without
/// photos belong to it). Worked out on the iPhone from what the library knows, nothing is sent
/// anywhere; a trip becomes a real album only when it is kept.
public enum Trips {
    /// A photo as the trip finder needs it.
    public struct Point: Sendable, Equatable {
        public var id: String
        public var takenAt: Int64
        public var timeZoneOffsetMinutes: Int?
        public var latitude: Double
        public var longitude: Double

        public init(id: String, takenAt: Int64, timeZoneOffsetMinutes: Int?, latitude: Double, longitude: Double) {
            self.id = id
            self.takenAt = takenAt
            self.timeZoneOffsetMinutes = timeZoneOffsetMinutes
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    public struct Trip: Sendable, Equatable, Identifiable {
        /// Stays the same while the trip does (its first day).
        public var id: String
        public var start: Int64
        public var end: Int64
        /// Newest first, like the library.
        public var assetIds: [String]
        /// Where most of its photos were taken, for its name.
        public var latitude: Double
        public var longitude: Double
        public var days: Int
    }

    /// How a trip is found.
    public struct Rules: Sendable {
        /// Farther than this from home is away.
        public var kilometres = 50.0
        /// Days without photos that still belong to the same trip.
        public var gapDays = 2
        /// Fewer photos away are no trip.
        public var minimumPhotos = 6

        public init(kilometres: Double = 50, gapDays: Int = 2, minimumPhotos: Int = 6) {
            self.kilometres = kilometres
            self.gapDays = gapDays
            self.minimumPhotos = minimumPhotos
        }
    }

    /// About 5 km squares (by latitude): the same place for "home".
    static func cell(_ latitude: Double, _ longitude: Double) -> String {
        "\(Int((latitude * 20).rounded(.down))):\(Int((longitude * 20).rounded(.down)))"
    }

    /// The day a photo was taken, where it was taken.
    static func day(_ point: Point) -> Int {
        let local = point.takenAt + Int64(point.timeZoneOffsetMinutes ?? 0) * 60_000
        return Int((Double(local) / 86_400_000).rounded(.down))
    }

    /// Home: the square with photos on the most days, and the middle of its photos.
    public static func home(of points: [Point]) -> (latitude: Double, longitude: Double)? {
        var days: [String: Set<Int>] = [:]
        for point in points { days[cell(point.latitude, point.longitude), default: []].insert(day(point)) }
        guard let best = days.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) })?.key else {
            return nil
        }
        let there = points.filter { cell($0.latitude, $0.longitude) == best }
        let latitude = there.map(\.latitude).reduce(0, +) / Double(there.count)
        let longitude = there.map(\.longitude).reduce(0, +) / Double(there.count)
        return (latitude, longitude)
    }

    /// Kilometres between two places (on a round earth).
    public static func distance(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let radians = Double.pi / 180
        let dLat = (b.0 - a.0) * radians
        let dLon = (b.1 - a.1) * radians
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.0 * radians) * cos(b.0 * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 6371 * 2 * atan2(sqrt(h), sqrt(1 - h))
    }

    /// The trips, newest first.
    public static func find(in points: [Point], rules: Rules = Rules()) -> [Trip] {
        guard let home = home(of: points) else { return [] }
        let away =
            points
            .filter { distance((home.latitude, home.longitude), ($0.latitude, $0.longitude)) > rules.kilometres }
            .sorted { $0.takenAt < $1.takenAt }
        var runs: [[Point]] = []
        for point in away {
            if let last = runs.last?.last, day(point) - day(last) <= rules.gapDays + 1 {
                runs[runs.count - 1].append(point)
            } else {
                runs.append([point])
            }
        }
        return
            runs
            .filter { $0.count >= rules.minimumPhotos }
            .map { run in
                // Named after where most of it happened.
                var counts: [String: [Point]] = [:]
                for point in run { counts[cell(point.latitude, point.longitude), default: []].append(point) }
                let main = counts.values.max { ($0.count, $1.first!.id) < ($1.count, $0.first!.id) }!
                let first = run.first!
                let days = Set(run.map(day))
                return Trip(
                    id: "trip-\(day(first))", start: first.takenAt, end: run.last!.takenAt,
                    assetIds: run.reversed().map(\.id),
                    latitude: main.map(\.latitude).reduce(0, +) / Double(main.count),
                    longitude: main.map(\.longitude).reduce(0, +) / Double(main.count),
                    days: (days.max()! - days.min()!) + 1)
            }
            .reversed()
    }

    /// "Rome, May 2026", "Italy, May – June 2026".
    public static func title(place: String, start: Int64, end: Int64, timeZone: TimeZone = .current) -> String {
        let format = Date.FormatStyle(timeZone: timeZone).month(.wide)
        let from = Date(timeIntervalSince1970: Double(start) / 1000)
        let to = Date(timeIntervalSince1970: Double(end) / 1000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let fromYear = calendar.component(.year, from: from)
        let toYear = calendar.component(.year, from: to)
        let sameMonth = calendar.isDate(from, equalTo: to, toGranularity: .month)
        let when: String
        if sameMonth {
            when = "\(from.formatted(format)) \(fromYear)"
        } else if fromYear == toYear {
            when = "\(from.formatted(format)) – \(to.formatted(format)) \(toYear)"
        } else {
            when = "\(from.formatted(format)) \(fromYear) – \(to.formatted(format)) \(toYear)"
        }
        return "\(place), \(when)"
    }
}

extension HaldenDatabase {
    /// Every photo with a place, for the trip finder.
    public func tripPoints() throws -> [Trips.Point] {
        try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, takenAt, timeZoneOffsetMinutes, latitude, longitude FROM asset
                    WHERE latitude IS NOT NULL AND longitude IS NOT NULL
                      AND trashedAt IS NULL AND deletedAt IS NULL
                    """
            ).map {
                Trips.Point(
                    id: $0["id"], takenAt: $0["takenAt"], timeZoneOffsetMinutes: $0["timeZoneOffsetMinutes"],
                    latitude: $0["latitude"], longitude: $0["longitude"])
            }
        }
    }
}
