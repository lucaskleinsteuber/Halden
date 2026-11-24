import Foundation
import Testing

@testable import HaldenKit

@Suite struct TripsTests {
    let day: Int64 = 86_400_000
    let start: Int64 = 1_779_926_400_000  // 28 May 2026, midnight UTC: the photos stay on their day

    /// Photos at `place` on `days` (offsets from `start`), `perDay` each.
    func photos(_ prefix: String, at place: (Double, Double), days: [Int], perDay: Int = 3) -> [Trips.Point] {
        days.flatMap { d in
            (0..<perDay).map { n in
                Trips.Point(
                    id: "\(prefix)-\(d)-\(n)", takenAt: start + Int64(d) * day + Int64(n) * 3_600_000,
                    timeZoneOffsetMinutes: 120, latitude: place.0 + Double(n) * 0.001, longitude: place.1)
            }
        }
    }

    let fulda = (50.555, 9.680)
    let rome = (41.902, 12.496)
    let paris = (48.857, 2.352)

    /// Home is where most days are; days away, close together, are one trip.
    @Test func daysAwayBecomeTrips() {
        let home = photos("home", at: fulda, days: Array(0..<60))
        // Rome over five days with a day without photos; Paris for two days, later.
        let romeTrip = photos("rome", at: rome, days: [10, 11, 13, 14])
        let parisTrip = photos("paris", at: paris, days: [40, 41])
        // One photo far away is no trip.
        let lonely = photos("once", at: paris, days: [50], perDay: 1)
        let trips = Trips.find(in: home + romeTrip + parisTrip + lonely)
        #expect(trips.count == 2)
        #expect(trips[0].assetIds.allSatisfy { $0.hasPrefix("paris") }, "newest first")
        #expect(trips[1].assetIds.count == 12 && trips[1].days == 5)
        #expect(abs(trips[1].latitude - rome.0) < 0.01)
        #expect(trips[1].assetIds.first == "rome-14-2", "newest photo first")
        #expect(Trips.find(in: home + romeTrip).first?.id == trips[1].id, "the same trip keeps its id")
    }

    /// A long gap splits; a short trip with few photos is none.
    @Test func longGapsSplitAndFewPhotosAreNoTrip() {
        let home = photos("home", at: fulda, days: Array(0..<40))
        let twice = photos("rome", at: rome, days: [5, 6, 20, 21])
        #expect(Trips.find(in: home + twice).count == 2)
        let few = photos("rome", at: rome, days: [5], perDay: 3)
        #expect(Trips.find(in: home + few).isEmpty)
        #expect(Trips.find(in: home + few, rules: .init(minimumPhotos: 3)).count == 1)
        #expect(Trips.find(in: []).isEmpty)
    }

    @Test func distancesAndTitles() {
        // Paris to London: 343.5 km.
        #expect(abs(Trips.distance((48.8566, 2.3522), (51.5074, -0.1278)) - 343.5) < 2)
        let utc = TimeZone(identifier: "UTC")!
        let may = Int64(1_779_000_000_000)  // 17 May 2026
        #expect(Trips.title(place: "Rome", start: may, end: may + day * 3, timeZone: utc) == "Rome, May 2026")
        #expect(
            Trips.title(place: "Italy", start: may, end: may + day * 20, timeZone: utc) == "Italy, May – June 2026")
        #expect(
            Trips.title(place: "Alps", start: may + day * 220, end: may + day * 240, timeZone: utc)
                == "Alps, December 2026 – January 2027")
    }
}
