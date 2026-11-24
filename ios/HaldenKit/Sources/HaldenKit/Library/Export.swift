import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Copies of photos and videos to share or save elsewhere, with the corrected time, place, title
/// and description written into the file, so they go along. The picture itself is copied, not
/// encoded again: nothing of its quality is lost.
public enum Export {
    /// What goes into the file.
    public struct Facts: Sendable, Equatable {
        public var takenAt: Date
        public var timeZoneOffsetMinutes: Int?
        /// `nil`: the file carries no place at all (also not the one it had).
        public var location: ClientLocation?
        public var title: String?
        public var description: String?

        public init(
            takenAt: Date, timeZoneOffsetMinutes: Int?, location: ClientLocation?, title: String?,
            description: String?
        ) {
            self.takenAt = takenAt
            self.timeZoneOffsetMinutes = timeZoneOffsetMinutes
            self.location = location
            self.title = title
            self.description = description
        }

        public init(_ asset: LocalAsset) {
            takenAt = Date(timeIntervalSince1970: Double(asset.takenAt) / 1000)
            timeZoneOffsetMinutes = asset.timeZoneOffsetMinutes
            location = asset.latitude.flatMap { latitude in
                asset.longitude.map { longitude in
                    ClientLocation(
                        latitude: latitude, longitude: longitude, altitude: asset.altitude,
                        horizontalAccuracy: asset.locationAccuracy, heading: asset.heading)
                }
            }
            title = asset.title
            description = asset.description
        }

        var timeZone: TimeZone {
            timeZoneOffsetMinutes.flatMap { TimeZone(secondsFromGMT: $0 * 60) } ?? .current
        }
    }

    /// A photo with `facts` in its metadata (EXIF, GPS, IPTC), the picture copied as it is.
    public static func photo(_ source: URL, to destination: URL, facts: Facts) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(input),
            let original = CGImageSourceCopyMetadataAtIndex(input, 0, nil),
            let metadata = CGImageMetadataCreateMutableCopy(original)
        else { throw CocoaError(.fileReadCorruptFile) }

        // The place it had goes: either the corrected one replaces it, or there is none.
        var gpsTags: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(
            metadata, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary
        ) { path, _ in
            let name = path as String
            if name.hasPrefix("exif:GPS") { gpsTags.append(name) }
            return true
        }
        for tag in gpsTags { CGImageMetadataRemoveTagWithPath(metadata, nil, tag as CFString) }

        func set(_ dictionary: CFString, _ property: CFString, _ value: Any) {
            CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, property, value as CFTypeRef)
        }
        let zone = facts.timeZone
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = zone
        local.dateFormat = "yyyy:MM:dd HH:mm:ss"
        set(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, local.string(from: facts.takenAt))
        set(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeDigitized, local.string(from: facts.takenAt))
        let offset = zone.secondsFromGMT(for: facts.takenAt) / 60
        let offsetText = String(format: "%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 60, abs(offset) % 60)
        set(kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTimeOriginal, offsetText)
        set(kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTime, offsetText)
        if let location = facts.location {
            let gps = kCGImagePropertyGPSDictionary
            set(gps, kCGImagePropertyGPSLatitude, abs(location.latitude))
            set(gps, kCGImagePropertyGPSLatitudeRef, location.latitude >= 0 ? "N" : "S")
            set(gps, kCGImagePropertyGPSLongitude, abs(location.longitude))
            set(gps, kCGImagePropertyGPSLongitudeRef, location.longitude >= 0 ? "E" : "W")
            if let altitude = location.altitude {
                set(gps, kCGImagePropertyGPSAltitude, abs(altitude))
                set(gps, kCGImagePropertyGPSAltitudeRef, altitude >= 0 ? 0 : 1)
            }
            if let accuracy = location.horizontalAccuracy { set(gps, kCGImagePropertyGPSHPositioningError, accuracy) }
            if let heading = location.heading {
                set(gps, kCGImagePropertyGPSImgDirection, heading)
                set(gps, kCGImagePropertyGPSImgDirectionRef, "T")
            }
        }
        if let title = facts.title { set(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCObjectName, title) }
        if let description = facts.description {
            set(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract, description)
        }

        try? FileManager.default.removeItem(at: destination)
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(output, input, options as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? CocoaError(.fileWriteUnknown)
        }
    }

    /// A video with `facts` in its QuickTime metadata, the streams copied as they are.
    public static func video(_ source: URL, to destination: URL, facts: Facts) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var items = VideoMetadata.items(location: facts.location, takenAt: facts.takenAt, timeZone: facts.timeZone)
        func add(_ identifier: AVMetadataIdentifier, _ value: String) {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            items.append(item)
        }
        if let title = facts.title { add(.quickTimeMetadataTitle, title) }
        if let description = facts.description { add(.quickTimeMetadataDescription, description) }
        session.metadata = items
        try? FileManager.default.removeItem(at: destination)
        try await session.export(to: destination, as: .mov)
    }

    /// A copy for sharing in `folder`, named like the original, with the corrections in it when
    /// `withCorrections`; else the original itself.
    public static func copy(
        of original: URL, asset: LocalAsset, withCorrections: Bool, into folder: URL
    ) async throws -> URL {
        guard withCorrections else { return original }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(
            "Halden-\(asset.id.prefix(8)).\(original.pathExtension.lowercased())")
        if Thumbnails.isVideo(original) {
            try await video(original, to: destination, facts: Facts(asset))
        } else {
            try photo(original, to: destination, facts: Facts(asset))
        }
        return destination
    }
}
