import CoreLocation
import Foundation
import HaldenKit
import MapKit

/// A trip found in the photos, with a name: "Rome, May 2026".
struct TripSuggestion: Identifiable, Equatable, Sendable {
    let trip: Trips.Trip
    let title: String
    var id: String { trip.id }
}

/// Finds trips in the library (`Trips`) and names them after the town where most of their photos
/// were taken. Names come from Apple Maps one at a time and are kept, so each place is asked for
/// once; trips kept as albums are not suggested again.
actor TripFinder {
    private let database: HaldenDatabase
    private var names: [String: String] = [:]
    private var loaded = false

    init(database: HaldenDatabase) {
        self.database = database
    }

    /// The trips not kept yet, newest first.
    func suggestions(rules: Trips.Rules) async -> [TripSuggestion] {
        loadNames()
        guard let points = try? database.tripPoints() else { return [] }
        let kept = keptTrips()
        let trips = Trips.find(in: points, rules: rules).filter { !kept.contains($0.id) }
        var found: [TripSuggestion] = []
        for trip in trips.prefix(30) {
            let place = await name(trip.latitude, trip.longitude) ?? "Trip"
            found.append(TripSuggestion(trip: trip, title: Trips.title(place: place, start: trip.start, end: trip.end)))
        }
        return found
    }

    /// Made into an album: not suggested again.
    func kept(_ id: String) {
        var kept = keptTrips()
        kept.insert(id)
        try? database.setMeta("keptTrips", try? JSONEncoder().encode(kept))
    }

    private func keptTrips() -> Set<String> {
        (try? database.meta("keptTrips")).flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
    }

    private func loadNames() {
        guard !loaded else { return }
        loaded = true
        names =
            (try? database.meta("placeNames")).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            ?? [:]
    }

    /// The town (else the region) at a place, by about 1 km.
    private func name(_ latitude: Double, _ longitude: Double) async -> String? {
        let key = String(format: "%.2f,%.2f", latitude, longitude)
        if let known = names[key] { return known }
        guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude)),
            let item = try? await request.mapItems.first
        else { return nil }
        let name = item.addressRepresentations?.cityName ?? item.addressRepresentations?.regionName ?? item.name
        if let name {
            names[key] = name
            try? database.setMeta("placeNames", try? JSONEncoder().encode(names))
        }
        // Apple Maps is asked gently.
        try? await Task.sleep(for: .milliseconds(300))
        return name
    }
}
