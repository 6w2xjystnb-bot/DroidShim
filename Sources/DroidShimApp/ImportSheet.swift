//
//  ImportSheet.swift
//  DroidShimApp
//
//  File importer for .apk archives.
//

#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import DroidShimCore

struct ImportSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var engine: ContainerEngine
    @State private var isImporting = false
    @State private var status = "Select an APK file"
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text(status)
                    .foregroundColor(.secondary)

                Button("Import APK") {
                    isImporting = true
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding()
            .navigationTitle("Import APK")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isPresented = false }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [UTType(filenameExtension: "apk") ?? UTType.data],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result: result)
            }
            .alert("Import Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func handleImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            status = "Installing \(url.lastPathComponent)..."
            Task {
                do {
                    _ = try await engine.install(apkURL: url)
                    await MainActor.run {
                        status = "Installed successfully"
                        isPresented = false
                    }
                } catch {
                    await MainActor.run {
                        errorMessage = error.localizedDescription
                        showError = true
                        status = "Install failed"
                    }
                }
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
#endif
