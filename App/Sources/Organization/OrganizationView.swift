import Engine
import SwiftUI

private enum OrganizationNavigation: Hashable {
    case root(UUID)
    case recent
}

struct OrganizationView: View {
    @Bindable var controller: OrganizationController

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                Section("Folders") {
                    ForEach(controller.registrations) { registration in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(URL(fileURLWithPath: registration.path).lastPathComponent, systemImage: "folder")
                            Text(registration.displayStatus)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .tag(OrganizationNavigation.root(registration.id))
                        .contextMenu {
                            if registration.automatic {
                                Button(registration.paused ? String(localized: "Resume") : String(localized: "Pause")) {
                                    controller.togglePause(registration.id)
                                }
                            }
                            Button("Remove Folder") { controller.remove(registration.id) }
                        }
                    }
                }
                Label("Recent Organization", systemImage: "clock.arrow.circlepath")
                    .tag(OrganizationNavigation.recent)
            }
            .safeAreaInset(edge: .bottom) {
                Button("Add Folder…", systemImage: "plus") { controller.chooseFolder() }.padding()
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if controller.showingRecent {
                recent
            } else if let selected = controller.selected {
                editor(selected)
            } else {
                ContentUnavailableView(
                    "Choose a Folder", systemImage: "folder",
                    description: Text("Review a policy and a move preview before enabling automatic organization."))
            }
        }
        .frame(minWidth: 850, minHeight: 560)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if controller.isScanning {
                    ProgressView().controlSize(.small); Button("Stop") { controller.cancelPreview() }
                }
                Text(controller.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
            }.padding(.horizontal).padding(.vertical, 8)
        }
        .alert(
            "Organization Could Not Finish",
            isPresented: Binding(
                get: { controller.failure != nil },
                set: { if !$0 { controller.failure = nil } })
        ) {
            Button("OK") { controller.failure = nil }
        } message: {
            Text(controller.failure ?? "")
        }
    }

    private var sidebarSelection: Binding<OrganizationNavigation?> {
        Binding(
            get: {
                controller.showingRecent ? .recent : controller.selectedRoot.map(OrganizationNavigation.root)
            },
            set: { selection in
                switch selection {
                case .root(let id): controller.select(id)
                case .recent:
                    controller.showingRecent = true
                    Task { await controller.refreshRecent() }
                case nil: break
                }
            })
    }

    private func editor(_ registration: OrganizationRegistration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(registration.path).font(.headline).textSelection(.enabled)
            Text("Only loose files in this folder are organized. Existing folders stay in place.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                LabeledContent("Category folders") {
                    TextEditor(text: $controller.categoriesText).font(.system(.body, design: .monospaced))
                        .frame(height: 85).border(.separator)
                        .accessibilityLabel("Category folders, one relative path per line")
                }
                TextField("Classification instructions", text: $controller.policy.instructions)
                Toggle(
                    "Allow new subcategories within these category folders",
                    isOn: $controller.policy.allowNewSubcategories)
                Toggle("Rename opaque camera, scan and random filenames", isOn: $controller.policy.renameOpaqueFiles)
                LabeledContent("Stability delay") {
                    TextField(
                        "Seconds", value: $controller.policy.stabilityDelay,
                        format: .number.precision(.fractionLength(0))
                    )
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 80)
                    Text("seconds").foregroundStyle(.secondary)
                }
            }
            .disabled(controller.isScanning || controller.isApplying)
            HStack {
                Button("Suggest Categories") { controller.suggestCategories() }
                    .disabled(controller.isScanning || controller.isApplying)
                Button("Preview Organization") { controller.preview() }
                    .disabled(controller.isScanning || controller.isApplying || !controller.canSave)
                if registration.automatic {
                    Button(
                        registration.paused
                            ? String(localized: "Resume Automation") : String(localized: "Pause Automation")
                    ) {
                        controller.togglePause(registration.id)
                    }
                }
                Spacer()
                Text("\(controller.readyCount) ready · \(controller.proposals.count - controller.readyCount) held")
                    .foregroundStyle(.secondary)
            }
            Table(controller.proposals) {
                TableColumn("Current file") { proposal in
                    Text(proposal.source.lastPathComponent).help(proposal.source.path)
                }
                TableColumn("Category") { proposal in
                    Picker(
                        "Category",
                        selection: Binding(
                            get: { proposal.category ?? "" },
                            set: { controller.setCategory($0.isEmpty ? nil : $0, for: proposal.source) })
                    ) {
                        Text("Hold in Place").tag("")
                        if let category = proposal.category, !registration.policy.categories.contains(category) {
                            Text(category).tag(category)
                        }
                        ForEach(registration.policy.categories, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
                TableColumn("Proposed name") { proposal in
                    TextField(
                        "Proposed name",
                        text: Binding(
                            get: { proposal.name },
                            set: { controller.setName($0, for: proposal.source) }))
                }
                TableColumn("Reason") { proposal in Text(proposal.reason).font(.caption).help(proposal.reason) }
            }
            .disabled(controller.isScanning || controller.isApplying)
            HStack {
                Text("Collisions receive a numbered suffix. Every move can be undone.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Organize Once") { controller.apply(enableAutomatic: false) }
                Button("Organize & Enable Automation") { controller.apply(enableAutomatic: true) }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(
                controller.isScanning || controller.isApplying || !controller.hasPreview || !controller.canSave)
        }.padding()
    }

    private var recent: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Recent Organization").font(.headline)
                Spacer()
                TextField("Search old or new path", text: $controller.search).textFieldStyle(.roundedBorder).frame(
                    maxWidth: 300)
            }.padding()
            Table(controller.filteredRecent) {
                TableColumn("Original path") { row in
                    Text(row.move.from.path).lineLimit(1).truncationMode(.middle).help(row.move.from.path)
                }
                TableColumn("Current path") { row in
                    Text(row.move.to.path).lineLimit(1).truncationMode(.middle).help(row.move.to.path)
                }
                TableColumn("Category") { row in
                    Menu(row.move.category) {
                        if let registration = controller.registrations.first(where: { $0.path == row.move.root.path }) {
                            ForEach(registration.policy.categories, id: \.self) { category in
                                Button(category) { controller.correct(row, category: category) }
                            }
                        }
                    }
                }
                TableColumn("Batch") { row in
                    Button("Undo Batch") { controller.undo(row.batch) }.disabled(row.batch.undone)
                }
            }
        }
    }
}

struct OrganizationSettingsView: View {
    @Bindable var controller: OrganizationController
    var body: some View {
        Form {
            Section("Automatic Organization") {
                Text("Automation is enabled separately for each folder after reviewing its policy and move preview.")
                ForEach(controller.registrations) { registration in
                    LabeledContent(registration.path) {
                        Text(registration.displayStatus)
                        if registration.automatic {
                            Button(registration.paused ? String(localized: "Resume") : String(localized: "Pause")) {
                                controller.togglePause(registration.id)
                            }
                        }
                    }
                }
                Button("Open Organization…") { controller.open() }
            }
        }.formStyle(.grouped)
    }
}

private extension OrganizationRegistration {
    var displayStatus: String {
        if paused { return String(localized: "Paused") }
        return automatic ? String(localized: "Automatic") : String(localized: "Preview only")
    }
}
