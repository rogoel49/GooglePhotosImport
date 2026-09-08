import SwiftUI

/// The app's single screen: sign in → "Import from <album>" → progress/result.
struct ImportView: View {
    @Bindable var model: ImportViewModel
    @Environment(\.openURL) private var openURL
    @State private var showResetConfirm = false

    var body: some View {
        NavigationStack {
            List {
                if !AppConfig.isGoogleConfigured {
                    setupSection
                } else {
                    accountSection
                    albumSection
                    importSection
                    historySection
                }
            }
            .navigationTitle("Photos Importer")
            .task { await model.onAppear() }
            .onChange(of: model.albums) { model.saveAlbums() }
            .onChange(of: model.pendingPickerURL) { _, url in
                guard let url else { return }
                model.pendingPickerURL = nil
                openURL(url)
            }
            .alert("Import failed", isPresented: failedBinding) {
                Button("OK") { model.dismissResult() }
            } message: {
                if case let .failed(message) = model.phase { Text(message) }
            }
            .confirmationDialog(
                "Reset import history?",
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) { Task { await model.resetDedupHistory() } }
            } message: {
                Text("Photos already in your library are kept. The next import will treat everything as new, which can create duplicates.")
            }
        }
    }

    // MARK: Sections

    /// Shown when Secrets.xcconfig hasn't been filled in yet.
    private var setupSection: some View {
        Section {
            Label("Google sign-in isn't configured", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Create an iOS OAuth client in Google Cloud, put its ID in Config/Secrets.xcconfig, run `xcodegen generate`, and rebuild. Step-by-step instructions are in README.md.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Setup required")
        }
    }

    private var accountSection: some View {
        Section("Google account") {
            if model.auth.isSignedIn {
                LabeledContent("Signed in as", value: model.auth.accountEmail ?? "Google user")
                Button("Sign out", role: .destructive) { model.signOut() }
                    .disabled(model.phase.isBusy)
            } else {
                Button {
                    Task { await model.signIn() }
                } label: {
                    Label("Sign in with Google", systemImage: "person.crop.circle.badge.checkmark")
                }
            }
        }
    }

    private var albumSection: some View {
        Section {
            if let index = model.albums.indices.first {
                TextField("Album name", text: $model.albums[index].name)
                TextField(
                    "Share link (optional)",
                    text: Binding(
                        get: { model.albums[index].shareURL?.absoluteString ?? "" },
                        set: { model.albums[index].shareURL = URL(string: $0) }
                    )
                )
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                if let url = model.albums[index].shareURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Open album in Google Photos", systemImage: "arrow.up.right.square")
                    }
                }
            }
        } header: {
            Text("Album")
        } footer: {
            Text("Google's picker can't be pointed at one album automatically. Use the link to find it, then pick the new photos inside Google's picker.")
        }
    }

    private var importSection: some View {
        Section {
            switch model.phase {
            case .idle, .failed:
                Button {
                    model.startImport()
                } label: {
                    Label("Import from \(model.selectedAlbum?.name ?? "Google Photos")", systemImage: "square.and.arrow.down")
                }
                .disabled(!model.auth.isSignedIn)

            case .creatingSession:
                busyRow("Starting picker session…")

            case .waitingForSelection:
                busyRow("Pick photos in Google's picker, then come back here.")
                cancelButton

            case .fetchingSelection:
                busyRow("Fetching your selection…")

            case let .importing(progress):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(progress.processed), total: Double(max(progress.total, 1)))
                    Text("\(progress.saved) of \(progress.total) saved")
                        .font(.footnote.monospacedDigit())
                    if progress.skippedDuplicates > 0 {
                        Text("\(progress.skippedDuplicates) already imported, skipped")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                cancelButton

            case let .finished(progress):
                resultRows(progress)
                Button("Done") { model.dismissResult() }
            }
        } header: {
            Text("Import")
        }
    }

    private var historySection: some View {
        Section {
            LabeledContent("Items imported so far", value: "\(model.importedCount)")
            Button("Reset import history…", role: .destructive) { showResetConfirm = true }
                .disabled(model.phase.isBusy)
        } header: {
            Text("History")
        } footer: {
            Text("Saved into the \"\(AppConfig.importedAlbumTitle)\" album in Photos.")
        }
    }

    // MARK: Pieces

    private func busyRow(_ text: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(text)
        }
    }

    private var cancelButton: some View {
        Button("Cancel", role: .cancel) { model.cancelImport() }
    }

    @ViewBuilder
    private func resultRows(_ progress: ImportProgress) -> some View {
        Label("\(progress.saved) saved", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        if progress.skippedDuplicates > 0 {
            Label("\(progress.skippedDuplicates) skipped (already imported)", systemImage: "arrow.uturn.backward.circle")
                .foregroundStyle(.secondary)
        }
        // Fail loud: every failed item is listed, never silently dropped.
        ForEach(progress.failures) { failure in
            VStack(alignment: .leading, spacing: 2) {
                Label(failure.filename ?? failure.id, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(failure.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var failedBinding: Binding<Bool> {
        Binding(
            get: { if case .failed = model.phase { return true } else { return false } },
            set: { if !$0 { model.dismissResult() } }
        )
    }
}

#Preview {
    ImportView(model: ImportViewModel(auth: GooglePhotosAuth()))
}
