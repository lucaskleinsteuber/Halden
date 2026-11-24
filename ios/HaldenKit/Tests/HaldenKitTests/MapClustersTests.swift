import Foundation
import Testing

@testable import HaldenKit

@Suite struct MapClustersTests {
    func point(_ id: String, _ latitude: Double, _ longitude: Double, at: Int64 = 0, estimated: Bool = false)
        -> MapClusters.Point
    {
        MapClusters.Point(id: id, latitude: latitude, longitude: longitude, takenAt: at, estimated: estimated)
    }

    let germany = MapClusters.Region(latitude: 51, longitude: 10, latitudeSpan: 8, longitudeSpan: 8)

    /// Photos close together are one group, with the newest as its picture; far apart, two.
    @Test func closePhotosAreOneGroup() {
        let points = [
            point("a", 50.55, 9.68, at: 1), point("b", 50.56, 9.69, at: 3), point("c", 50.54, 9.67, at: 2),
            point("berlin", 52.52, 13.40, at: 5),
            point("rome", 41.9, 12.5),
        ]
        let groups = MapClusters.clusters(points, in: germany)
        #expect(groups.count == 2, "Rome is outside: \(groups)")
        #expect(groups[0].count == 3 && groups[0].newest == "b")
        #expect(Set(groups[0].ids) == ["a", "b", "c"])
        #expect(abs(groups[0].latitude - 50.55) < 0.001)
    }

    /// A group keeps its square while the map moves a little, and splits when zooming in.
    @Test func groupsStayWhileMovingAndSplitWhenZooming() {
        let points = [point("a", 50.10, 9.10), point("b", 50.40, 9.40)]
        let moved = MapClusters.Region(latitude: 51.3, longitude: 10.2, latitudeSpan: 8, longitudeSpan: 8)
        #expect(
            MapClusters.clusters(points, in: germany).map(\.id) == MapClusters.clusters(points, in: moved).map(\.id))
        #expect(MapClusters.clusters(points, in: germany).count == 1)
        let close = MapClusters.Region(latitude: 50.25, longitude: 9.25, latitudeSpan: 0.5, longitudeSpan: 0.5)
        #expect(MapClusters.clusters(points, in: close).count == 2)
    }

    @Test func estimatedPlacesAreMarkedAndTheRegionShowsAll() {
        let groups = MapClusters.clusters(
            [point("a", 50.5, 9.6, estimated: true), point("b", 50.5, 9.6, estimated: true)], in: germany)
        #expect(groups.first?.estimated == true)
        let mixed = MapClusters.clusters([point("a", 50.5, 9.6, estimated: true), point("b", 50.5, 9.6)], in: germany)
        #expect(mixed.first?.estimated == false)
        let region = MapClusters.region(showing: [point("a", 50, 9), point("b", 52, 13)])
        #expect(region?.latitude == 51 && region?.longitude == 11)
        #expect(MapClusters.region(showing: []) == nil)
        #expect(
            MapClusters.clusters(
                [point("a", 50, 9)], in: .init(latitude: 0, longitude: 0, latitudeSpan: 0, longitudeSpan: 1)
            ).isEmpty)
    }

    /// Fifty thousand photos are grouped fast enough to follow the map.
    @Test func fiftyThousandPhotosAreQuick() {
        var generator = SystemRandomNumberGenerator()
        let points = (0..<50_000).map { n in
            point("p\(n)", Double.random(in: 47...55, using: &generator), Double.random(in: 6...15, using: &generator))
        }
        // The best of five, in a debug build while other tests run alongside, also on the CI's
        // slower machines (about 0.4 s there): a generous limit that still catches anything that
        // grows faster than the photos (that would take many seconds).
        let clock = ContinuousClock()
        let took = (0..<5).map { _ in clock.measure { _ = MapClusters.clusters(points, in: germany) } }.min()!
        #expect(took < .seconds(1), "\(took)")
    }
}
