import SwiftUI

struct MoreCubesView: View {
    @ObservedObject var model: GameViewModel
    let openGame: (GameCatalogEntry) async throws -> Void

    @State private var cubes: [GameCatalogEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectingCatalogID: String?
    @State private var reloadID = UUID()

    private let service = CubeCatalogService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Browse uploaded cubes")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 22)

                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading cubes…")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
                } else if let errorMessage {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.red)
                        Button("Try again") { reloadID = UUID() }
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(cubacadabraCoral)
                    }
                    .padding(.vertical, 8)
                } else if cubes.isEmpty {
                    Text("No uploaded cubes yet.")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 18)
                } else {
                    VStack(spacing: 0) {
                        ForEach(cubes, id: \.catalogID) { cube in
                            cubeRow(cube)
                            if cube.catalogID != cubes.last?.catalogID {
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                    .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 36)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reloadID) { await loadCubes() }
    }

    private func cubeRow(_ cube: GameCatalogEntry) -> some View {
        Button {
            guard selectingCatalogID == nil, !model.isSelectingGame else { return }
            selectingCatalogID = cube.catalogID
            errorMessage = nil
            Task {
                do {
                    try await openGame(cube)
                } catch is CancellationError {
                    // Navigation or task cancellation does not need an error message.
                } catch {
                    errorMessage = errorMessage(for: error)
                }
                selectingCatalogID = nil
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(cubacadabraCoral)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(cube.title)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(cube.subtitle)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selectingCatalogID == cube.catalogID {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .frame(minHeight: 76)
        }
        .buttonStyle(.plain)
        .disabled(selectingCatalogID != nil || model.isSelectingGame)
        .accessibilityHint("Downloads and opens the \(cube.title) lobby")
    }

    private func loadCubes() async {
        isLoading = true
        errorMessage = nil
        do {
            cubes = try await service.firstPage()
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled {
                errorMessage = errorMessage(for: error)
            }
        }
        if !Task.isCancelled {
            isLoading = false
        }
    }

    private func errorMessage(for error: Error) -> String {
        if let packageError = error as? GamePackageError, case .httpFailure = packageError {
            return "Cubes are unavailable right now. Check your connection and try again."
        }
        return "We couldn’t load the cubes. Please try again."
    }
}
