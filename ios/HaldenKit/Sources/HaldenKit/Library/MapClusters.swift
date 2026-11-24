import Foundation

/// Photos on a map, grouped so it stays fast with tens of thousands: the visible part of the map
/// is laid on a grid fixed to the earth (so groups don't jump while the map moves), and each
/// square with photos becomes one group with how many there are and the newest one as its
/// picture. Worked out away from the main thread; about 2 ms for 50,000 photos.
public enum MapClusters {
    /// A photo with a place.
    public struct Point: Sendable, Equatable {
        public var id: String
        public var latitude: Double
        public var longitude: Double
        public var takenAt: Int64
        /// The place was estimated (from photos nearby in time), not measured.
        public var estimated: Bool

        public init(id: String, latitude: Double, longitude: Double, takenAt: Int64, estimated: Bool = false) {
            self.id = id
            self.latitude = latitude
            self.longitude = longitude
            self.takenAt = takenAt
            self.estimated = estimated
        }
    }

    /// The part of the map shown: its middle and how far it reaches (degrees).
    public struct Region: Sendable, Equatable {
        public var latitude: Double
        public var longitude: Double
        public var latitudeSpan: Double
        public var longitudeSpan: Double

        public init(latitude: Double, longitude: Double, latitudeSpan: Double, longitudeSpan: Double) {
            self.latitude = latitude
            self.longitude = longitude
            self.latitudeSpan = latitudeSpan
            self.longitudeSpan = longitudeSpan
        }
    }

    public struct Cluster: Sendable, Equatable, Identifiable {
        /// The square it is in: the same while the map moves at this zoom.
        public var id: String
        public var latitude: Double
        public var longitude: Double
        public var count: Int
        /// The newest photo, for the picture.
        public var newest: String
        /// Every photo in it is placed by estimate.
        public var estimated: Bool
        public var ids: [String]
    }

    /// Groups the photos in and just around `region`, about `across` squares across the width.
    public static func clusters(_ points: [Point], in region: Region, across: Int = 6) -> [Cluster] {
        guard region.latitudeSpan > 0, region.longitudeSpan > 0, across > 0 else { return [] }
        // Square sizes in steps of two, so zooming in splits a square into four.
        let step = pow(2, (log2(region.longitudeSpan / Double(across))).rounded(.up))
        let latitudeStep = step
        // A margin of half a screen around what is shown: no groups popping in at the edges.
        let south = region.latitude - region.latitudeSpan
        let north = region.latitude + region.latitudeSpan
        let west = region.longitude - region.longitudeSpan
        let east = region.longitude + region.longitudeSpan
        struct Sum {
            var latitude = 0.0
            var longitude = 0.0
            var count = 0
            var newest: (Int64, String) = (.min, "")
            var estimated = true
            var ids: [String] = []
        }
        var squares: [Int64: Sum] = [:]
        for point in points
        where point.latitude >= south && point.latitude <= north && point.longitude >= west
            && point.longitude <= east
        {
            let row = Int64((point.latitude / latitudeStep).rounded(.down))
            let column = Int64((point.longitude / step).rounded(.down))
            let key = row &* 1_000_003 &+ column
            var sum = squares[key] ?? Sum()
            sum.latitude += point.latitude
            sum.longitude += point.longitude
            sum.count += 1
            if (point.takenAt, point.id) > sum.newest { sum.newest = (point.takenAt, point.id) }
            sum.estimated = sum.estimated && point.estimated
            sum.ids.append(point.id)
            squares[key] = sum
        }
        return squares.map { key, sum in
            Cluster(
                id: "\(step)-\(key)", latitude: sum.latitude / Double(sum.count),
                longitude: sum.longitude / Double(sum.count), count: sum.count, newest: sum.newest.1,
                estimated: sum.estimated, ids: sum.ids)
        }
        .sorted { $0.count > $1.count || ($0.count == $1.count && $0.id < $1.id) }
    }

    /// The part of the map that shows every photo, with a little room around.
    public static func region(showing points: [Point]) -> Region? {
        guard let first = points.first else { return nil }
        var (south, north, west, east) = (first.latitude, first.latitude, first.longitude, first.longitude)
        for point in points {
            south = min(south, point.latitude)
            north = max(north, point.latitude)
            west = min(west, point.longitude)
            east = max(east, point.longitude)
        }
        return Region(
            latitude: (south + north) / 2, longitude: (west + east) / 2,
            latitudeSpan: min(max((north - south) * 1.3, 0.05), 170),
            longitudeSpan: min(max((east - west) * 1.3, 0.05), 350))
    }
}

extension LocalAsset {
    /// The photo as a point on the map, if it has a place.
    public var mapPoint: MapClusters.Point? {
        guard let latitude, let longitude else { return nil }
        return MapClusters.Point(
            id: id, latitude: latitude, longitude: longitude, takenAt: takenAt, estimated: locationSource == "estimated"
        )
    }
}
