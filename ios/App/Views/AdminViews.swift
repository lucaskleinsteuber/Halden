import HaldenKit
import SwiftUI

/// Looking after the server, for owners: everything `halden` does in the terminal except
/// folders, port, certificate and restoring a backup.
struct AdminView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmRestart = false
    @State private var note: String?

    var body: some View {
        Loaded(load: { try await $0.serverStatus() }) { status, _ in
            List {
                Section("Server") {
                    LabeledContent("Name", value: status.name).accessibilityIdentifier("admin-name")
                    LabeledContent("Version", value: status.version)
                    LabeledContent("Running since", value: TakenAt.text(status.startedAt, offset: nil))
                    if let memory = status.memoryBytes {
                        LabeledContent(
                            "Memory", value: ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory))
                    }
                    if status.inDocker { LabeledContent("Runs in", value: "Docker") }
                    if let problem = status.configProblem {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                Section("Disks") {
                    disk("Library", status.libraryDisk)
                    disk("Database", status.dataDisk)
                    disk("Mirror", status.mirrorDisk)
                }
                Section("Photos") {
                    ForEach(status.accounts, id: \.userId) { account in
                        LabeledContent(
                            account.username,
                            value:
                                "\(account.photos) photos · \(account.videos) videos · \(ByteCountFormatter.string(fromByteCount: account.libraryBytes, countStyle: .file))"
                        )
                    }
                    LabeledContent("Uploads running", value: String(status.uploadsInProgress))
                    LabeledContent("Jobs", value: "\(status.jobs.waiting) waiting, \(status.jobs.failed) failed")
                }
                Section {
                    NavigationLink("Check everything (doctor)") { DoctorView() }.accessibilityIdentifier("admin-doctor")
                    NavigationLink("Settings") { ServerSettingsView() }.accessibilityIdentifier("admin-settings")
                    NavigationLink("Accounts") { AccountsView() }.accessibilityIdentifier("admin-accounts")
                    NavigationLink("Mirror") { MirrorView() }
                    NavigationLink("Database backups") { BackupsView() }
                    NavigationLink("Failed jobs (\(status.jobs.failed))") { JobsView() }
                    NavigationLink("Update") { UpdateView() }
                    Button("Restart the server", role: .destructive) { confirmRestart = true }
                }
                if let note { Section { Text(note) } }
            }
        }
        .navigationTitle("Server")
        .confirmationDialog("Restart the server?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart", role: .destructive) {
                Task {
                    do {
                        try await app.api().restartServer()
                        note = "The server is starting again."
                    } catch {
                        note = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("It is back in a second; uploads go on where they were.")
        }
    }

    @ViewBuilder private func disk(_ name: String, _ disk: ServerStatus.Disk?) -> some View {
        if let disk {
            LabeledContent(name) {
                VStack(alignment: .trailing) {
                    Text(
                        "\(ByteCountFormatter.string(fromByteCount: disk.freeBytes, countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: disk.totalBytes, countStyle: .file))"
                    )
                    Text(disk.path).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct DoctorView: View {
    var body: some View {
        Loaded(load: { try await $0.doctor() }) { report, _ in
            List(report.checks) { check in
                VStack(alignment: .leading, spacing: 4) {
                    Label(check.title, systemImage: Self.symbol(check.level))
                        .foregroundStyle(
                            check.level == "ok" ? Color.primary : check.level == "warning" ? .orange : .red)
                    Text(check.detail).font(.footnote)
                    if let fix = check.fix { Text(fix).font(.footnote).foregroundStyle(.secondary) }
                }
                .accessibilityIdentifier("check-\(check.id)")
            }
        }
        .navigationTitle("Doctor")
    }

    static func symbol(_ level: String) -> String {
        switch level {
        case "ok": "checkmark.circle"
        case "warning": "exclamationmark.triangle"
        default: "xmark.octagon"
        }
    }
}

/// The server's settings; changes are saved together and the server restarts with them.
struct ServerSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var config: ServerConfig?
    @State private var edits: [String: String] = [:]
    @State private var askPassword = false
    @State private var problem: String?
    @State private var saving = false

    var body: some View {
        Form {
            if let config {
                if !config.canChange {
                    Text("This server wasn't started from a settings file it may change.").foregroundStyle(.orange)
                }
                ForEach(groups(config), id: \.0) { group, settings in
                    Section(group) {
                        ForEach(settings) { setting in row(setting) }
                    }
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if changes.keys.contains(where: { name in
                        config?.settings.first { $0.name == name }?.access == "password"
                    }) {
                        askPassword = true
                    } else {
                        save(password: nil)
                    }
                }
                .disabled(changes.isEmpty || saving)
                .accessibilityIdentifier("save-settings")
            }
        }
        .askingForPassword($askPassword, because: "Some of these changes need your password.") { save(password: $0) }
        .task { await load() }
    }

    private func load() async {
        do {
            config = try await app.api().serverConfig()
            edits = [:]
        } catch {
            problem = error.localizedDescription
        }
    }

    private func groups(_ config: ServerConfig) -> [(String, [ServerSetting])] {
        let grouped = Dictionary(grouping: config.settings) { String($0.name.split(separator: ".").first ?? "") }
        return grouped.keys.sorted().map { ($0.capitalized, grouped[$0] ?? []) }
    }

    @ViewBuilder private func row(_ setting: ServerSetting) -> some View {
        let name = String(setting.name.split(separator: ".").dropFirst().joined(separator: "."))
        VStack(alignment: .leading, spacing: 4) {
            if setting.access == "terminal" {
                LabeledContent(name, value: setting.value?.text ?? "")
                Text("Only in the terminal: halden config set \(setting.name) …").font(.caption2).foregroundStyle(
                    .secondary)
            } else if setting.kind == "bool" {
                Toggle(
                    name,
                    isOn: Binding(
                        get: { (edits[setting.name] ?? setting.value?.text) == "on" },
                        set: { edits[setting.name] = $0 ? "on" : "off" }))
            } else {
                LabeledContent(name) {
                    TextField(setting.default?.text ?? "", text: text(setting))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(setting.kind == "number" ? .numberPad : .default)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("setting-\(setting.name)")
                }
            }
            if let about = setting.about { Text(about).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func text(_ setting: ServerSetting) -> Binding<String> {
        Binding(get: { edits[setting.name] ?? setting.value?.text ?? "" }, set: { edits[setting.name] = $0 })
    }

    /// Only what really changed, as the server expects it.
    private var changes: [String: JSONValue] {
        guard let config else { return [:] }
        var changes: [String: JSONValue] = [:]
        for (name, text) in edits {
            guard let setting = config.settings.first(where: { $0.name == name }), text != (setting.value?.text ?? "")
            else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            switch setting.kind {
            case "bool": changes[name] = .bool(trimmed == "on")
            case "number": changes[name] = Double(trimmed).map(JSONValue.number) ?? .string(trimmed)
            case "networks":
                changes[name] = .array(
                    trimmed.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) })
            default: changes[name] = trimmed.isEmpty && setting.kind == "optionalPath" ? .null : .string(trimmed)
            }
        }
        return changes
    }

    private func save(password: String?) {
        saving = true
        Task {
            defer { saving = false }
            do {
                _ = try await app.api().changeServerConfig(changes, currentPassword: password)
                problem = nil
                // The server starts again with them, in about a second.
                try? await Task.sleep(for: .seconds(1.5))
                await load()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

struct BackupsView: View {
    @Environment(AppModel.self) private var app
    @State private var problem: String?

    var body: some View {
        Loaded(load: { try await $0.databaseBackups() }) { backups, reload in
            List {
                Section {
                    Button("Back up the database now") {
                        Task {
                            do {
                                _ = try await app.api().makeDatabaseBackup()
                                reload()
                            } catch {
                                problem = error.localizedDescription
                            }
                        }
                    }
                    if let problem { Text(problem).foregroundStyle(.red) }
                } footer: {
                    Text("The server backs up its database every night by itself and copies it to the mirror.")
                }
                ForEach(backups) { backup in
                    LabeledContent(
                        TakenAt.text(backup.madeAt, offset: nil),
                        value: ByteCountFormatter.string(fromByteCount: backup.size, countStyle: .file))
                }
            }
        }
        .navigationTitle("Database backups")
    }
}

struct MirrorView: View {
    @Environment(AppModel.self) private var app
    @State private var path = ""
    @State private var asking: String?
    @State private var problem: String?

    var body: some View {
        Loaded(load: { try await $0.mirror() }) { mirror, reload in
            Form {
                Section {
                    LabeledContent("Mirror", value: mirror.path ?? "none")
                    if let backup = mirror.backup {
                        LabeledContent("State", value: backup.mirror)
                        if backup.mirrorOnSameDisk {
                            Text("The mirror is on the same disk as the library: it protects against nothing.")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Section {
                    TextField("Folder on a second disk, e.g. /mnt/usb/halden", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Use as mirror") { asking = "set" }.disabled(path.isEmpty)
                    if mirror.path != nil {
                        Button("Stop mirroring", role: .destructive) { asking = "stop" }
                    }
                } footer: {
                    Text("Every photo is copied there too. The folder must exist and be outside the library.")
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }
            .askingForPassword(
                Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                because: "Changing the mirror needs your password."
            ) { password in
                let what = asking
                Task {
                    do {
                        if what == "set" {
                            try await app.api().setMirror(path: path, currentPassword: password)
                        } else {
                            try await app.api().stopMirror(currentPassword: password)
                        }
                        problem = nil
                        try? await Task.sleep(for: .seconds(1.5))
                        reload()
                    } catch {
                        problem = error.localizedDescription
                    }
                }
            }
        }
        .navigationTitle("Mirror")
    }
}

struct JobsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Loaded(load: { try await $0.jobs() }) { jobs, reload in
            List {
                if jobs.isEmpty {
                    Text("No job failed.")
                } else {
                    Button("Try all again") {
                        Task {
                            _ = try? await app.api().retryJobs()
                            reload()
                        }
                    }
                }
                ForEach(jobs) { job in
                    VStack(alignment: .leading) {
                        Text("\(job.kind) · \(job.attempts) tries").font(.headline)
                        if let error = job.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
        }
        .navigationTitle("Failed jobs")
    }
}

struct UpdateView: View {
    @Environment(AppModel.self) private var app
    @State private var status: UpdateStatus?
    @State private var askPassword = false
    @State private var problem: String?

    var body: some View {
        Form {
            if let status {
                Section {
                    LabeledContent("Running", value: status.running)
                    LabeledContent("Newest", value: status.latest ?? "not known yet")
                    LabeledContent("State", value: status.state)
                    if let message = status.message { Text(message).font(.footnote) }
                    if let checked = status.checkedAt {
                        LabeledContent("Checked", value: TakenAt.text(checked, offset: nil))
                    }
                }
                Section {
                    Button("Look for an update") { run { try await $0.checkForUpdate() } }
                    if status.state == "available" {
                        if status.canInstall {
                            Button("Install \(status.latest ?? "")") { askPassword = true }
                        } else if let hint = status.installHint {
                            Text(hint).font(.footnote).textSelection(.enabled)
                        }
                    }
                }
            } else {
                ProgressView()
            }
            if let problem { Section { Text(problem).foregroundStyle(.red) } }
        }
        .navigationTitle("Update")
        .task { run { try await $0.updateStatus() } }
        .askingForPassword($askPassword, because: "Installing an update needs your password.") { password in
            run { try await $0.installUpdate(currentPassword: password) }
        }
    }

    private func run(_ call: @escaping @MainActor (APIClient) async throws -> UpdateStatus) {
        Task {
            do {
                status = try await call(try app.api())
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// Accounts on the server: add, change, disable, delete, and pairing codes for them.
struct AccountsView: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false
    @State private var pending: ((String) async throws -> Void)?
    @State private var problem: String?
    @State private var code: PairingCode?

    var body: some View {
        Loaded(load: { try await $0.accounts() }) { accounts, reload in
            List {
                if let problem { Text(problem).foregroundStyle(.red) }
                ForEach(accounts) { account in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName).font(.headline)
                        Text(
                            "\(account.username) · \(account.role)\(account.disabled ? " · disabled" : "") · \(account.devices ?? 0) devices"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("account-\(account.username)")
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            ask { password in
                                try await app.api().deleteAccount(account.id, currentPassword: password)
                                reload()
                            }
                        }
                        Button(account.disabled ? "Enable" : "Disable") {
                            Task {
                                do {
                                    _ = try await app.api().changeAccount(account.id, disabled: !account.disabled)
                                    reload()
                                } catch {
                                    problem = error.localizedDescription
                                }
                            }
                        }
                        Button("Pair") {
                            ask { password in
                                code = try await app.api().pairingCode(for: account.id, currentPassword: password)
                            }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add", systemImage: "plus") { adding = true }.accessibilityIdentifier("add-account")
                }
            }
            .sheet(isPresented: $adding) {
                NewAccountView { username, name, owner, password in
                    ask { current in
                        _ = try await app.api().createAccount(
                            username: username, displayName: name.isEmpty ? nil : name, owner: owner,
                            password: password.isEmpty ? nil : password, currentPassword: current)
                        reload()
                    }
                }
            }
        }
        .navigationTitle("Accounts")
        .askingForPassword(
            Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), because: "This needs your password."
        ) { password in
            let action = pending
            Task {
                do {
                    try await action?(password)
                    problem = nil
                } catch {
                    problem = error.localizedDescription
                }
            }
        }
        .sheet(item: Binding(get: { code.map { SharedCode(code: $0) } }, set: { if $0 == nil { code = nil } })) {
            shared in
            VStack(spacing: 16) {
                if let image = QRCode.image(shared.code.url) {
                    Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 260)
                }
                Text(shared.code.code).font(.system(.title2, design: .monospaced))
            }
            .padding()
        }
    }

    private func ask(_ action: @escaping (String) async throws -> Void) {
        pending = action
    }

    struct SharedCode: Identifiable {
        let code: PairingCode
        var id: String { code.code }
    }
}

struct NewAccountView: View {
    @Environment(\.dismiss) private var dismiss
    let create: (String, String, Bool, String) -> Void
    @State private var username = ""
    @State private var name = ""
    @State private var owner = false
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("new-username")
                TextField("Name (optional)", text: $name)
                SecureField("Password (optional: else only by pairing)", text: $password)
                    .accessibilityIdentifier("new-password")
                Toggle("Owner (may look after the server)", isOn: $owner)
            }
            .navigationTitle("New account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        dismiss()
                        create(username, name, owner, password)
                    }
                    .disabled(username.count < 2 || (!password.isEmpty && password.count < 8))
                    .accessibilityIdentifier("create-account")
                }
            }
        }
    }
}
