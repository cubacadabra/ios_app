import Foundation
import SwiftUI

/// Loads a validated game manifest and script from cache, bundle, or the host.
struct GamePackageLoader {
    // The generated Luau package format changed with the Build Together UI.
    // Versioning these keys prevents an older cached script from overriding a
    // corrected bundle on the first launch after an app update. Version 3
    // also separates the new per-game bundled packages from older caches.
    private static let cachedManifestKeyPrefix = "cubacadabra.cached-manifest.v3."
    private static let cachedScriptKeyPrefix = "cubacadabra.cached-script.v3."
    private static let maximumManifestBytes = 512_000
    private static let maximumScriptBytes = 512_000

    func load(gameID: String = "first-game") async throws -> LoadedGamePackage {
        guard Self.isValidGameID(gameID) else { throw GamePackageError.invalidGameID }
        if let cachedPackage = cachedPackage(for: gameID) { return cachedPackage }
        if let bundledPackage = try? loadBundledPackage(for: gameID) { return bundledPackage }
        return try await fetchPackage(for: gameID)
    }

    /// Refreshes the validated package for the next launch. The bundled
    /// package for each game remains the offline fallback if the host is unavailable.
    func refreshPackage(gameID: String = "first-game") async {
        guard Self.isValidGameID(gameID) else { return }
        let baseURL = remoteBaseURL(for: gameID)
        let manifestURL = baseURL.appendingPathComponent("manifest.json")
        let scriptURL = baseURL.appendingPathComponent("game.luau")
        guard let manifestData = try? await fetch(manifestURL, maximumBytes: Self.maximumManifestBytes),
              let scriptData = try? await fetch(scriptURL, maximumBytes: Self.maximumScriptBytes),
              let script = String(data: scriptData, encoding: .utf8),
              (try? makePackage(manifestData: manifestData, script: script, expectedGameID: gameID)) != nil else { return }
        UserDefaults.standard.set(manifestData, forKey: Self.cachedManifestKeyPrefix + gameID)
        UserDefaults.standard.set(script, forKey: Self.cachedScriptKeyPrefix + gameID)
    }

    private func fetchPackage(for gameID: String) async throws -> LoadedGamePackage {
        let baseURL = remoteBaseURL(for: gameID)
        let manifestData = try await fetch(baseURL.appendingPathComponent("manifest.json"), maximumBytes: Self.maximumManifestBytes)
        let scriptData = try await fetch(baseURL.appendingPathComponent("game.luau"), maximumBytes: Self.maximumScriptBytes)
        guard let script = String(data: scriptData, encoding: .utf8) else { throw GamePackageError.invalidScript }
        let loaded = try makePackage(manifestData: manifestData, script: script, expectedGameID: gameID)
        UserDefaults.standard.set(manifestData, forKey: Self.cachedManifestKeyPrefix + gameID)
        UserDefaults.standard.set(script, forKey: Self.cachedScriptKeyPrefix + gameID)
        return loaded
    }

    private func loadBundledPackage(for gameID: String) throws -> LoadedGamePackage {
        let manifestURL = Bundle.main.url(forResource: "manifest-\(gameID)", withExtension: "json")
            ?? (gameID == "first-game" ? Bundle.main.url(forResource: "manifest", withExtension: "json") : nil)
        let scriptURL = Bundle.main.url(forResource: "game-\(gameID)", withExtension: "luau")
            ?? (gameID == "first-game" ? Bundle.main.url(forResource: "game", withExtension: "luau") : nil)
        guard let manifestURL, let scriptURL,
              let manifestData = try? Data(contentsOf: manifestURL),
              let scriptData = try? Data(contentsOf: scriptURL),
              let script = String(data: scriptData, encoding: .utf8) else { throw GamePackageError.missingBundledPackage }
#if DEBUG
        NSLog("Cubacadabra using %@ package at %@", gameID, scriptURL.path)
#endif
        return try makePackage(manifestData: manifestData, script: script, expectedGameID: gameID)
    }

    private func cachedPackage(for gameID: String) -> LoadedGamePackage? {
        guard let manifestData = cachedManifestData(for: gameID), let script = cachedScriptData(for: gameID) else { return nil }
        return try? makePackage(manifestData: manifestData, script: script, expectedGameID: gameID)
    }

    private func cachedManifestData(for gameID: String) -> Data? {
        guard let data = UserDefaults.standard.data(forKey: Self.cachedManifestKeyPrefix + gameID), data.count <= Self.maximumManifestBytes else { return nil }
        return data
    }

    private func cachedScriptData(for gameID: String) -> String? {
        guard let script = UserDefaults.standard.string(forKey: Self.cachedScriptKeyPrefix + gameID), script.utf8.count <= Self.maximumScriptBytes else { return nil }
        return script
    }

    private func makePackage(manifestData: Data, script: String, expectedGameID: String? = nil) throws -> LoadedGamePackage {
        guard !script.isEmpty, script.utf8.count <= Self.maximumScriptBytes else { throw GamePackageError.invalidScript }
        guard manifestData.count <= Self.maximumManifestBytes, let manifest = String(data: manifestData, encoding: .utf8) else { throw GamePackageError.invalidBundledPackage }
        let package: GamePackage
        do { package = try JSONDecoder().decode(GamePackage.self, from: manifestData) }
        catch { throw GamePackageError.invalidBundledPackage }
        guard package.worldDefinition(named: package.initialWorld) != nil else { throw GamePackageError.missingWorld(package.initialWorld) }
        if let expectedGameID,
           let manifestObject = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
           let manifestGameID = manifestObject["id"] as? String,
           manifestGameID != expectedGameID { throw GamePackageError.invalidGameID }
        return LoadedGamePackage(package: package, manifest: manifest, script: script)
    }

    private func remoteBaseURL(for gameID: String) -> URL {
        var components = URLComponents(url: ClientConfiguration.gameBaseURL, resolvingAgainstBaseURL: false)
        let path = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let parentPath = path.split(separator: "/").dropLast().joined(separator: "/")
        components?.path = "/" + (parentPath.isEmpty ? gameID : parentPath + "/" + gameID) + "/"
        return components?.url ?? ClientConfiguration.gameBaseURL
    }

    private static func isValidGameID(_ gameID: String) -> Bool {
        gameID.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil
    }

    private func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GamePackageError.httpFailure((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard data.count <= maximumBytes else { throw GamePackageError.invalidBundledPackage }
        return data
    }
}

struct LoadedGamePackage {
    let package: GamePackage
    let manifest: String
    let script: String
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(cleaned, radix: 16) ?? 0xffffff
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}
