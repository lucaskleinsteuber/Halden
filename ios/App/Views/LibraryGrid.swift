import HaldenKit
import SwiftUI
import UIKit

/// The photo grid. A collection view rather than a SwiftUI lazy grid: with tens of thousands of
/// photos it keeps every frame, reuses cells and asks for pictures before they scroll in. Pictures
/// come decoded and scaled from `ImagePipeline`, off the main thread.
struct LibraryGrid: UIViewControllerRepresentable {
    let assets: [LocalAsset]
    /// Changes whenever `assets` does; comparing 50,000 assets on every upload step would cost.
    let version: Int
    let uploads: [String: Double]
    let pipeline: ImagePipeline
    /// While choosing photos (to delete many at once), a tap selects instead of opening.
    var selection: Set<String>? = nil
    let open: (String) -> Void

    func makeUIViewController(context: Context) -> GridController {
        GridController(pipeline: pipeline, open: open)
    }

    func updateUIViewController(_ controller: GridController, context: Context) {
        controller.open = open
        controller.show(assets: assets, version: version, uploads: uploads, selection: selection)
    }
}

final class GridController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    static let spacing: CGFloat = 2
    static let minimumCell: CGFloat = 90

    let pipeline: ImagePipeline
    var open: (String) -> Void
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var assets: [String: LocalAsset] = [:]
    private var uploads: [String: Double] = [:]
    private var selection: Set<String>?
    private var shownVersion = -1

    init(pipeline: ImagePipeline, open: @escaping (String) -> Void) {
        self.pipeline = pipeline
        self.open = open
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: Self.layout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.accessibilityIdentifier = "library-grid"
        view.addSubview(collectionView)
        let registration = UICollectionView.CellRegistration<GridCell, String> { [weak self] cell, _, id in
            self?.configure(cell, id: id)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, path, id in
            view.dequeueConfiguredReusableCell(using: registration, for: path, item: id)
        }
    }

    /// As many columns as fit with at least `minimumCell` points each.
    static func layout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let columns = max(3, Int((width + spacing) / (minimumCell + spacing)))
            let item = NSCollectionLayoutItem(
                layoutSize: .init(
                    widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .fractionalHeight(1)))
            item.contentInsets = .init(top: 0, leading: spacing / 2, bottom: 0, trailing: spacing / 2)
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(
                    widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(1 / CGFloat(columns))),
                repeatingSubitem: item, count: columns)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            return section
        }
    }

    /// Pixels a cell needs for a sharp picture.
    private var cellPixels: Int {
        let width = collectionView.bounds.width
        let columns = max(3, Int((width + Self.spacing) / (Self.minimumCell + Self.spacing)))
        return Int((width / CGFloat(columns) * traitCollection.displayScale).rounded(.up))
    }

    func show(
        assets list: [LocalAsset], version: Int, uploads newUploads: [String: Double],
        selection newSelection: Set<String>?
    ) {
        guard dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        var changed = Set<String>()
        var reorder = false
        var animate = false
        if version != shownVersion {
            shownVersion = version
            var byId: [String: LocalAsset] = [:]
            byId.reserveCapacity(list.count)
            for asset in list {
                if let old = assets[asset.id], old != asset { changed.insert(asset.id) }
                byId[asset.id] = asset
            }
            assets = byId
            let ids = list.map(\.id)
            if snapshot.numberOfSections == 0 || ids != snapshot.itemIdentifiers {
                let before = snapshot.numberOfItems
                snapshot = NSDiffableDataSourceSnapshot()
                snapshot.appendSections([0])
                snapshot.appendItems(ids)
                reorder = true
                // Big jumps (first load, a full sync) without animation; single photos animate.
                animate = before > 0 && abs(ids.count - before) < 50
            }
        }
        for (id, progress) in newUploads where uploads[id] != progress { changed.insert(id) }
        for id in uploads.keys where newUploads[id] == nil { changed.insert(id) }
        uploads = newUploads
        if newSelection != selection {
            let before = selection ?? []
            let after = newSelection ?? []
            // Entering or leaving the choosing: every visible cell; else only the ones that changed.
            if (selection == nil) != (newSelection == nil) {
                changed.formUnion(
                    collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) })
            } else {
                changed.formUnion(before.symmetricDifference(after))
            }
            selection = newSelection
        }
        let shown = changed.filter { snapshot.indexOfItem($0) != nil }
        if !shown.isEmpty { snapshot.reconfigureItems(Array(shown)) }
        if reorder || !shown.isEmpty {
            dataSource.apply(snapshot, animatingDifferences: animate)
        }
    }

    private func configure(_ cell: GridCell, id: String) {
        guard let asset = assets[id] else { return }
        cell.show(asset: asset, upload: uploads[id], selected: selection.map { $0.contains(id) })
        let pixels = cellPixels
        if let image = pipeline.cached(asset, pixels: pixels) {
            cell.setImage(UIImage(cgImage: image.cgImage), for: id)
            return
        }
        cell.setImage(nil, for: id)
        cell.loading = Task { [pipeline] in
            guard let image = await pipeline.image(for: asset, pixels: pixels), !Task.isCancelled else { return }
            cell.setImage(UIImage(cgImage: image.cgImage), for: id)
        }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let soon = indexPaths.compactMap { dataSource.itemIdentifier(for: $0) }.compactMap { assets[$0] }
        pipeline.prefetch(soon, pixels: cellPixels)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        if let id = dataSource.itemIdentifier(for: indexPath) { open(id) }
    }
}

final class GridCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let badge = UIImageView()
    private let progress = ProgressRing()
    private let duration = UILabel()
    private let check = UIImageView()
    private(set) var shownId: String?
    var loading: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemFill
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        duration.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        duration.textColor = .white
        duration.shadowColor = .black.withAlphaComponent(0.6)
        duration.shadowOffset = CGSize(width: 0, height: 1)
        for view in [imageView, badge, progress, duration, check] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            badge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            badge.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            badge.widthAnchor.constraint(equalToConstant: 16),
            badge.heightAnchor.constraint(equalToConstant: 16),
            progress.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            progress.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            progress.widthAnchor.constraint(equalToConstant: 16),
            progress.heightAnchor.constraint(equalToConstant: 16),
            duration.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 5),
            duration.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
            check.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            check.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            check.widthAnchor.constraint(equalToConstant: 22),
            check.heightAnchor.constraint(equalToConstant: 22),
        ])
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loading?.cancel()
        loading = nil
        imageView.image = nil
    }

    /// `selected`: `nil` while not choosing.
    func show(asset: LocalAsset, upload: Double?, selected: Bool? = nil) {
        shownId = asset.id
        check.isHidden = selected == nil
        check.image = UIImage(systemName: selected == true ? "checkmark.circle.fill" : "circle")?
            .withConfiguration(
                UIImage.SymbolConfiguration(paletteColors: selected == true ? [.white, .systemBlue] : [.white]))
        imageView.alpha = selected == true ? 0.75 : 1
        accessibilityTraits = selected == true ? [.button, .selected] : [.button]
        accessibilityIdentifier = "photo-\(asset.id)"
        let state: String
        if asset.backedUp {
            badge.image = UIImage(systemName: "checkmark.circle.fill")?
                .withConfiguration(UIImage.SymbolConfiguration(paletteColors: [.white, .systemGreen]))
            badge.isHidden = false
            progress.isHidden = true
            state = "backed up"
        } else if let upload {
            badge.isHidden = true
            progress.isHidden = false
            progress.value = upload
            state = "uploading"
        } else {
            badge.image = UIImage(systemName: "icloud.slash")?
                .withConfiguration(UIImage.SymbolConfiguration(paletteColors: [.white]))
            badge.isHidden = false
            progress.isHidden = true
            state = "not backed up yet"
        }
        if asset.isVideo, let ms = asset.durationMs {
            duration.text = Duration.milliseconds(ms).formatted(.time(pattern: .minuteSecond))
            duration.isHidden = false
        } else {
            duration.isHidden = true
        }
        accessibilityLabel = "\(asset.isVideo ? "Video" : "Photo"), \(state)"
    }

    func setImage(_ image: UIImage?, for id: String) {
        guard id == shownId else { return }
        imageView.image = image
    }
}

/// A small circle that fills up as an upload goes.
final class ProgressRing: UIView {
    private let track = CAShapeLayer()
    private let bar = CAShapeLayer()

    var value: Double = 0 {
        didSet { bar.strokeEnd = CGFloat(max(0, min(1, value))) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for layer in [track, bar] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = 2.5
            self.layer.addSublayer(layer)
        }
        track.strokeColor = UIColor.white.withAlphaComponent(0.4).cgColor
        bar.strokeColor = UIColor.white.cgColor
        bar.lineCap = .round
        bar.strokeEnd = 0
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2 - 1.5,
            startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true)
        track.path = path.cgPath
        bar.path = path.cgPath
    }
}
