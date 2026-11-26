import AVFoundation
import AVKit
import HaldenKit
import PhotosUI
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

/// One photo or video, full screen. A Live Photo plays while it is held.
final class PageController: UIViewController, UIScrollViewDelegate, PHLivePhotoViewDelegate {
    /// As it is now (it changes when it is edited here).
    private(set) var asset: LocalAsset
    let app: AppModel
    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private var player: AVPlayerViewController?
    private var loading: Task<Void, Never>?
    private var hasOriginal = false
    private var liveView: PHLivePhotoView?
    private var liveBadge: UILabel?
    private var effectPlayer: AVQueuePlayer?
    private var effectLooper: AVPlayerLooper?
    private var effectLayer: AVPlayerLayer?
    private var effectTask: Task<Void, Never>?
    private var playbackObserver: NSObjectProtocol?
    private var editObserver: NSObjectProtocol?
    private var liveLoading: Task<PHLivePhoto?, Never>?

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
        if asset.isLivePhoto { addLive() }
        editObserver = NotificationCenter.default.addObserver(
            forName: .haldenEditChanged, object: nil, queue: .main
        ) { [weak self] note in
            let changedId = note.object as? String
            MainActor.assumeIsolated {
                guard let self, changedId == nil || changedId == self.asset.id else { return }
                self.edited()
            }
        }
        if asset.isSlowMotion { addBadge(symbol: "slowmo", text: "SLO-MO", label: "Slow motion") }
        if asset.isTimeLapse { addBadge(symbol: "timelapse", text: "TIME-LAPSE", label: "Time-lapse") }
        // The thumbnail at once, if it is decoded already.
        if let small = app.pipeline.cached(asset, pixels: 512) ?? app.pipeline.cached(asset, pixels: 300) {
            imageView.image = UIImage(cgImage: small.cgImage)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard loading == nil else { return }
        loadPictures()
    }

    /// Edited here: the new picture (or the video as edited), from the start.
    private func edited() {
        asset = app.asset(asset.id) ?? asset
        if asset.isVideo {
            if asset.isSlowMotion {
                playSlowly()
            } else if asset.edit != nil {
                playEdited()
            } else if let video = app.playable(asset) {
                player?.player?.replaceCurrentItem(with: AVPlayerItem(asset: video))
            }
            return
        }
        loading?.cancel()
        hasOriginal = false
        scroll.setZoomScale(1, animated: false)
        if asset.isLivePhoto {
            updateLiveBadge()
            refreshLiveEffectPlayback()
        }
        loadPictures()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        effectLayer?.frame = imageView.bounds
    }

    /// The thumbnail at once, then the preview (as edited) over it.
    private func loadPictures() {
        let pixels = Int(max(view.bounds.width, view.bounds.height) * traitCollection.displayScale)
        loading = Task { [weak self, asset, app] in
            if self?.imageView.image == nil, let small = await app.pipeline.image(for: asset, pixels: 512) {
                self?.show(small, fade: false)
            }
            let edit = asset.isVideo ? nil : asset.edit
            if let preview = await app.media.preview(of: asset),
                let decoded = await Task.detached(operation: {
                    ImagePipeline.decode(preview, pixels: pixels, edit: edit)
                }).value
            {
                self?.show(decoded, fade: true)
            } else if !asset.isVideo, let local = app.media.localOriginal(of: asset),
                let decoded = await Task.detached(operation: { ImagePipeline.decode(local, pixels: pixels, edit: edit) }
                )
                .value
            {
                self?.show(decoded, fade: true)
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if asset.isVideo && player == nil { startVideo() }
        if asset.isLivePhoto { refreshLiveEffectPlayback() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        player?.player?.pause()
        effectPlayer?.pause()
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

    // MARK: Live Photos

    private func addLive() {
        let live = PHLivePhotoView(frame: imageView.bounds)
        live.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        live.contentMode = .scaleAspectFit
        live.isUserInteractionEnabled = false
        live.alpha = 0
        live.delegate = self
        imageView.addSubview(live)
        liveView = live
        let press = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        press.minimumPressDuration = 0.25
        scroll.addGestureRecognizer(press)

        liveBadge = addBadge(
            symbol: asset.activeLiveEffect.symbol, text: asset.activeLiveEffect.title.uppercased(),
            label: Self.liveBadgeLabel(for: asset.activeLiveEffect), id: "live-badge")
    }

    private static func liveBadgeLabel(for effect: LivePhotoEffect) -> String {
        switch effect {
        case .live: "Live Photo, touch and hold to play"
        case .loop: "Loop Live Photo"
        case .bounce: "Bounce Live Photo"
        case .longExposure: "Long Exposure Live Photo"
        }
    }

    private func updateLiveBadge() {
        guard let badge = liveBadge else { return }
        let effect = asset.activeLiveEffect
        let content = NSMutableAttributedString(
            attachment: NSTextAttachment(
                image: UIImage(systemName: effect.symbol)!.withTintColor(.label, renderingMode: .alwaysOriginal)))
        content.append(
            NSAttributedString(
                string: " \(effect.title.uppercased())",
                attributes: [.font: UIFont.systemFont(ofSize: 12, weight: .semibold)]))
        badge.attributedText = content
        badge.accessibilityLabel = Self.liveBadgeLabel(for: effect)
        badge.invalidateIntrinsicContentSize()
    }

    private func stopEffectPlayer() {
        effectTask?.cancel()
        effectTask = nil
        effectPlayer?.pause()
        effectLooper?.disableLooping()
        effectLooper = nil
        effectPlayer = nil
        effectLayer?.removeFromSuperlayer()
        effectLayer = nil
    }

    /// Plays Loop/Bounce MP4 seamlessly or displays Long Exposure / Key Photo derived still.
    private func refreshLiveEffectPlayback() {
        stopEffectPlayer()
        let current = app.asset(asset.id) ?? asset
        asset = current
        let effect = current.activeLiveEffect
        guard effect != .live || current.edit?.liveKeyFrameMs != nil else { return }
        effectTask = Task { [weak self, current, app] in
            guard let url = try? await app.media.liveEffect(of: current) else { return }
            guard !Task.isCancelled, let self else { return }
            if effect.isVideoOutput {
                let item = AVPlayerItem(url: url)
                let queue = AVQueuePlayer()
                queue.isMuted = true
                let looper = AVPlayerLooper(player: queue, templateItem: item)
                let layer = AVPlayerLayer(player: queue)
                layer.frame = self.imageView.bounds
                layer.videoGravity = .resizeAspect
                self.imageView.layer.addSublayer(layer)
                self.effectPlayer = queue
                self.effectLooper = looper
                self.effectLayer = layer
                queue.play()
            } else {
                let pixels = Int(
                    max(self.view.bounds.width, self.view.bounds.height) * self.traitCollection.displayScale)
                if let decoded = await Task.detached(operation: {
                    ImagePipeline.decode(url, pixels: pixels, edit: nil)
                }).value {
                    self.show(decoded, fade: true)
                }
            }
        }
    }

    /// What kind of photo or video this is, top left.
    @discardableResult
    private func addBadge(symbol: String, text: String, label: String, id: String = "kind-badge") -> UILabel {
        let badge = UILabel()
        let content = NSMutableAttributedString(
            attachment: NSTextAttachment(
                image: UIImage(systemName: symbol)!.withTintColor(.label, renderingMode: .alwaysOriginal)))
        content.append(
            NSAttributedString(
                string: " \(text)", attributes: [.font: UIFont.systemFont(ofSize: 12, weight: .semibold)]))
        badge.attributedText = content
        badge.backgroundColor = .systemBackground.withAlphaComponent(0.7)
        badge.layer.cornerRadius = 6
        badge.clipsToBounds = true
        badge.textAlignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.accessibilityLabel = label
        badge.accessibilityIdentifier = id
        view.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            badge.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            badge.heightAnchor.constraint(equalToConstant: 24),
        ])
        badge.layoutMargins = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        badge.widthAnchor.constraint(greaterThanOrEqualToConstant: badge.intrinsicContentSize.width + 16).isActive =
            true
        return badge
    }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            Task { [weak self] in
                guard let self, let live = await self.loadLive(), gesture.state == .began || gesture.state == .changed
                else { return }
                self.liveView?.livePhoto = live
                self.liveView?.startPlayback(with: .full)
            }
        case .ended, .cancelled, .failed:
            liveView?.stopPlayback()
        default:
            break
        }
    }

    /// The photo and its video, on this iPhone or fetched once, put together as a Live Photo.
    private func loadLive() async -> PHLivePhoto? {
        if let liveLoading { return await liveLoading.value }
        let task = Task { [asset, app, placeholder = imageView.image] () -> PHLivePhoto? in
            guard let photo = try? await app.media.original(of: asset),
                let video = try? await app.media.pairedVideo(of: asset)
            else { return nil }
            return await withCheckedContinuation { continuation in
                let once = Once()
                PHLivePhoto.request(
                    withResourceFileURLs: [photo, video], placeholderImage: placeholder, targetSize: .zero,
                    contentMode: .aspectFit
                ) { live, info in
                    let degraded = info[PHLivePhotoInfoIsDegradedKey] as? Bool ?? false
                    let failed = info[PHLivePhotoInfoErrorKey] != nil || info[PHLivePhotoInfoCancelledKey] != nil
                    guard failed || (live != nil && !degraded) else { return }
                    if once.first() { continuation.resume(returning: failed ? nil : live) }
                }
            }
        }
        liveLoading = task
        let live = await task.value
        if live == nil { liveLoading = nil }
        return live
    }

    func livePhotoView(
        _ livePhotoView: PHLivePhotoView, willBeginPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle
    ) {
        livePhotoView.alpha = 1
    }

    func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle)
    {
        UIView.animate(withDuration: 0.2) { livePhotoView.alpha = 0 }
    }

    private func startVideo() {
        guard let video = app.playable(asset) else { return }
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(playerItem: AVPlayerItem(asset: video))
        controller.view.backgroundColor = .clear
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
        controller.view.accessibilityIdentifier = "video-player"
        player = controller
        if asset.edit != nil && !asset.isSlowMotion { playEdited() }
        if asset.isSlowMotion {
            playSlowly()
            playbackObserver = NotificationCenter.default.addObserver(
                forName: .haldenPlaybackChanged, object: nil, queue: .main
            ) { [weak self] note in
                let changedId = note.object as? String
                MainActor.assumeIsolated {
                    guard let self, changedId == nil || changedId == self.asset.id else { return }
                    self.playSlowly()
                }
            }
        }
    }

    /// A slow-motion video with its slow part (as it is now): the sound slows down with it.
    private func playSlowly() {
        Task { [weak self, asset, app] in
            guard let current = app.asset(asset.id) ?? Optional(asset), let video = app.playable(current) else {
                return
            }
            let slow = await app.slowMotion(of: current)
            let item: AVPlayerItem
            if let edit = current.edit, let edited = try? await Retiming.edited(video, edit: edit, slow: slow) {
                item = AVPlayerItem(asset: edited.composition)
                item.videoComposition = edited.video
            } else if let played = try? await Retiming.slowMotion(video, slow: slow) {
                item = AVPlayerItem(asset: played)
            } else {
                return
            }
            item.audioTimePitchAlgorithm = .varispeed
            self?.player?.player?.replaceCurrentItem(with: item)
        }
    }

    /// An edited video: trimmed, with its light and colour.
    private func playEdited() {
        Task { [weak self, asset, app] in
            guard let current = app.asset(asset.id) ?? Optional(asset), let edit = current.edit,
                let video = app.playable(current), let edited = try? await Retiming.edited(video, edit: edit)
            else { return }
            let item = AVPlayerItem(asset: edited.composition)
            item.videoComposition = edited.video
            self?.player?.player?.replaceCurrentItem(with: item)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        asset.isVideo ? nil : imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Zoomed in: the original, for every detail.
        guard scrollView.zoomScale > 1.5, !hasOriginal, !asset.isVideo else { return }
        hasOriginal = true
        Task { [weak self, asset, app] in
            let edit = asset.edit
            guard let url = try? await app.media.original(of: asset),
                let decoded = await Task.detached(operation: { ImagePipeline.decode(url, pixels: 6000, edit: edit) })
                    .value
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

/// True the first time only: for callbacks that may come more than once.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
