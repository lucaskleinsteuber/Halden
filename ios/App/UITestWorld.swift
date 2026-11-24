import HaldenKit
import UIKit

/// A library for the UI tests: any number of photos with real thumbnails on disk, so the grid can
/// be scrolled and measured without a server.
enum UITestWorld {
    static func fill(_ database: HaldenDatabase, files: FileLocations, with count: Int) throws {
        // A few dozen distinct thumbnails, shared by many photos (as many photos look alike).
        let colors = 24
        var shas: [String] = []
        for index in 0..<colors {
            let hue = CGFloat(index) / CGFloat(colors)
            let image = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 384)).image { context in
                UIColor(hue: hue, saturation: 0.6, brightness: 0.85, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 512, height: 384))
                UIColor.white.withAlphaComponent(0.5).setFill()
                context.fill(CGRect(x: 40 + index * 12, y: 60, width: 120, height: 120))
            }
            let sha = String(format: "%064x", index + 1)
            try image.jpegData(compressionQuality: 0.8)?.write(to: files.thumbnail(sha256: sha))
            shas.append(sha)
        }
        let newest: Int64 = 1_795_443_730_000
        try database.writer.write { db in
            for index in 0..<count {
                var asset = LocalAsset(
                    id: String(format: "00000000-0000-4000-8000-%012d", index),
                    kind: index % 17 == 0 ? "video" : "photo",
                    takenAt: newest - Int64(index) * 3_600_000, width: 4032, height: 3024)
                asset.backedUp = index % 9 != 0
                asset.thumbnailSha256 = shas[index % colors]
                asset.durationMs = asset.isVideo ? Int64(5_000 + index % 60_000) : nil
                asset.seq = Int64(count - index)
                try asset.insert(db)
            }
        }
    }
}
