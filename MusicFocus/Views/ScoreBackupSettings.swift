import SwiftUI
import UniformTypeIdentifiers

struct ScoreBackupSettings: View {
    @EnvironmentObject private var library: ScoreLibrary
    @State private var busy = false
    @State private var importing = false
    @State private var sharing = false
    @State private var backup: URL?
    @State private var message: String?
    var body: some View {
        Section {
            Button("score.backupExport".localized, systemImage: "square.and.arrow.up") {
                busy = true
                Task {
                    do { backup = try await library.exportBackup(); sharing = true }
                    catch { message = error.localizedDescription }
                    busy = false
                }
            }.accessibilityIdentifier("scoreBackupExport")
            Button("score.backupRestore".localized, systemImage: "square.and.arrow.down") { importing = true }
                .accessibilityIdentifier("scoreBackupRestore")
            if busy { ProgressView("score.backupWorking".localized) }
        } header: { Text("score.backup".localized) }
        footer: { Text("score.backupHint".localized) }
        .disabled(busy || library.isImporting)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                busy = true
                Task {
                    do { let count = try await library.restoreBackupCopies(url); message = "score.backupRestored".localizedFormat(count) }
                    catch { message = error.localizedDescription }
                    busy = false
                }
            case .failure(let error): message = error.localizedDescription
            }
        }
        .sheet(isPresented: $sharing) { if let backup { ScoreShareSheet(url: backup) } }
        .alert("score.backup".localized, isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK".localized, role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }
}
