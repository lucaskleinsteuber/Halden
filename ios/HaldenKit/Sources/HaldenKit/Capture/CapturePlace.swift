import Foundation

/// A position as the phone measured it.
public struct PlaceReading: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    /// Metres above sea level; `nil` when the phone doesn't know.
    public var altitude: Double?
    /// Radius in metres around the position in which the true one lies.
    public var horizontalAccuracy: Double
    public var verticalAccuracy: Double?
    public var measuredAt: Date

    public init(
        latitude: Double, longitude: Double, altitude: Double? = nil, horizontalAccuracy: Double,
        verticalAccuracy: Double? = nil, measuredAt: Date
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.measuredAt = measuredAt
    }
}

/// Which way the camera pointed: degrees from north (true north when known, else magnetic).
public struct CompassReading: Sendable, Equatable {
    public var degrees: Double
    public var accuracy: Double
    public var trueNorth: Bool

    public init(degrees: Double, accuracy: Double, trueNorth: Bool) {
        self.degrees = degrees
        self.accuracy = accuracy
        self.trueNorth = trueNorth
    }
}

/// Which place goes with a photo or video.
public enum CapturePlace {
    /// A reading older than this is from somewhere else.
    public static let maxAge: TimeInterval = 60

    /// The place for something taken at `moment`: none when the reading is too old or makes no
    /// sense; one less precise than the limit is kept with its accuracy (so it can be shown as
    /// imprecise) or left out, as the settings say. Better no place than a wrong one.
    public static func location(
        _ reading: PlaceReading?, heading: CompassReading?, at moment: Date, settings: AppSettings
    ) -> ClientLocation? {
        guard let reading,
            abs(moment.timeIntervalSince(reading.measuredAt)) <= maxAge,
            reading.horizontalAccuracy >= 0,
            (-90...90).contains(reading.latitude), (-180...180).contains(reading.longitude)
        else { return nil }
        if reading.horizontalAccuracy > settings.locationAccuracyLimit, settings.inaccurateLocation == .omit {
            return nil
        }
        let vertical = reading.verticalAccuracy.flatMap { $0 >= 0 ? $0 : nil }
        return ClientLocation(
            latitude: reading.latitude, longitude: reading.longitude,
            altitude: vertical == nil ? nil : reading.altitude,
            horizontalAccuracy: reading.horizontalAccuracy, verticalAccuracy: vertical,
            heading: heading?.degrees, headingAccuracy: heading?.accuracy)
    }

    /// Whether a place counts as imprecise (shown as such in the app).
    public static func imprecise(accuracy: Double?, settings: AppSettings) -> Bool {
        guard let accuracy else { return false }
        return accuracy > settings.locationAccuracyLimit
    }

    /// The place as ISO 6709, the way QuickTime keeps it in a video: `+48.1372+011.5755+519.000/`.
    public static func iso6709(latitude: Double, longitude: Double, altitude: Double?) -> String {
        func signed(_ value: Double, width: Int) -> String {
            let sign = value < 0 ? "-" : "+"
            return sign + String(format: "%0\(width).4f", abs(value))
        }
        var text = signed(latitude, width: 7) + signed(longitude, width: 8)
        if let altitude {
            text += (altitude < 0 ? "-" : "+") + String(format: "%.3f", abs(altitude))
        }
        return text + "/"
    }
}
