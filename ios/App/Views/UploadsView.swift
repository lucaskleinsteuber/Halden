import GRDB
import HaldenKit
import SwiftUI

/// Everything that hasn't reached the server yet: how far each upload is, what went wrong, and a
/// way to try again.
struct UploadsView: View {
    @Environment(AppModel.self) private var app
    @State private var items: [UploadItem] = []
    @State private var observation: AnyDatabaseCancellable?

    var body: some View {
        List {
            Section {
                let summary = app.uploadSummary
                LabeledContent("This round", value: "\(summary.done) of \(summary.total) uploaded")
                    .accessibilityIdentifier("upload-round")
                if summary.bytesTotal > 0 {
                    ProgressView(value: Double(summary.bytesSent), total: Double(summary.bytesTotal))
                }
                if let reason = app.uploadsWaitBecause {
                    Label(reason, systemImage: "pause.circle").foregroundStyle(.orange)
                        .accessibilityIdentifier("uploads-wait")
                } else if !app.reachable && !items.isEmpty {
                    Label("The server can't be reached right now.", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }
            if let backup = app.backup, backup.onlyOneCopy {
                Section {
                    Label(
                        "Only one copy on the server: if its disk breaks, photos only there are gone.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }
            Section(items.isEmpty ? "Everything is on the server" : "Waiting") {
                ForEach(items, id: \.key) { item in
                    UploadRow(item: item) {
                        try? Uploader.retry(item.assetId, database: app.database)
                        app.refresh()
                    }
                }
            }
        }
        .navigationTitle("Uploads")
        .refreshable { app.refresh() }
        .onAppear(perform: watch)
        .onDisappear { observation = nil }
    }

    private func watch() {
        observation =
            ValueObservation
            .tracking { db in try UploadItem.filter(sql: "state <> 'done'").order(sql: "createdAt").fetchAll(db) }
            .start(in: app.database.writer, scheduling: .async(onQueue: .main)) { _ in
            } onChange: { found in
                MainActor.assumeIsolated { items = found }
            }
    }
}

private struct UploadRow: View {
    let item: UploadItem
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: item.mimeType.hasPrefix("video/") ? "video" : "photo")
                Text(
                    item.metadata?.takenAt.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? .now, style: .date)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(item.sent), total: Double(max(item.size, 1)))
            Text(stateText).font(.footnote).foregroundStyle(item.state == "failed" ? .red : .secondary)
            if let error = item.lastError {
                Text(error).font(.footnote).foregroundStyle(.red).lineLimit(3)
            }
            if item.state == "failed" || item.attempts > 0 {
                Button("Try again", action: retry)
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("retry-\(item.assetId)")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var stateText: String {
        switch item.state {
        case "waiting": item.attempts > 0 ? "Waiting to try again (\(item.attempts) tries so far)" : "Waiting"
        case "sending": "Uploading"
        case "thumbnails": "On the server; sending its thumbnail"
        case "failed": "The server didn't take it"
        default: item.state
        }
    }
}
