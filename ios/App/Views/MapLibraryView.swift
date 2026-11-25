import HaldenKit
import MapKit
import SwiftUI

/// Every photo with a place on a map, grouped (`MapClusters`): a picture and how many per
/// group, a tap shows them. Photos placed by estimate have a dashed frame; photos without a place
/// are a tap away.
struct MapLibraryView: View {
    @Environment(AppModel.self) private var app
    let open: ([String]) -> Void
    let withoutPlace: () -> Void
    @State private var points: [MapClusters.Point] = []

    var body: some View {
        PhotoMap(points: points, pipeline: app.pipeline, assets: { id in app.asset(id) }, open: open)
            .accessibilityIdentifier("photo-map")
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) {
                let missing = app.library.count - points.count
                if missing > 0 {
                    Button("\(missing) without a place", systemImage: "mappin.slash", action: withoutPlace)
                        .font(.footnote)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .background(.regularMaterial, in: .capsule)
                        .padding(.bottom, 150)
                        .accessibilityIdentifier("map-without-place")
                }
            }
            .task(id: app.libraryVersion) {
                let library = app.library
                points = await Task.detached { library.compactMap(\.mapPoint) }.value
            }
    }
}

/// The map itself (MapKit), with a group's picture and count as its pin.
struct PhotoMap: UIViewRepresentable {
    /// The room the library's floating switcher takes above the tab bar.
    static let switcherHeight: CGFloat = 52
    let points: [MapClusters.Point]
    let pipeline: ImagePipeline
    let assets: (String) -> LocalAsset?
    let open: ([String]) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = true
        // Apple's logo and "Legal" must stay visible: above the Library/Albums/Map switcher that
        // floats over the map's lower edge.
        map.layoutMargins.bottom = Self.switcherHeight
        map.register(GroupPin.self, forAnnotationViewWithReuseIdentifier: GroupPin.reuse)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard coordinator.points != points else { return }
        let first = coordinator.points.isEmpty
        coordinator.points = points
        if first, let region = MapClusters.region(showing: points) {
            map.setRegion(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: region.latitude, longitude: region.longitude),
                    span: MKCoordinateSpan(latitudeDelta: region.latitudeSpan, longitudeDelta: region.longitudeSpan)),
                animated: false)
        }
        coordinator.regroup(map)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: PhotoMap
        var points: [MapClusters.Point] = []
        private var grouping: Task<Void, Never>?

        init(parent: PhotoMap) {
            self.parent = parent
        }

        /// Groups again for what is shown now, away from the main thread; only pins that changed
        /// are replaced, so nothing flickers.
        func regroup(_ map: MKMapView) {
            grouping?.cancel()
            let region = MapClusters.Region(
                latitude: map.region.center.latitude, longitude: map.region.center.longitude,
                latitudeSpan: map.region.span.latitudeDelta, longitudeSpan: map.region.span.longitudeDelta)
            let points = points
            grouping = Task { [weak map] in
                let groups = await Task.detached { MapClusters.clusters(points, in: region) }.value
                guard !Task.isCancelled, let map else { return }
                let shown = map.annotations.compactMap { $0 as? Group }
                let wanted = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
                let gone = shown.filter { wanted[$0.cluster.id] != $0.cluster }
                let kept = Set(shown.filter { wanted[$0.cluster.id] == $0.cluster }.map(\.cluster.id))
                map.removeAnnotations(gone)
                map.addAnnotations(groups.filter { !kept.contains($0.id) }.map(Group.init))
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            regroup(mapView)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard let group = annotation as? Group else { return nil }
            let pin =
                mapView.dequeueReusableAnnotationView(withIdentifier: GroupPin.reuse, for: annotation) as? GroupPin
                ?? GroupPin(annotation: annotation, reuseIdentifier: GroupPin.reuse)
            pin.show(group.cluster)
            if let asset = parent.assets(group.cluster.newest) {
                let id = group.cluster.id
                if let cached = parent.pipeline.cached(asset, pixels: 160) {
                    pin.picture(UIImage(cgImage: cached.cgImage), for: id)
                } else {
                    let pipeline = parent.pipeline
                    Task { [weak pin] in
                        if let image = await pipeline.image(for: asset, pixels: 160) {
                            pin?.picture(UIImage(cgImage: image.cgImage), for: id)
                        }
                    }
                }
            }
            return pin
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: any MKAnnotation) {
            mapView.deselectAnnotation(annotation, animated: false)
            guard let group = annotation as? Group else { return }
            parent.open(group.cluster.ids)
        }
    }

    /// A group on the map.
    final class Group: NSObject, MKAnnotation {
        let cluster: MapClusters.Cluster
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: cluster.latitude, longitude: cluster.longitude)
        }
        var title: String? { "\(cluster.count) photos" }

        init(_ cluster: MapClusters.Cluster) {
            self.cluster = cluster
        }
    }

    /// A group's pin: its newest photo, with the count on it.
    final class GroupPin: MKAnnotationView {
        static let reuse = "group"
        private let imageView = UIImageView()
        private let count = UILabel()
        private let dashes = CAShapeLayer()
        private var shownId: String?

        override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
            super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
            frame = CGRect(x: 0, y: 0, width: 56, height: 56)
            imageView.frame = bounds
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 10
            imageView.layer.borderColor = UIColor.white.cgColor
            imageView.layer.borderWidth = 2
            imageView.backgroundColor = .secondarySystemBackground
            addSubview(imageView)
            dashes.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 10).cgPath
            dashes.fillColor = nil
            dashes.strokeColor = UIColor.systemOrange.cgColor
            dashes.lineWidth = 2
            dashes.lineDashPattern = [5, 3]
            layer.addSublayer(dashes)
            count.font = .systemFont(ofSize: 11, weight: .bold)
            count.textColor = .white
            count.backgroundColor = .systemBlue
            count.textAlignment = .center
            count.layer.cornerRadius = 9
            count.clipsToBounds = true
            addSubview(count)
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.25
            layer.shadowRadius = 3
            layer.shadowOffset = CGSize(width: 0, height: 1)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        func show(_ cluster: MapClusters.Cluster) {
            shownId = cluster.id
            imageView.image = nil
            count.text = cluster.count > 999 ? "\(cluster.count / 1000)k" : "\(cluster.count)"
            let width = max(20, count.intrinsicContentSize.width + 10)
            count.frame = CGRect(x: bounds.width - width + 6, y: -6, width: width, height: 18)
            count.isHidden = cluster.count < 2
            dashes.isHidden = !cluster.estimated
            isAccessibilityElement = true
            accessibilityLabel =
                "\(cluster.count) \(cluster.count == 1 ? "photo" : "photos")"
                + (cluster.estimated ? ", place estimated" : "")
            accessibilityIdentifier = "map-group"
        }

        func picture(_ image: UIImage, for id: String) {
            guard id == shownId else { return }
            imageView.image = image
        }
    }
}

/// The photos of one group on the map, like the library.
struct MapGroupView: View {
    @Environment(AppModel.self) private var app
    let ids: [String]
    let openPhoto: (String) -> Void
    @State private var photos: [LocalAsset] = []
    @State private var loaded = 0

    var body: some View {
        LibraryGrid(assets: photos, version: loaded, uploads: app.uploads, pipeline: app.pipeline) { id in
            openPhoto(id)
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("\(ids.count) \(ids.count == 1 ? "photo" : "photos")")
        .task(id: app.libraryVersion) {
            let wanted = Set(ids)
            photos = app.library.filter { wanted.contains($0.id) }
            loaded += 1
        }
    }
}
