import SwiftUI

struct MoreCubesView: View {
    @ObservedObject var model: AppViewModel
    let openGame: (GameCatalogEntry) async throws -> Void

    @State private var selectingCatalogID: String?
    @State private var gameSelectionError: String?

    private var cubes: [GameCatalogEntry] {
        model.catalogSnapshot.entries.compactMap { entry in
            #if DEBUG
            let packagePath = entry.packagePath
            #else
            let packagePath = entry.assetBaseURL ?? entry.packagePath
            #endif
            let normalizedPackagePath = packagePath.hasSuffix("/") ? packagePath : packagePath + "/"
            guard let packageURL = URL(string: normalizedPackagePath, relativeTo: ClientConfiguration.backendAPIURL)?.absoluteURL,
                  packageURL.path.hasPrefix("/cubes/"),
                  isAllowedPackageURL(packageURL) else { return nil }
            return GameCatalogEntry(
                id: entry.cubeID,
                title: entry.displayName,
                subtitle: "\(entry.cubeID) · v\(entry.version)",
                version: entry.version,
                packageBaseURL: packageURL
            )
        }
    }

    private func isAllowedPackageURL(_ url: URL) -> Bool {
        let backendURL = ClientConfiguration.backendAPIURL
        let isBackendURL = url.scheme == backendURL.scheme
            && url.host == backendURL.host
        #if DEBUG
        return isBackendURL
        #else
        return isBackendURL || (url.scheme == "https" && url.host == ClientConfiguration.publicAssetHost)
        #endif
    }

    private var catalogError: String? { model.catalogSnapshot.feedback?.message }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Browse uploaded cubes")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 22)

                if model.catalogSnapshot.isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading cubes…")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
                } else if let errorMessage = catalogError {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.red)
                        Button("Try again") { model.loadCatalog() }
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
                if let gameSelectionError {
                    Label(gameSelectionError, systemImage: "exclamationmark.circle")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.red)
                        .padding(.top, 10)
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
        .task { model.loadCatalog() }
    }

    private func cubeRow(_ cube: GameCatalogEntry) -> some View {
        Button {
            guard selectingCatalogID == nil else { return }
            selectingCatalogID = cube.catalogID
            gameSelectionError = nil
            Task {
                do {
                    try await openGame(cube)
                } catch is CancellationError {
                    // Navigation or task cancellation does not need an error message.
                } catch {
                    gameSelectionError = error.localizedDescription
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
        .disabled(selectingCatalogID != nil)
        .accessibilityHint("Downloads and opens the \(cube.title) lobby")
    }

}
