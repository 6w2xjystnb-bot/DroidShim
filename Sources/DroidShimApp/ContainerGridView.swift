//
//  ContainerGridView.swift
//  DroidShimApp
//
//  Grid of imported APK containers.
//

#if canImport(UIKit)
import SwiftUI
import DroidShimCore

struct ContainerGridView: View {
    @EnvironmentObject var engine: ContainerEngine
    @State private var isImporting = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    if let message = engine.activity.message {
                        HStack(spacing: 10) {
                            if case .failed = engine.activity {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                            } else {
                                ProgressView()
                            }
                            Text(message)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                            Spacer()
                            if case .failed = engine.activity {
                                Button("OK") {
                                    engine.clearActivity()
                                }
                                .font(.footnote)
                            }
                        }
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 20) {
                        ForEach(engine.containers) { container in
                            ContainerCell(container: container)
                                .environmentObject(engine)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("DroidShim")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { isImporting = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $isImporting) {
                ImportSheet(isPresented: $isImporting)
                    .environmentObject(engine)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct ContainerCell: View {
    @ObservedObject var container: ContainerModel
    @EnvironmentObject var engine: ContainerEngine

    var body: some View {
        VStack {
            Group {
                if let icon = container.icon {
                    Image(uiImage: icon)
                        .resizable()
                } else {
                    Color.gray
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary, lineWidth: 1))

            Text(container.name)
                .font(.caption)
                .lineLimit(1)

            Text(container.state.rawValue)
                .font(.caption2)
                .foregroundColor(stateColor)

            Button(action: { engine.launch(container) }) {
                Image(systemName: "play.fill")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            engine.launch(container)
        }
        .contextMenu {
            Button("Delete Data") {
                // Phase 1: reset container data directory.
            }
            Button("Export Logs") {
                // Phase 1: share logs URL.
                _ = engine.exportLogs(container)
            }
            Button("Uninstall", role: .destructive) {
                engine.uninstall(container)
            }
        }
    }

    private var stateColor: Color {
        switch container.state {
        case .installed: return .secondary
        case .running: return .green
        case .paused: return .orange
        case .error: return .red
        }
    }
}
#endif
