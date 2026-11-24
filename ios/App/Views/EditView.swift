import AVFoundation
import CoreImage
import HaldenKit
import SwiftUI

/// Editing a photo or video: light, colour, turning, straightening and cropping (videos: light,
/// colour and trimming). Only what is set is kept; the original stays, and "Original" goes back
/// to it any time. The picture follows every slider at once (Core Image on the GPU).
struct EditView: View {
    enum Tool: String, CaseIterable, Identifiable {
        case light = "Light"
        case colour = "Colour"
        case shape = "Crop"
        case trim = "Trim"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let asset: LocalAsset
    @State private var recipe: EditRecipe
    @State private var tool = Tool.light
    @State private var base: CIImage?
    @State private var shown: CGImage?
    @State private var problem: String?
    @State private var aspect: Double?

    init(asset: LocalAsset) {
        self.asset = asset
        _recipe = State(initialValue: asset.edit ?? EditRecipe())
    }

    private var tools: [Tool] { asset.isVideo ? [.light, .colour, .trim] : [.light, .colour, .shape] }
    private var durationMs: Int64 { max(asset.durationMs ?? 1000, 200) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                picture
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Picker("Tool", selection: $tool) {
                    ForEach(tools) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .accessibilityIdentifier("edit-tool")
                controls
                    .frame(height: 220)
            }
            .background(Color.black)
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        app.setEdit(asset.id, recipe.isEmpty ? nil : recipe.fitted)
                        dismiss()
                    }
                    .accessibilityIdentifier("save-edit")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Original") { recipe = EditRecipe() }
                        .disabled(recipe.isEmpty)
                        .accessibilityIdentifier("edit-original")
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("Auto", systemImage: "wand.and.stars") { automatic() }
                        .disabled(base == nil)
                        .accessibilityIdentifier("edit-auto")
                }
            }
            .task { await load() }
            .task(id: rendering) { await render() }
            .alert("Can't edit", isPresented: .constant(problem != nil)) {
                Button("OK") { dismiss() }
            } message: {
                Text(problem ?? "")
            }
        }
    }

    /// While cropping, the whole picture with the crop on it; otherwise the result.
    private var rendering: EditRecipe {
        var shownRecipe = recipe
        if tool == .shape { shownRecipe.crop = nil }
        shownRecipe.trimStartMs = nil
        shownRecipe.trimEndMs = nil
        return shownRecipe
    }

    @ViewBuilder private var picture: some View {
        if let shown {
            GeometryReader { geometry in
                let size = CGSize(width: shown.width, height: shown.height)
                let fitted = Self.fit(size, in: geometry.size)
                Image(decorative: shown, scale: 1)
                    .resizable()
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .overlay {
                        if tool == .shape {
                            CropOverlay(crop: cropBinding, aspect: aspect, imageSize: size)
                                .frame(width: fitted.width, height: fitted.height)
                                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        }
                    }
            }
            .padding(12)
            .accessibilityElement()
            .accessibilityLabel("The edited picture")
            .accessibilityIdentifier("edit-picture")
        } else {
            ProgressView().tint(.white)
        }
    }

    static func fit(_ size: CGSize, in space: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return space }
        let scale = min(space.width / size.width, space.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private var cropBinding: Binding<EditRecipe.Crop> {
        Binding(
            get: { recipe.crop ?? EditRecipe.Crop(x: 0, y: 0, width: 1, height: 1) },
            set: { crop in
                recipe.crop =
                    crop.x == 0 && crop.y == 0 && crop.width >= 0.999 && crop.height >= 0.999 ? nil : crop.fitted
            })
    }

    @ViewBuilder private var controls: some View {
        ScrollView {
            VStack(spacing: 14) {
                switch tool {
                case .light:
                    slider("Exposure", \.exposure, range: -3...3)
                    slider("Brightness", \.brightness)
                    slider("Contrast", \.contrast)
                    slider("Highlights", \.highlights)
                    slider("Shadows", \.shadows)
                case .colour:
                    slider("Saturation", \.saturation)
                    slider("Vibrance", \.vibrance)
                    slider("Warmth", \.warmth)
                    slider("Tint", \.tint)
                case .shape:
                    HStack {
                        Button("Turn", systemImage: "rotate.right") {
                            recipe.quarterTurns = (recipe.quarterTurns + 1) % 4
                        }
                        .accessibilityIdentifier("edit-turn")
                        Spacer()
                        Menu("Shape: \(aspectName)") {
                            Button("Free") { setAspect(nil) }
                            Button("Square") { setAspect(1) }
                            Button("4:3") { setAspect(4.0 / 3) }
                            Button("3:4") { setAspect(3.0 / 4) }
                            Button("16:9") { setAspect(16.0 / 9) }
                        }
                    }
                    slider("Straighten", \.straighten, range: -45...45)
                case .trim:
                    trimSliders
                }
            }
            .padding(.horizontal, 20)
        }
        .foregroundStyle(.white)
        .tint(.yellow)
    }

    private var aspectName: String {
        switch aspect {
        case nil: "Free"
        case 1: "Square"
        case let value? where abs(value - 4.0 / 3) < 0.01: "4:3"
        case let value? where abs(value - 3.0 / 4) < 0.01: "3:4"
        default: "16:9"
        }
    }

    /// A shape for the crop: the biggest of that shape in the middle of the picture.
    private func setAspect(_ ratio: Double?) {
        aspect = ratio
        guard let ratio, let shown else { return }
        let imageRatio = Double(shown.width) / Double(shown.height)
        var width = 1.0
        var height = imageRatio / ratio
        if height > 1 {
            height = 1
            width = ratio / imageRatio
        }
        recipe.crop = EditRecipe.Crop(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    private func slider(
        _ title: String, _ keyPath: WritableKeyPath<EditRecipe, Double>, range: ClosedRange<Double> = -1...1
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.footnote)
                Spacer()
                Text(
                    recipe[keyPath: keyPath].formatted(.number.precision(.fractionLength(range.upperBound > 1 ? 1 : 2)))
                )
                .font(.footnote.monospacedDigit())
                .foregroundStyle(recipe[keyPath: keyPath] == 0 ? .secondary : Color.yellow)
            }
            Slider(value: $recipe[dynamicMember: keyPath], in: range)
                .accessibilityIdentifier("edit-\(title.lowercased())")
                .onTapGesture(count: 2) { recipe[keyPath: keyPath] = 0 }
        }
    }

    @ViewBuilder private var trimSliders: some View {
        let start = Binding(
            get: { Double(recipe.trimStartMs ?? 0) },
            set: { recipe.trimStartMs = $0 <= 0 ? nil : Int64($0) })
        let end = Binding(
            get: { Double(recipe.trimEndMs ?? durationMs) },
            set: { recipe.trimEndMs = $0 >= Double(durationMs) ? nil : Int64($0) })
        VStack(alignment: .leading, spacing: 2) {
            Text("Start: \(SlowMotionEditor.seconds(recipe.trimStartMs ?? 0))").font(.footnote)
            Slider(value: start, in: 0...Double(durationMs)).accessibilityIdentifier("trim-start")
            Text("End: \(SlowMotionEditor.seconds(recipe.trimEndMs ?? durationMs))").font(.footnote)
            Slider(value: end, in: 0...Double(durationMs)).accessibilityIdentifier("trim-end")
        }
    }

    // MARK: Pictures

    /// The picture to edit: the preview (about 2048 px) or, for a video, its first frame.
    private func load() async {
        let edge = 1600
        if asset.isVideo {
            guard let video = app.playable(asset) else {
                problem = "The video isn't here and the server can't be reached."
                return
            }
            let generator = AVAssetImageGenerator(asset: video)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: edge, height: edge)
            if let frame = try? await generator.image(at: .zero).image {
                base = CIImage(cgImage: frame)
            }
        } else if let preview = await app.media.preview(of: asset),
            let decoded = await Task.detached(operation: { ImagePipeline.decode(preview, pixels: edge) }).value
        {
            base = CIImage(cgImage: decoded.cgImage)
        } else if let original = try? await app.media.original(of: asset),
            let decoded = await Task.detached(operation: { ImagePipeline.decode(original, pixels: edge) }).value
        {
            base = CIImage(cgImage: decoded.cgImage)
        }
        if base == nil { problem = "The photo isn't here and the server can't be reached." }
        await render()
    }

    private func render() async {
        guard let base else { return }
        let recipe = rendering
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let edited = EditRenderer.apply(recipe, to: base)
            return EditContext.shared.createCGImage(edited, from: edited.extent)
        }.value
        if let image, !Task.isCancelled { shown = image }
    }

    private func automatic() {
        guard let base else { return }
        let suggested = EditRenderer.automatic(for: base, context: EditContext.shared)
        recipe.exposure = suggested.exposure
        recipe.contrast = suggested.contrast
        recipe.vibrance = suggested.vibrance
        recipe.shadows = suggested.shadows
        recipe.highlights = suggested.highlights
    }
}

/// One Core Image context for editing (it keeps its GPU resources).
enum EditContext {
    static var shared: CIContext { ImagePipeline.editContext }
}

/// The crop on the picture: drag a corner to change it, the inside to move it. With a shape
/// chosen, corners keep it.
struct CropOverlay: View {
    @Binding var crop: EditRecipe.Crop
    let aspect: Double?
    let imageSize: CGSize
    @State private var start: EditRecipe.Crop?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let rect = CGRect(
                x: crop.x * size.width, y: crop.y * size.height, width: crop.width * size.width,
                height: crop.height * size.height)
            ZStack(alignment: .topLeading) {
                // Outside the crop darker.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(rect)
                }
                .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                Rectangle()
                    .strokeBorder(.white, lineWidth: 1.5)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .contentShape(.rect)
                    .gesture(move(size))
                ForEach(0..<4, id: \.self) { corner in
                    Circle()
                        .fill(.white)
                        .frame(width: 22, height: 22)
                        .position(
                            x: corner % 2 == 0 ? rect.minX : rect.maxX, y: corner < 2 ? rect.minY : rect.maxY
                        )
                        .gesture(resize(corner, size))
                        .accessibilityIdentifier("crop-corner-\(corner)")
                }
            }
        }
    }

    private func move(_ size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { drag in
                let from = start ?? crop
                start = from
                crop =
                    EditRecipe.Crop(
                        x: from.x + drag.translation.width / size.width,
                        y: from.y + drag.translation.height / size.height,
                        width: from.width, height: from.height
                    ).fitted
            }
            .onEnded { _ in start = nil }
    }

    /// Corners: 0 top left, 1 top right, 2 bottom left, 3 bottom right.
    private func resize(_ corner: Int, _ size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { drag in
                let from = start ?? crop
                start = from
                let dx = drag.translation.width / size.width
                let dy = drag.translation.height / size.height
                var left = from.x
                var top = from.y
                var right = from.x + from.width
                var bottom = from.y + from.height
                if corner % 2 == 0 {
                    left = min(max(left + dx, 0), right - 0.05)
                } else {
                    right = max(min(right + dx, 1), left + 0.05)
                }
                if corner < 2 {
                    top = min(max(top + dy, 0), bottom - 0.05)
                } else {
                    bottom = max(min(bottom + dy, 1), top + 0.05)
                }
                if let aspect, imageSize.width > 0, imageSize.height > 0 {
                    // Keep the shape: the height follows the width.
                    let width = right - left
                    let height = width * imageSize.width / imageSize.height / aspect
                    if corner < 2 { top = bottom - height } else { bottom = top + height }
                }
                crop = EditRecipe.Crop(x: left, y: top, width: right - left, height: bottom - top).fitted
            }
            .onEnded { _ in start = nil }
    }
}
