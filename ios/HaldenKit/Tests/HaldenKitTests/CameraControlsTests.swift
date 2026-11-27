import Foundation
import Testing

@testable import HaldenKit

@Suite struct CameraControlsTests {
    @Test func aspectRatioCropsAreCenteredAndKeepOrientation() throws {
        #expect(PhotoAspectRatio.fourByThree.crop(forWidth: 4032, height: 3024) == nil)
        #expect(PhotoAspectRatio.square.crop(forWidth: 1000, height: 1000) == nil)

        // 4:3 landscape → 1:1 crops left and right equally.
        let squareLandscape = try #require(PhotoAspectRatio.square.crop(forWidth: 4000, height: 3000))
        #expect(abs(squareLandscape.width - 0.75) < 0.001)
        #expect(abs(squareLandscape.x - 0.125) < 0.001)
        #expect(squareLandscape.y == 0 && squareLandscape.height == 1)

        // 3:4 portrait → 1:1 crops top and bottom equally.
        let squarePortrait = try #require(PhotoAspectRatio.square.crop(forWidth: 3000, height: 4000))
        #expect(abs(squarePortrait.height - 0.75) < 0.001)
        #expect(abs(squarePortrait.y - 0.125) < 0.001)
        #expect(squarePortrait.x == 0 && squarePortrait.width == 1)

        // 4:3 landscape → 16:9 crops top and bottom to 75% height.
        let wideLandscape = try #require(PhotoAspectRatio.sixteenByNine.crop(forWidth: 4000, height: 3000))
        #expect(abs(wideLandscape.height - 0.75) < 0.001)
        #expect(abs(wideLandscape.y - 0.125) < 0.001)
        #expect(wideLandscape.x == 0 && wideLandscape.width == 1)

        // 3:4 portrait → 9:16 crops left and right to 75% width.
        let widePortrait = try #require(PhotoAspectRatio.sixteenByNine.crop(forWidth: 3000, height: 4000))
        #expect(abs(widePortrait.width - 0.75) < 0.001)
        #expect(abs(widePortrait.x - 0.125) < 0.001)
        #expect(widePortrait.y == 0 && widePortrait.height == 1)
    }

    @Test func photoResolutionAvailabilityAndBestDimension() {
        let iphone15 = [(4032, 3024), (5712, 4284), (8064, 6048)]
        #expect(PhotoResolution.available(for: iphone15) == [.mp12, .mp24, .mp48])
        #expect(PhotoResolution.bestDimensionIndex(wanted: .mp12, in: iphone15) == 0)
        #expect(PhotoResolution.bestDimensionIndex(wanted: .mp24, in: iphone15) == 1)
        #expect(PhotoResolution.bestDimensionIndex(wanted: .mp48, in: iphone15) == 2)

        let older = [(4032, 3024)]
        #expect(PhotoResolution.available(for: older) == [.mp12])

        // 12 and 48 MP but nothing near 24 MP: 24 MP isn't offered (it would quietly be 12 MP).
        let noTwentyFour = [(4032, 3024), (8064, 6048)]
        #expect(PhotoResolution.available(for: noTwentyFour) == [.mp12, .mp48])
        #expect(PhotoResolution.fitted(.mp24, in: [.mp12, .mp48]) == .mp12)
        #expect(PhotoResolution.fitted(.mp48, in: [.mp12, .mp24]) == .mp24)
        #expect(PhotoResolution.fitted(.mp24, in: [.mp12, .mp24, .mp48]) == .mp24)
        #expect(PhotoResolution.bestDimensionIndex(wanted: .mp48, in: older) == 0)
        #expect(PhotoResolution.bestDimensionIndex(wanted: .mp12, in: []) == nil)
    }

    @Test func timerExposureFrameRatesFocalLengthsAndTopBar() {
        #expect(CameraControls.nextTimer(after: 0) == 3)
        #expect(CameraControls.nextTimer(after: 3) == 5)
        #expect(CameraControls.nextTimer(after: 5) == 10)
        #expect(CameraControls.nextTimer(after: 10) == 0)

        #expect(CameraControls.clampedExposureBias(5.0) == 2.0)
        #expect(CameraControls.clampedExposureBias(-5.0) == -2.0)
        #expect(abs(CameraControls.clampedExposureBias(0.65) - (2.0 / 3.0)) < 0.001)
        #expect(CameraControls.clampedExposureBias(0.05) == 0)

        #expect(CameraControls.isPAL(frameRate: 25))
        #expect(!CameraControls.isPAL(frameRate: 30))
        #expect(CameraControls.frameRateLabel(25) == "25 fps (PAL)")

        #expect(FocalLength.mm24.zoomFactor == 1.0)
        #expect(FocalLength.mm28.zoomFactor == 1.2)
        #expect(FocalLength.mm35.zoomFactor == 1.5)
        #expect(FocalLength.mm24.next == .mm28)
        #expect(FocalLength.mm28.next == .mm35)
        #expect(FocalLength.mm35.next == .mm24)
        #expect(FocalLength.matching(zoom: 1.21) == .mm28)
        #expect(FocalLength.matching(zoom: 2.0) == nil)

        #expect(CameraControls.sanitizedTopBar([]) == CameraControls.defaultTopBarControls)
        let dupes: [TopBarControl] = [.flash, .flash, .grid, .timer, .raw, .exposure]
        #expect(CameraControls.sanitizedTopBar(dupes) == [.flash, .grid, .timer, .raw])
    }

    @Test func preserveSettingsResetsOnlyUnpreservedFields() {
        var settings = AppSettings()
        settings.preserveMode = false
        settings.keptMode = "video"
        settings.preserveExposure = false
        settings.keptExposureBias = 1.0
        settings.preserveLivePhoto = false
        settings.livePhotos = false
        settings.preserveResolution = false
        settings.photoResolution = .mp48
        settings.captureRAW = true
        settings.keepManualSettings = false
        settings.keptManual = ManualSettings(iso: 400)

        let reset = CameraControls.resetUnpreserved(in: settings)
        #expect(reset.keptMode == nil)
        #expect(reset.keptExposureBias == 0)
        #expect(reset.livePhotos == true)
        #expect(reset.photoResolution == .mp24)
        #expect(reset.captureRAW == false)
        #expect(reset.keptManual == nil)

        settings.preserveMode = true
        settings.preserveExposure = true
        settings.preserveLivePhoto = true
        settings.preserveResolution = true
        settings.keepManualSettings = true
        let kept = CameraControls.resetUnpreserved(in: settings)
        #expect(kept.keptMode == "video")
        #expect(kept.keptExposureBias == 1.0)
        #expect(kept.livePhotos == false)
        #expect(kept.photoResolution == .mp48)
        #expect(kept.captureRAW == true)
        #expect(kept.keptManual?.iso == 400)
    }

    @Test func croppedPhotoSavesCroppedVersionToApplePhotosWhileKeepingFullOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        let database = try HaldenDatabase()
        final class CapturingLibrary: PhotoLibrary, @unchecked Sendable {
            private let lock = NSLock()
            var savedDimensions: (Int, Int)?
            func mayRead() async -> Bool { true }
            func mayAdd() async -> Bool { true }
            func changes(since token: Data?) async throws -> PhotoChanges {
                PhotoChanges(added: [], deleted: [], token: nil)
            }
            func items(after date: Date?, limit: Int) async throws -> [PhotoItem] { [] }
            func items(withIdentifiers identifiers: [String]) async -> [PhotoItem] { [] }
            func export(_ item: PhotoItem, into folder: URL) async throws -> [ExportedFile] { [] }
            func save(_ file: URL, kind: PhotoItem.Kind, pairedVideo: URL?) async throws -> String {
                let data = try Data(contentsOf: file)
                let size = Thumbnails.shownSize(of: data)
                lock.withLock { savedDimensions = size }
                return "saved-crop"
            }
            func delete(_ identifiers: [String]) async -> Bool { true }
        }
        let library = CapturingLibrary()
        let sync = PhotosSync(library: library, database: database, files: files)

        // Full 4:3 photo (160 × 120), with 1:1 non-destructive crop in Halden.
        let data = try #require(SampleMedia.photo(seed: 12, width: 160, height: 120))
        try data.write(to: files.original("p1.jpg"))
        try Uploader.enqueue(
            database: database, files: files, assetId: "p1", fileName: "p1.jpg", kind: "photo",
            mimeType: "image/jpeg", metadata: UploadMetadata(takenAt: 100, width: 160, height: 120))
        var recipe = EditRecipe()
        recipe.crop = PhotoAspectRatio.square.crop(forWidth: 160, height: 120)
        try Actions(database: database).correct("p1", AssetCorrection(edit: .set(recipe)))

        await sync.save(assetId: "p1", settings: AppSettings())
        let saved = try #require(library.savedDimensions)
        #expect(saved.0 == 120 && saved.1 == 120, "Apple Photos gets the 1:1 cropped version")
        // Halden's original stays 160 × 120 untouched.
        let originalSize = try #require(Thumbnails.shownSize(of: try Data(contentsOf: files.original("p1.jpg"))))
        #expect(originalSize.width == 160 && originalSize.height == 120)
    }

    @Test func rawCompanionUploadEnqueuesAfterOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try FileLocations(root: root, caches: root.appendingPathComponent("caches"))
        let database = try HaldenDatabase()
        try Data("heic".utf8).write(to: files.original("r1.heic"))
        try Data("dng-bytes".utf8).write(to: files.original("r1.dng"))
        try Uploader.enqueue(
            database: database, files: files, assetId: "r1", fileName: "r1.heic", kind: "photo",
            mimeType: "image/heic", metadata: UploadMetadata(takenAt: 1))
        try Uploader.enqueueRaw(database: database, files: files, assetId: "r1", fileName: "r1.dng")
        let pending = try database.pendingUploads()
        #expect(pending.map(\.role) == ["original", "raw"])
        #expect(pending.last?.mimeType == "image/x-adobe-dng")
    }
}
