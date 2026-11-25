import Foundation
import GRDB

/// Rules for giving screenshots and screen recordings without GPS an estimated place in Halden:
///
/// 1. If the capture is recent (at most `screenshotPlaceMaxMinutes`, default 30 min), use where
///    this iPhone is right now (source `device`), when a fresh reading is available.
/// 2. Otherwise (or when no device reading is available), use the place of the nearest photo in
///    time within two hours (source `estimated`), matching the server's `location-suggestion`.
/// 3. Otherwise leave it without a place so it appears in "Without place".
///
/// Apple Photos is never modified.
public enum ScreenshotPlace {
    /// Two hours on either side, matching `[library] location_suggest_minutes = 120` on the server.
    public static let neighborWindowMs: Int64 = 2 * 60 * 60 * 1000

    /// Small clock-skew allowance for a capture timestamp just ahead of `now`.
    private static let futureAllowanceSeconds: TimeInterval = 60

    /// Whether this Apple Photos item should receive an estimated place.
    public static func eligible(_ item: PhotoItem, settings: AppSettings) -> Bool {
        guard settings.locateScreenshots, item.location == nil else { return false }
        if item.isScreenshot { return true }
        if item.isScreenRecording && settings.locateScreenRecordings { return true }
        return false
    }

    /// True when the item was taken recently enough to use this iPhone's current location.
    public static func withinDeviceWindow(_ item: PhotoItem, now: Date, settings: AppSettings) -> Bool {
        guard let taken = item.creationDate else { return false }
        let maxSeconds = TimeInterval(max(settings.screenshotPlaceMaxMinutes, 0) * 60)
        guard maxSeconds > 0 else { return false }
        let age = now.timeIntervalSince(taken)
        return age >= -futureAllowanceSeconds && age <= maxSeconds
    }

    /// Turns a fresh device reading into a `device`-sourced estimated location.
    public static func deviceLocation(
        _ reading: PlaceReading?, at now: Date, settings: AppSettings
    ) -> ClientLocation? {
        guard var location = CapturePlace.location(reading, heading: nil, at: now, settings: settings) else {
            return nil
        }
        location.source = "device"
        return location
    }

    /// Nearest non-deleted photo in the local library within `windowMs` that has a non-estimated
    /// location, returned with source `estimated`.
    public static func nearestLocation(
        in database: HaldenDatabase, near takenAtMs: Int64, excluding assetId: String? = nil,
        windowMs: Int64 = neighborWindowMs
    ) throws -> ClientLocation? {
        let low = takenAtMs - windowMs
        let high = takenAtMs + windowMs
        let excluded = assetId?.lowercased() ?? ""
        struct Candidate: FetchableRecord, Decodable {
            var latitude: Double
            var longitude: Double
            var altitude: Double?
            var takenAt: Int64
        }
        let pair: (Candidate?, Candidate?) = try database.writer.read { db in
            let before = try Candidate.fetchOne(
                db,
                sql: """
                    SELECT latitude, longitude, altitude, takenAt FROM asset
                    WHERE takenAt BETWEEN ? AND ? AND id <> ?
                      AND deletedAt IS NULL AND latitude IS NOT NULL AND longitude IS NOT NULL
                      AND coalesce(locationSource, '') NOT IN ('estimated', 'device')
                    ORDER BY takenAt DESC LIMIT 1
                    """, arguments: [low, takenAtMs, excluded])
            let after = try Candidate.fetchOne(
                db,
                sql: """
                    SELECT latitude, longitude, altitude, takenAt FROM asset
                    WHERE takenAt BETWEEN ? AND ? AND id <> ?
                      AND deletedAt IS NULL AND latitude IS NOT NULL AND longitude IS NOT NULL
                      AND coalesce(locationSource, '') NOT IN ('estimated', 'device')
                    ORDER BY takenAt ASC LIMIT 1
                    """, arguments: [takenAtMs, high, excluded])
            return (before, after)
        }
        let chosen = [pair.0, pair.1].compactMap { $0 }.min {
            abs($0.takenAt - takenAtMs) < abs($1.takenAt - takenAtMs)
        }
        return chosen.map {
            ClientLocation(latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude, source: "estimated")
        }
    }

    /// Chooses an estimated location for `item`, or `nil` if none applies.
    public static func resolve(
        for item: PhotoItem, now: Date, deviceReading: PlaceReading?, database: HaldenDatabase, settings: AppSettings
    ) throws -> ClientLocation? {
        guard eligible(item, settings: settings) else { return nil }
        if withinDeviceWindow(item, now: now, settings: settings),
            let current = deviceLocation(deviceReading, at: now, settings: settings)
        {
            return current
        }
        guard let date = item.creationDate else { return nil }
        let takenAtMs = Int64((date.timeIntervalSince1970 * 1000).rounded())
        return try nearestLocation(in: database, near: takenAtMs)
    }
}
