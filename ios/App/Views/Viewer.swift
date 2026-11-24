import AVFoundation
import AVKit
import HaldenKit
import SwiftUI
import UIKit

/// Full screen: swipe between photos, pinch or double-tap to zoom, videos play. A picture never
/// jumps: the thumbnail is there at once, the preview fades in over it at the same size, and the
/// original follows when zoomed in.
struct ViewerPager: UIViewControllerRepresentable {
    let assets: [LocalAsset]
    let start: String
    let app: AppModel
    /// The photo shown now.
    let shown: (String) -> Void

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(
            transitionStyle: .scroll, navigationOrientation: .horizontal,
            options: [.interPageSpacing: 16])
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = .systemBackground
        pager.view.accessibilityIdentifier = "viewer"
        if let page = context.coordinator.page(for: start) {
            pager.setViewControllers([page], direction: .forward, animated: false)
        }
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.index = Dictionary(
            assets.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: ViewerPager
        var index: [String: Int]

        init(parent: ViewerPager) {
            self.parent = parent
            index = Dictionary(
                parent.assets.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        }

        func page(for id: String) -> PageController? {
            guard let position = index[id] else { return nil }
            return PageController(asset: parent.assets[position], app: parent.app)
        }

        private func neighbour(of controller: UIViewController, by step: Int) -> UIViewController? {
            guard let page = controller as? PageController, let position = index[page.asset.id] else { return nil }
            let next = position + step
            guard parent.assets.indices.contains(next) else { return nil }
            return PageController(asset: parent.assets[next], app: parent.app)
        }

        func pageViewController(_ pager: UIPageViewController, viewControllerBefore controller: UIViewController)
            -> UIViewController?
        {
            neighbour(of: controller, by: -1)
        }

        func pageViewController(_ pager: UIPageViewController, viewControllerAfter controller: UIViewController)
            -> UIViewController?
        {
            neighbour(of: controller, by: 1)
        }

        func pageViewController(
            _ pager: UIPageViewController, didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController], transitionCompleted completed: Bool
        ) {
            if completed, let page = pager.viewControllers?.first as? PageController { parent.shown(page.asset.id) }
        }
    }
}

/// One photo or video, full screen.
final class PageController: UIViewController, UIScrollViewDelegate {
    let asset: LocalAsset
    let app: AppModel
    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private var player: AVPlayerViewController?
    private var loading: Task<Void, Never>?
    private var hasOriginal = false

    init(asset: LocalAsset, app: AppModel) {
        self.asset = asset
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "page-\(asset.id)"
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        view.addSubview(scroll)
        imageView.frame = scroll.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = asset.isVideo ? "Video" : "Photo"
        scroll.addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(zoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        // The thumbnail at once, if it is decoded already.
        if let small = app.pipeline.cached(asset, pixels: 512) ?? app.pipeline.cached(asset, pixels: 300) {
            imageView.image = UIImage(cgImage: small.cgImage)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard loading == nil else { return }
        let pixels = Int(max(view.bounds.width, view.bounds.height) * traitCollection.displayScale)
        loading = Task { [weak self, asset, app] in
            if self?.imageView.image == nil, let small = await app.pipeline.image(for: asset, pixels: 512) {
                self?.show(small, fade: false)
            }
            if let preview = await app.media.preview(of: asset),
                let decoded = await Task.detached(operation: { ImagePipeline.decode(preview, pixels: pixels) }).value
            {
                self?.show(decoded, fade: true)
            } else if !asset.isVideo, let local = app.media.localOriginal(of: asset),
                let decoded = await Task.detached(operation: { ImagePipeline.decode(local, pixels: pixels) }).value
            {
                self?.show(decoded, fade: true)
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if asset.isVideo && player == nil { startVideo() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        player?.player?.pause()
    }

    private func show(_ image: DecodedImage, fade: Bool) {
        let new = UIImage(cgImage: image.cgImage)
        guard fade, imageView.image != nil else {
            imageView.image = new
            return
        }
        UIView.transition(with: imageView, duration: 0.2, options: .transitionCrossDissolve) {
            self.imageView.image = new
        }
    }

    private func startVideo() {
        let item: AVPlayerItem
        if let local = app.media.localOriginal(of: asset) {
            item = AVPlayerItem(url: local)
        } else if let stream = app.stream(asset) {
            item = AVPlayerItem(asset: stream)
        } else {
            return
        }
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(playerItem: item)
        controller.view.backgroundColor = .clear
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
        controller.view.accessibilityIdentifier = "video-player"
        player = controller
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        asset.isVideo ? nil : imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Zoomed in: the original, for every detail.
        guard scrollView.zoomScale > 1.5, !hasOriginal, !asset.isVideo else { return }
        hasOriginal = true
        Task { [weak self, asset, app] in
            guard let url = try? await app.media.original(of: asset),
                let decoded = await Task.detached(operation: { ImagePipeline.decode(url, pixels: 6000) }).value
            else { return }
            self?.show(decoded, fade: true)
        }
    }

    @objc private func zoom(_ gesture: UITapGestureRecognizer) {
        guard !asset.isVideo else { return }
        if scroll.zoomScale > 1 {
            scroll.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
            scroll.zoom(
                to: CGRect(
                    x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                animated: true)
        }
    }
}
