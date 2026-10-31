import AppKit
import Engine
import MenuCatalog
import SwiftUI

extension RecipeOutput {
    var title: String {
        switch self {
        case .imageJPEG: String(localized: "Image: JPEG")
        case .imagePNG: String(localized: "Image: PNG")
        case .imageHEIC: String(localized: "Image: HEIC")
        case .imageWebP: String(localized: "Image: WebP")
        case .imageAVIF: String(localized: "Image: AVIF")
        case .imageTIFF: String(localized: "Image: TIFF")
        case .videoMP4: String(localized: "Video: MP4 (H.264)")
        case .videoMOV: String(localized: "Video: MOV (HEVC)")
        case .videoWebM: String(localized: "Video: WebM (VP9)")
        case .videoThumbnail: String(localized: "Video: Thumbnail (PNG)")
        case .pdf: String(localized: "PDF: Document")
        case .pdfPagesPNG: String(localized: "PDF: Pages (PNG)")
        case .pdfPagesJPEG: String(localized: "PDF: Pages (JPEG)")
        case .pdfText: String(localized: "PDF: Text (UTF-8)")
        }
    }
}

struct RecipeLibraryView: View {
    let recipeStore: RecipeStore
    @State private var recipes: [Recipe] = []
    @State private var selection: UUID?
    @State private var editing: Recipe?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finishing recipes").font(.title2)
            Text("Create final files together. Every recipe keeps the originals and publishes one folder or ZIP.")
                .foregroundStyle(.secondary)
            List(recipes, selection: $selection) { recipe in
                VStack(alignment: .leading, spacing: 3) {
                    Text(recipe.name)
                    Text(recipe.variants.map { $0.output.title }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(recipe.id)
            }
            .onTapGesture(count: 2) { editing = selected }
            HStack {
                Button("New Recipe", systemImage: "plus") {
                    editing = Recipe(
                        name: String(localized: "New Recipe"), variants: [OutputVariant(output: .imageJPEG)])
                }
                Button("Edit Recipe") { editing = selected }.disabled(selected == nil)
                Button("Duplicate") { change { _ = try await $0.duplicate(selectionID()) } }.disabled(selected == nil)
                Spacer()
                Button("Delete", role: .destructive) { change { try await $0.delete(selectionID()) } }
                    .disabled(selected == nil)
            }
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(20)
        .task { await reload() }
        .sheet(item: $editing) { recipe in
            RecipeEditorView(recipe: recipe) { revised in
                _ = try await recipeStore.save(revised)
                await reload()
            }
        }
    }

    private var selected: Recipe? { recipes.first { $0.id == selection } }

    private func selectionID() throws -> UUID {
        guard let selection else { throw RecipeError.invalidRecipe }
        return selection
    }

    private func change(_ mutation: @escaping (RecipeStore) async throws -> Void) {
        Task {
            do {
                try await mutation(recipeStore)
                await reload()
            } catch { failure = error.localizedDescription }
        }
    }

    private func reload() async {
        do {
            recipes = try await recipeStore.recipes()
            failure = nil
        } catch { failure = error.localizedDescription }
    }
}

struct RecipeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var recipe: Recipe
    let onSave: (Recipe) async throws -> Void
    @State private var failure: String?
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Recipe") {
                    TextField("Name", text: $recipe.name)
                    Picker("Package", selection: $recipe.packaging) {
                        Text("Folder").tag(Recipe.Packaging.folder)
                        Text("ZIP").tag(Recipe.Packaging.zip)
                    }
                    RecipeByteLimit(label: String(localized: "Limit total package size"), bytes: $recipe.totalBytes)
                    Text(
                        "Folder limits count every output file. ZIP limits count the completed archive. If the limit cannot be met, nothing is published."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($recipe.variants) { $variant in
                    Section {
                        Picker("Output", selection: $variant.output) {
                            ForEach(RecipeOutput.allCases, id: \.self) { output in
                                Text(output.title).tag(output)
                            }
                        }
                        .onChange(of: variant.output) {
                            if !variant.output.supportsResize { variant.maximumEdge = nil }
                            if !variant.output.supportsByteTarget { variant.targetBytes = nil }
                        }
                        TextField("Filename suffix", text: $variant.suffix)
                        if variant.output.supportsResize {
                            Toggle(
                                "Resize within a maximum edge",
                                isOn: Binding(
                                    get: { variant.maximumEdge != nil },
                                    set: { variant.maximumEdge = $0 ? 1920 : nil }))
                            if variant.maximumEdge != nil {
                                TextField(
                                    "Maximum edge (pixels)",
                                    value: Binding(
                                        get: { variant.maximumEdge ?? 1920 },
                                        set: { variant.maximumEdge = $0 }), format: .number.grouping(.never))
                            }
                            RecipeByteLimit(
                                label: String(localized: "Limit each output size"), bytes: $variant.targetBytes)
                        }
                        if variant.output.supportsResize || variant.output == .pdfPagesJPEG {
                            Stepper("Quality: \(variant.quality)%", value: $variant.quality, in: 1...100)
                        }
                        if variant.output == .pdf {
                            Toggle("Compress PDF images", isOn: $variant.compressPDF)
                            Text("PDF compression has no guaranteed target size.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if variant.output == .pdfPagesPNG || variant.output == .pdfPagesJPEG {
                            TextField("Resolution (DPI)", value: $variant.pdfDPI, format: .number.grouping(.never))
                        }
                        Button("Remove Output", role: .destructive) {
                            recipe.variants.removeAll { $0.id == variant.id }
                        }
                        .disabled(recipe.variants.count <= 1)
                    } header: {
                        Text(variant.output.title)
                    }
                }
                Button("Add Output", systemImage: "plus") {
                    recipe.variants.append(OutputVariant(output: .imageJPEG, suffix: "_copy"))
                }.disabled(recipe.variants.count >= Recipe.maximumVariants)
                Text(
                    "Each selected file must match an output rule. Multiple matching rules create multiple variants directly from the original."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let failure { Text(failure).foregroundStyle(.red).font(.caption) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    saving = true
                    Task {
                        do {
                            try recipe.validate()
                            try await onSave(recipe)
                            dismiss()
                        } catch { failure = error.localizedDescription }
                        saving = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(saving)
            }.padding()
        }
        .frame(width: 600, height: 620)
    }
}

private struct RecipeByteLimit: View {
    let label: String
    @Binding var bytes: Int64?

    var body: some View {
        Toggle(label, isOn: Binding(get: { bytes != nil }, set: { bytes = $0 ? 25_000_000 : nil }))
        if bytes != nil {
            TextField(
                "Maximum bytes", value: Binding(get: { bytes ?? 25_000_000 }, set: { bytes = $0 }),
                format: .number.grouping(.never))
        }
    }
}

struct RecipeRunView: View {
    let inputs: [URL]
    let settings: Engine.Settings
    let recipeStore: RecipeStore
    var preselectedRecipeID: UUID?
    var expectedRevision: String?
    let onRun: (Batch) -> Void
    let onCancel: () -> Void
    @State private var recipes: [Recipe] = []
    @State private var selectedID: UUID?
    @State private var destination: URL?
    @State private var failure: String?
    @State private var editing: Recipe?
    @State private var busy = false
    @State private var acceptedRevision: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Finish Files").font(.title2)
            Text("\(inputs.count) selected files. Originals are always kept.").foregroundStyle(.secondary)
            Form {
                Picker("Recipe", selection: $selectedID) {
                    ForEach(recipes) { recipe in Text(recipe.name).tag(Optional(recipe.id)) }
                }
                .onChange(of: selectedID) { failure = revisionFailure }
                Button("Edit Recipe") { editing = selected }.disabled(selected == nil)
                if let selected {
                    LabeledContent("Outputs", value: selected.variants.map { $0.output.title }.joined(separator: ", "))
                    LabeledContent("Package", value: selected.packaging == .zip ? "ZIP" : String(localized: "Folder"))
                    if let bytes = selected.totalBytes {
                        LabeledContent(
                            "Maximum package size",
                            value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    }
                }
                LabeledContent("Output folder") {
                    Text(destination?.path ?? defaultDestination).lineLimit(2).truncationMode(.middle)
                    Button("Choose…") { chooseDestination() }
                }
            }
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Finish Files") { run() }
                    .keyboardShortcut(.defaultAction).disabled(selected == nil || busy)
            }
        }
        .padding(24)
        .frame(width: 650)
        .task { await reload() }
        .sheet(item: $editing) { recipe in
            RecipeEditorView(recipe: recipe) { revised in
                let saved = try await recipeStore.save(revised)
                if saved.id == preselectedRecipeID { acceptedRevision = saved.revision }
                await reload(selecting: saved.id)
            }
        }
    }

    private var selected: Recipe? { recipes.first { $0.id == selectedID } }

    private var revisionFailure: String? {
        guard let selected, selected.id == preselectedRecipeID, let expectedRevision,
            String(selected.revision) != expectedRevision, selected.revision != acceptedRevision
        else { return nil }
        return String(localized: "This recipe changed. Reopen Finish Files from Finder to use the latest revision.")
    }

    private var defaultDestination: String {
        RecipePlanner.requiresDestination(for: inputs)
            ? String(localized: "Choose an output folder") : inputs.first?.deletingLastPathComponent().path ?? ""
    }

    private func reload(selecting id: UUID? = nil) async {
        do {
            recipes = try await recipeStore.recipes()
            selectedID = id ?? selectedID ?? preselectedRecipeID ?? recipes.first?.id
            failure = revisionFailure
        } catch { failure = error.localizedDescription }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose Output Folder")
        if panel.runModal() == .OK { destination = panel.url }
    }

    private func run() {
        guard let selected else { return }
        if let revisionFailure {
            failure = revisionFailure
            return
        }
        if RecipePlanner.requiresDestination(for: inputs), destination == nil {
            chooseDestination()
            guard destination != nil else { return }
        }
        busy = true
        Task {
            do {
                try RecipePlanner.validate(recipe: selected, inputs: inputs)
                let batch = try RecipePlanner.batch(
                    recipe: selected, inputs: inputs, destination: destination, settings: settings)
                onRun(batch)
            } catch { failure = error.localizedDescription }
            busy = false
        }
    }
}
