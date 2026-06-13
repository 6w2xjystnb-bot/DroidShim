//
//  ImportSheet.swift
//  DroidShimApp
//
//  File importer for .apk archives.
//

#if canImport(UIKit)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import DroidShimCore

private extension UTType {
    static let androidPackage = UTType(exportedAs: "com.android.package-archive", conformingTo: .data)
}

struct ImportSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var engine: ContainerEngine
    @State private var isImporting = false
    @State private var launchAfterImport = false
    @State private var status = "Select an APK file"
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text(status)
                    .foregroundColor(.secondary)

                Button("Import APK") {
                    launchAfterImport = false
                    isImporting = true
                }
                .buttonStyle(.bordered)

                Button("Import & Run") {
                    launchAfterImport = true
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
            .sheet(isPresented: $isImporting) {
                APKDocumentPicker { result in
                    isImporting = false
                    handleImport(result: result)
                }
            }
            .alert("Import Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func handleImport(result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            status = launchAfterImport ? "Opening \(url.lastPathComponent)..." : "Installing \(url.lastPathComponent)..."
            Task {
                do {
                    _ = try await engine.openAPK(from: url, launchAfterInstall: launchAfterImport)
                    await MainActor.run {
                        status = launchAfterImport ? "Opening..." : "Installed successfully"
                        isPresented = false
                    }
                } catch {
                    await MainActor.run {
                        errorMessage = String(describing: error)
                        showError = true
                        status = "Install failed"
                    }
                }
            }
        case .failure(let error):
            errorMessage = String(describing: error)
            showError = true
        }
    }
}

struct APKDocumentPicker: UIViewControllerRepresentable {
    let onComplete: (Result<URL, Error>) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item, .data, .androidPackage],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onComplete: (Result<URL, Error>) -> Void

        init(onComplete: @escaping (Result<URL, Error>) -> Void) {
            self.onComplete = onComplete
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onComplete(.failure(ContainerEngineError.importFailed("No file selected")))
                return
            }
            onComplete(.success(url))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onComplete(.failure(ContainerEngineError.importFailed("File selection cancelled")))
        }
    }
}
#endif
