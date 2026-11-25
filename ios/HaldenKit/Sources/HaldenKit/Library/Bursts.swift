import Foundation

/// One tile in the library grid: either a single photo/video (`count == 1`), or a burst stack
/// represented by its cover photo (`count >= 2`).
public struct BurstStack: Equatable, Sendable {
    public var cover: LocalAsset
    public var burstId: String?
    public var count: Int
    public var memberIds: [String]

    public init(cover: LocalAsset, burstId: String?, count: Int, memberIds: [String]) {
        self.cover = cover
        self.burstId = burstId
        self.count = count
        self.memberIds = memberIds
    }
}

/// Grouping and selection helpers for burst photo stacks.
public enum Bursts {
    /// Collapses photos that share a `burstId` into a single grid stack at the position of the
    /// newest photo in the burst, keeping standalone photos and single-photo bursts as-is.
    public static func collapse(_ assets: [LocalAsset]) -> [BurstStack] {
        var counts: [String: Int] = [:]
        var membersByBurst: [String: [String]] = [:]
        for asset in assets {
            guard !asset.isVideo, let bid = asset.burstId, !bid.isEmpty else { continue }
            counts[bid, default: 0] += 1
            membersByBurst[bid, default: []].append(asset.id)
        }
        var seen: Set<String> = []
        var stacks: [BurstStack] = []
        stacks.reserveCapacity(assets.count)
        for asset in assets {
            if !asset.isVideo, let bid = asset.burstId, !bid.isEmpty, let count = counts[bid], count > 1 {
                guard seen.insert(bid).inserted else { continue }
                stacks.append(
                    BurstStack(cover: asset, burstId: bid, count: count, memberIds: membersByBurst[bid] ?? [asset.id]))
            } else {
                stacks.append(BurstStack(cover: asset, burstId: nil, count: 1, memberIds: [asset.id]))
            }
        }
        return stacks
    }

    /// All photos belonging to `asset`'s burst (in the order they appear in `assets`, or oldest
    /// first if `chronological` is true). Standalone assets return `[asset]`.
    public static func members(of asset: LocalAsset, in assets: [LocalAsset], chronological: Bool = true)
        -> [LocalAsset]
    {
        guard !asset.isVideo, let bid = asset.burstId, !bid.isEmpty else { return [asset] }
        let matched = assets.filter { !$0.isVideo && $0.burstId == bid }
        guard matched.count > 1 else { return [asset] }
        if chronological {
            return matched.sorted { ($0.takenAt, $0.id) < ($1.takenAt, $1.id) }
        }
        return matched
    }

    /// Given all members of a burst and the IDs the user chose to keep, returns the IDs to move
    /// to trash. Returns empty if nothing is kept (protects against accidentally trashing all).
    public static func toTrash(members: [LocalAsset], keeping: Set<String>) -> [String] {
        guard !keeping.isEmpty else { return [] }
        return members.map(\.id).filter { !keeping.contains($0) }
    }
}
