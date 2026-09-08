import Foundation

struct CubeCatalogService {
    private static let maximumResponseBytes = 512 * 1024

    private struct Response: Decodable {
        let cubes: [RemoteCube]
    }

    private struct RemoteCube: Decodable {
        let id: Int
        let cubeID: String
        let version: String
        let displayName: String
        let fileCount: Int
        let packagePath: String
        let assetBaseURL: String?

        enum CodingKeys: String, CodingKey {
            case id
            case cubeID = "cubeId"
            case version
            case displayName
            case fileCount
            case packagePath
            case assetBaseURL
        }
    }

    func firstPage(pageSize: Int = 20) async throws -> [GameCatalogEntry] {
        var components = URLComponents(
            url: ClientConfiguration.backendAPIURL.appendingPathComponent("cubes"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "page_size", value: String(pageSize)),
        ]
        guard let url = components?.url else { throw GamePackageError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw GamePackageError.httpFailure((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw GamePackageError.invalidBundledPackage
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GamePackageError.invalidBundledPackage
        }

        return try decoded.cubes.map { cube in
            let backendURL = ClientConfiguration.backendAPIURL
#if DEBUG
            let packagePath = cube.packagePath
#else
            let packagePath = cube.assetBaseURL ?? cube.packagePath
#endif
            let isBackendPackageURL = { (url: URL) in
                url.scheme == backendURL.scheme
                    && url.host == backendURL.host
                    && url.path.hasPrefix("/cubes/")
            }
#if !DEBUG
            let isPublicAssetURL = { (url: URL) in
                url.scheme == "https"
                    && url.host == ClientConfiguration.publicAssetHost
                    && url.path.hasPrefix("/cubes/")
            }
#endif
            let isAllowedPackageURL: (URL) -> Bool
#if DEBUG
            isAllowedPackageURL = isBackendPackageURL
#else
            isAllowedPackageURL = { url in isBackendPackageURL(url) || isPublicAssetURL(url) }
#endif
            guard Self.isValidGameID(cube.cubeID),
                  cube.packagePath.hasPrefix("/cubes/"),
                  packagePath.hasSuffix("/"),
                  let packageURL = URL(string: packagePath, relativeTo: ClientConfiguration.backendAPIURL)?.absoluteURL,
                  isAllowedPackageURL(packageURL),
                  !packageURL.path.isEmpty else {
                throw GamePackageError.invalidGameID
            }
            return GameCatalogEntry(
                id: cube.cubeID,
                title: cube.displayName,
                subtitle: "\(cube.cubeID) · v\(cube.version)",
                version: cube.version,
                packageBaseURL: packageURL
            )
        }
    }

    private static func isValidGameID(_ gameID: String) -> Bool {
        gameID.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil
    }
}
