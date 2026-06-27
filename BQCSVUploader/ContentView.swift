import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @AppStorage("tableReference") private var tableReference = ""
    @State private var selectedFileURL: URL?
    @State private var isTargeted = false
    @State private var isUploading = false
    @State private var statusMessage = "Drop a CSV file or click to browse."
    @State private var statusIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("BigQuery CSV Uploader")
                .font(.title2.weight(.semibold))

            Text("Uses upload-bq-dataset with your gcloud / bq credentials.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Table reference")
                    .font(.headline)
                TextField("project_id.dataset_id.table_id", text: $tableReference)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isUploading)
            }

            dropZone

            if let selectedFileURL {
                HStack {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(selectedFileURL.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Clear") {
                        self.selectedFileURL = nil
                        resetStatus()
                    }
                    .disabled(isUploading)
                }
                .font(.callout)
            }

            Button(action: startUpload) {
                HStack {
                    if isUploading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isUploading ? "Uploading…" : "Upload to BigQuery")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canUpload)

            statusView

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 380)
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                )

            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Drop CSV here")
                    .font(.headline)
                Text("or click to choose a file")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 28)
        }
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { openFilePicker() }
        .onDrop(of: [.fileURL, .commaSeparatedText], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private var statusView: some View {
        Text(statusMessage)
            .font(.caption)
            .foregroundStyle(statusIsError ? .red : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private var canUpload: Bool {
        !isUploading && selectedFileURL != nil && !tableReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func resetStatus() {
        statusMessage = "Drop a CSV file or click to browse."
        statusIsError = false
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "Choose CSV file"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, UTType(filenameExtension: "csv")!]

        if panel.runModal() == .OK, let url = panel.url {
            selectFile(url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                DispatchQueue.main.async { selectFile(url) }
            }
            return true
        }

        return false
    }

    private func selectFile(_ url: URL) {
        guard url.pathExtension.lowercased() == "csv" else {
            statusMessage = "Please choose a .csv file."
            statusIsError = true
            return
        }
        selectedFileURL = url
        statusMessage = "Ready to upload."
        statusIsError = false
    }

    private func startUpload() {
        guard let selectedFileURL else { return }

        isUploading = true
        statusMessage = "Running upload…"
        statusIsError = false

        Task {
            do {
                let result = try await BQUploadService.upload(
                    csvURL: selectedFileURL,
                    tableReference: tableReference
                )
                await MainActor.run {
                    statusMessage = result
                    statusIsError = false
                    isUploading = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = error.localizedDescription
                    statusIsError = true
                    isUploading = false
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
