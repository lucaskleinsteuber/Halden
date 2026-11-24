import HaldenKit
import MapKit
import SwiftUI

/// A photo or video full screen, with info and sharing.
struct PhotoView: View {
    @Environment(AppModel.self) private var app
    let start: String
    let assets: [LocalAsset]
    @State private var current: String
    @State private var showInfo = false
    @State private var sharing: SharedFile?
    @State private var preparing = false
    @State private var problem: String?
    @State private var confirmDelete = false
    @State private var editingSlowMotion = false
    @State private var addingToAlbum: ChosenPhotos?
    @Environment(\.dismiss) private var dismiss

    init(start: String, assets: [LocalAsset]) {
        self.start = start
        self.assets = assets
        _current = State(initialValue: start)
    }

    private var asset: LocalAsset? { app.asset(current) }

    var body: some View {
        ViewerPager(assets: assets, start: start, app: app) { current = $0 }
            .ignoresSafeArea()
            .navigationTitle(asset.map { TakenAt.text($0.takenAt, offset: $0.timeZoneOffsetMinutes) } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            // Full screen: the tab bar would cover the middle of the bottom bar.
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Menu {
                        Button("Original") { share(.original) }
                        Button("With corrected time and place") { share(.corrected) }
                        Button("In the preferred format") { share(.preferred) }
                        if asset?.isSlowMotion == true {
                            Button("As played, slowed down") { share(.asPlayed) }
                        }
                        Divider()
                        Button("Add to album…", systemImage: "rectangle.stack.badge.plus") {
                            addingToAlbum = ChosenPhotos(ids: [current])
                        }
                        .accessibilityIdentifier("photo-add-to-album")
                    } label: {
                        if preparing { ProgressView() } else { Image(systemName: "square.and.arrow.up") }
                    }
                    .accessibilityLabel("Share")
                    .accessibilityIdentifier("share")
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        confirmDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete")
                    .accessibilityIdentifier("delete")
                }
                if asset?.isSlowMotion == true {
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            editingSlowMotion = true
                        } label: {
                            Image(systemName: "slowmo")
                        }
                        .accessibilityLabel("Slow part")
                        .accessibilityIdentifier("slow-motion")
                    }
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        showInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Info")
                    .accessibilityIdentifier("info")
                }
            }
            .confirmationDialog("Delete this photo?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete everywhere", role: .destructive) {
                    app.moveToTrash([current])
                    dismiss()
                }
                .accessibilityIdentifier("delete-everywhere")
                if let asset, asset.backedUp, asset.localFile != nil {
                    Button("Remove from this iPhone only") {
                        if app.removeFromPhone([current]) == 0 {
                            problem = "Not yet: its preview isn't on this iPhone. Try again in a moment."
                        }
                    }
                    .accessibilityIdentifier("remove-from-phone")
                }
            } message: {
                Text(
                    "Everywhere: it goes to the trash on the server and on all devices, and can be restored for \(app.trashDays) days. From this iPhone only: the server keeps it, and it stays in your library."
                )
            }
            .sheet(isPresented: $showInfo) { InfoView(id: current) }
            .sheet(item: $addingToAlbum) { chosen in AlbumPicker(assetIds: chosen.ids) }
            .sheet(isPresented: $editingSlowMotion) {
                if let asset { SlowMotionEditor(asset: asset) }
            }
            .sheet(item: $sharing) { file in ShareSheet(items: file.urls) }
            .alert("Can't share", isPresented: .constant(problem != nil)) {
                Button("OK") { problem = nil }
            } message: {
                Text(problem ?? "")
            }
    }

    private func share(_ kind: AppModel.ShareKind) {
        guard let asset else { return }
        preparing = true
        Task {
            defer { preparing = false }
            do {
                sharing = SharedFile(urls: try await app.filesToShare(asset, as: kind))
            } catch let error as APIError where error.status == 404 {
                problem = "There is no copy in the preferred format. Choose one in Settings › Formats."
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// One file to share, or a Live Photo's photo and video.
struct SharedFile: Identifiable {
    let urls: [URL]
    var id: [URL] { urls }
}

/// The system's share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum TakenAt {
    /// The time a photo was taken, in the time zone where it was taken.
    static func text(_ takenAt: Int64, offset: Int?, style: Date.FormatStyle.DateStyle = .abbreviated) -> String {
        var format = Date.FormatStyle(date: style, time: .shortened)
        if let offset, let zone = TimeZone(secondsFromGMT: offset * 60) { format.timeZone = zone }
        return Date(timeIntervalSince1970: Double(takenAt) / 1000).formatted(format)
    }

    static func zone(_ offset: Int?) -> String {
        guard let offset else { return "this iPhone's time zone" }
        return String(format: "UTC%@%02d:%02d", offset < 0 ? "−" : "+", abs(offset) / 60, abs(offset) % 60)
    }
}

/// Everything about one photo, in three layers: as shown (with corrections), as it was taken,
/// and as the server keeps it.
struct InfoView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var detail: AssetDetail?
    @State private var correcting = false

    var body: some View {
        NavigationStack {
            List {
                if let asset = app.asset(id) {
                    shown(asset)
                    original
                    corrections(asset)
                    server(asset)
                } else {
                    Text("This photo is gone.")
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: app.libraryVersion) { detail = try? await app.detail(id) }
            .sheet(isPresented: $correcting) {
                if let asset = app.asset(id) { CorrectionView(asset: asset) }
            }
        }
    }

    @ViewBuilder private func shown(_ asset: LocalAsset) -> some View {
        Section("As shown") {
            if let title = asset.title { LabeledContent("Title", value: title).accessibilityIdentifier("info-title") }
            if let description = asset.description { Text(description) }
            LabeledContent(
                "Taken", value: TakenAt.text(asset.takenAt, offset: asset.timeZoneOffsetMinutes, style: .long))
            LabeledContent("Time zone", value: TakenAt.zone(asset.timeZoneOffsetMinutes))
            if let latitude = asset.latitude, let longitude = asset.longitude {
                PlaceMap(
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    accuracy: asset.locationAccuracy, heading: asset.heading
                )
                .frame(height: 200)
                .listRowInsets(EdgeInsets())
                LabeledContent("Place", value: String(format: "%.5f, %.5f", latitude, longitude))
                if let accuracy = asset.locationAccuracy {
                    LabeledContent(
                        "Accuracy",
                        value: "± \(Int(accuracy.rounded())) m"
                            + (CapturePlace.imprecise(accuracy: accuracy, settings: app.settings) ? " (imprecise)" : "")
                    )
                }
                if let heading = asset.heading { LabeledContent("Facing", value: "\(Int(heading.rounded()))°") }
                LabeledContent("Place from", value: Self.source(asset.locationSource))
            } else {
                LabeledContent("Place", value: "none")
            }
            if let width = asset.width, let height = asset.height {
                LabeledContent("Size", value: "\(width) × \(height)")
            }
            if let duration = asset.durationMs {
                LabeledContent(
                    "Length", value: Duration.milliseconds(duration).formatted(.time(pattern: .minuteSecond)))
            }
            if let kind = asset.isLivePhoto
                ? "Live Photo" : asset.isSlowMotion ? "Slow motion" : asset.isTimeLapse ? "Time-lapse" : nil
            {
                LabeledContent("Taken as", value: kind)
            }
            if let slow = asset.playback {
                LabeledContent(
                    "Slow part",
                    value:
                        "\(SlowMotionEditor.seconds(slow.slowFromMs))–\(SlowMotionEditor.seconds(slow.slowToMs)), \(Int((1 / slow.rate).rounded()))× slower"
                )
            }
            Button("Correct…") { correcting = true }.accessibilityIdentifier("correct")
        }
    }

    @ViewBuilder private var original: some View {
        if let detail {
            Section("As taken") {
                if let original = detail.original {
                    if let takenAt = original.takenAt {
                        LabeledContent(
                            "Taken", value: TakenAt.text(takenAt, offset: original.timeZoneOffsetMinutes, style: .long))
                    }
                    LabeledContent("Time from", value: Self.source(original.takenAtSource))
                    if let place = original.location {
                        LabeledContent("Place", value: String(format: "%.5f, %.5f", place.latitude, place.longitude))
                    }
                }
                if let camera = detail.asset.camera {
                    if let model = camera.model {
                        LabeledContent("Camera", value: [camera.make, model].compactMap { $0 }.joined(separator: " "))
                    }
                    if let lens = camera.lens { LabeledContent("Lens", value: lens) }
                }
                ForEach(detail.exif.keys.sorted(), id: \.self) { key in
                    LabeledContent(key, value: detail.exif[key] ?? "")
                }
            }
        }
    }

    @ViewBuilder private func corrections(_ asset: LocalAsset) -> some View {
        if let edits = detail?.edits, !edits.isEmpty {
            Section("Corrections") {
                ForEach(Array(edits.enumerated()), id: \.offset) { _, edit in
                    LabeledContent(edit.field, value: TakenAt.text(edit.at, offset: nil))
                }
                Button("Back to the time and place as taken") {
                    app.correct(asset.id, AssetCorrection(restore: ["takenAt", "location"]))
                }
            }
        }
    }

    @ViewBuilder private func server(_ asset: LocalAsset) -> some View {
        Section("On the server") {
            LabeledContent("Backed up", value: asset.backedUp ? "yes" : "not yet")
            if let sha = asset.originalSha256 {
                LabeledContent("Checksum") {
                    Text(sha.prefix(16) + "…").font(.system(.caption, design: .monospaced))
                }
            }
            LabeledContent("On this iPhone", value: asset.localFile == nil ? "no" : "yes")
            if let files = detail?.asset.files {
                ForEach(files, id: \.role) { file in
                    LabeledContent(
                        Self.role(file.role),
                        value:
                            "\(file.mimeType) · \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))"
                    )
                }
            }
        }
    }

    static func source(_ source: String?) -> String {
        switch source {
        case "client": "this iPhone"
        case "exif": "the file"
        case "manual": "corrected"
        case "estimated": "estimated from a photo nearby"
        case "upload": "the time of upload"
        default: source ?? "unknown"
        }
    }

    static func role(_ role: String) -> String {
        switch role {
        case "original": "Original"
        case "thumbnail": "Thumbnail"
        case "preview": "Preview"
        case "converted": "Preferred format"
        case "paired_video": "Live Photo video"
        default: role
        }
    }
}

/// Where a photo was taken: the place, how precisely (a circle), and which way the camera faced.
struct PlaceMap: View {
    let coordinate: CLLocationCoordinate2D
    let accuracy: Double?
    let heading: Double?

    var body: some View {
        Map(
            initialPosition: .region(
                MKCoordinateRegion(center: coordinate, latitudinalMeters: 800, longitudinalMeters: 800))
        ) {
            if let accuracy { MapCircle(center: coordinate, radius: accuracy).foregroundStyle(.blue.opacity(0.15)) }
            Annotation("", coordinate: coordinate) {
                Image(systemName: heading == nil ? "circle.fill" : "location.north.fill")
                    .foregroundStyle(.blue)
                    .rotationEffect(.degrees(heading ?? 0))
            }
        }
    }
}

/// Correct time, time zone, title, description and place. The original values stay on the
/// server and can be brought back.
struct CorrectionView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let asset: LocalAsset
    @State private var takenAt: Date
    @State private var offset: Int
    @State private var title: String
    @State private var text: String
    @State private var place: CLLocationCoordinate2D?

    init(asset: LocalAsset) {
        self.asset = asset
        _takenAt = State(initialValue: Date(timeIntervalSince1970: Double(asset.takenAt) / 1000))
        _offset = State(initialValue: asset.timeZoneOffsetMinutes ?? TimeZone.current.secondsFromGMT() / 60)
        _title = State(initialValue: asset.title ?? "")
        _text = State(initialValue: asset.description ?? "")
        _place = State(
            initialValue: asset.latitude.flatMap { latitude in
                asset.longitude.map { CLLocationCoordinate2D(latitude: latitude, longitude: $0) }
            })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Time") {
                    DatePicker("Taken", selection: $takenAt)
                        .environment(\.timeZone, TimeZone(secondsFromGMT: offset * 60) ?? .current)
                    Picker("Time zone", selection: $offset) {
                        ForEach(Array(stride(from: -12 * 60, through: 14 * 60, by: 15)), id: \.self) { minutes in
                            Text(TakenAt.zone(minutes)).tag(minutes)
                        }
                    }
                }
                Section("Title and description") {
                    TextField("Title", text: $title).accessibilityIdentifier("title-field")
                    TextField("Description", text: $text, axis: .vertical).lineLimit(2...6)
                }
                Section {
                    PlacePicker(place: $place).frame(height: 260).listRowInsets(EdgeInsets())
                    if place != nil {
                        Button("Remove the place", role: .destructive) { place = nil }
                    }
                } header: {
                    Text("Place")
                } footer: {
                    Text("Tap the map where the photo was taken.")
                }
            }
            .navigationTitle("Correct")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        app.correct(asset.id, correction)
                        dismiss()
                    }
                    .accessibilityIdentifier("save-correction")
                }
            }
        }
    }

    /// Only what changed.
    private var correction: AssetCorrection {
        var correction = AssetCorrection()
        let milliseconds = Int64((takenAt.timeIntervalSince1970 * 1000).rounded())
        if milliseconds != asset.takenAt { correction.takenAt = .set(milliseconds) }
        if offset != asset.timeZoneOffsetMinutes { correction.timeZoneOffsetMinutes = .set(offset) }
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if newTitle != (asset.title ?? "") { correction.title = newTitle.isEmpty ? .clear : .set(newTitle) }
        let newText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if newText != (asset.description ?? "") { correction.description = newText.isEmpty ? .clear : .set(newText) }
        if place?.latitude != asset.latitude || place?.longitude != asset.longitude {
            correction.location =
                place.map { .set(CorrectedLocation(latitude: $0.latitude, longitude: $0.longitude)) } ?? .clear
        }
        return correction
    }
}

/// A map to tap a place on.
struct PlacePicker: View {
    @Binding var place: CLLocationCoordinate2D?
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let place { Marker("Here", coordinate: place) }
                UserAnnotation()
            }
            .onTapGesture { point in
                if let coordinate = proxy.convert(point, from: .local) { place = coordinate }
            }
            .onAppear {
                if let place {
                    camera = .region(
                        MKCoordinateRegion(center: place, latitudinalMeters: 2000, longitudinalMeters: 2000))
                } else {
                    camera = .userLocation(fallback: .automatic)
                }
            }
        }
    }
}
