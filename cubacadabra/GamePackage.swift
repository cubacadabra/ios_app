import Foundation
import SwiftUI

struct GamePackage: Decodable {
    let startWorld: String
    let launch: LaunchRoute
    let scene: SceneDefinition
    let palette: [String: String]
    let world: WorldSettings
    let launchPads: [LaunchPadDefinition]
    let blocks: [BlockDefinition]
    let worlds: [String: WorldDefinition]

    func worldDefinition(named id: String) -> WorldDefinition? {
        if id == "lobby" {
            return WorldDefinition(
                scene: scene,
                palette: palette,
                world: world,
                launchPads: launchPads,
                blocks: blocks
            )
        }
        return worlds[id]
    }

    func runtimeWorldEntries() -> [(id: String, definition: WorldDefinition)] {
        let lobby = worldDefinition(named: "lobby").map { [(id: "lobby", definition: $0)] } ?? []
        return lobby + worlds.keys.sorted().compactMap { id in
            worlds[id].map { (id: id, definition: $0) }
        }
    }
}

struct LaunchRoute: Decodable {
    let destinationWorld: String
}

struct SceneDefinition: Decodable {
    let eyebrow: String
    let title: String
    let description: String
    let maxPlayers: Int
}

struct WorldDefinition: Decodable {
    let scene: SceneDefinition
    let palette: [String: String]
    let world: WorldSettings
    let launchPads: [LaunchPadDefinition]
    let blocks: [BlockDefinition]
}

struct WorldSettings: Decodable {
    let groundSize: Float
    let gridSize: Float
    let gridDivisions: Int
    let spawn: [Float]
    let showSpawnPad: Bool
    let clouds: [[String: JSONValue]]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groundSize = try container.decodeIfPresent(Float.self, forKey: .groundSize) ?? 120
        gridSize = try container.decodeIfPresent(Float.self, forKey: .gridSize) ?? 112
        gridDivisions = try container.decodeIfPresent(Int.self, forKey: .gridDivisions) ?? 28
        spawn = try container.decodeIfPresent([Float].self, forKey: .spawn) ?? [0, 0, 0]
        showSpawnPad = try container.decodeIfPresent(Bool.self, forKey: .showSpawnPad) ?? true
        clouds = try container.decodeIfPresent([[String: JSONValue]].self, forKey: .clouds) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case groundSize, gridSize, gridDivisions, spawn, showSpawnPad, clouds
    }
}

struct LaunchPadDefinition: Decodable, Identifiable {
    let id: String
    let code: String
    let label: String
    let position: [Float]
    let color: String
    let radius: Float
    let countdown: Float
    let destinationWorld: String?
    let enabled: Bool
    let availabilityLabel: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        code = try container.decode(String.self, forKey: .code)
        label = try container.decode(String.self, forKey: .label)
        position = try container.decode([Float].self, forKey: .position)
        color = try container.decode(String.self, forKey: .color)
        radius = try container.decodeIfPresent(Float.self, forKey: .radius) ?? 2.7
        countdown = try container.decodeIfPresent(Float.self, forKey: .countdown) ?? 8
        destinationWorld = try container.decodeIfPresent(String.self, forKey: .destinationWorld)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        availabilityLabel = try container.decodeIfPresent(String.self, forKey: .availabilityLabel) ?? "COMING SOON"
    }

    private enum CodingKeys: String, CodingKey {
        case id, code, label, position, color, radius, countdown, destinationWorld, enabled, availabilityLabel
    }
}

struct BlockDefinition: Decodable {
    let position: [Float]
    let size: [Float]
    let color: String
    let outline: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decode([Float].self, forKey: .position)
        size = try container.decode([Float].self, forKey: .size)
        color = try container.decode(String.self, forKey: .color)
        outline = try container.decodeIfPresent(Bool.self, forKey: .outline) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case position, size, color, outline
    }
}

enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }
}

enum GamePackageError: LocalizedError {
    case invalidURL
    case httpFailure(Int)
    case invalidScript
    case missingWorld(String)
    case missingBundledPackage
    case invalidBundledPackage

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The game package URL is invalid."
        case .httpFailure(let status): return "The game package server returned HTTP \(status)."
        case .invalidScript: return "The game script was not valid UTF-8."
        case .missingWorld(let id): return "The game world \"\(id)\" was not found."
        case .missingBundledPackage: return "The bundled first game could not be found."
        case .invalidBundledPackage: return "The bundled first game could not be opened."
        }
    }
}

enum ClientConfiguration {
#if DEBUG
    private static let defaultBackendURL = "ws://localhost:8787"
    private static let defaultGameBaseURL = "http://localhost:5173/games/first-game/"
    #else
    private static let defaultBackendURL = "wss://api.cubacadabra.com"
    private static let defaultGameBaseURL = "https://cubacadabra.com/games/first-game/"
    #endif

    static var backendURL: URL {
        configuredURL(forKey: "CUBACADABRA_BACKEND_URL", fallback: defaultBackendURL)
    }

    static var gameBaseURL: URL {
        configuredURL(forKey: "CUBACADABRA_GAME_BASE_URL", fallback: defaultGameBaseURL)
    }

    private static func configuredURL(forKey key: String, fallback: String) -> URL {
        if let configured = ProcessInfo.processInfo.environment[key],
           let url = URL(string: configured),
           url.scheme != nil,
           url.host != nil {
            return url
        }
        return URL(string: fallback)!
    }
}

enum AppLinks {
#if DEBUG
    static let privacy = URL(string: "http://localhost:5173/privacy/")!
    static let terms = URL(string: "http://localhost:5173/terms/")!
#else
    static let privacy = URL(string: "https://cubacadabra.com/privacy/")!
    static let terms = URL(string: "https://cubacadabra.com/terms/")!
#endif
    static let support = URL(string: "mailto:support@cubacadabra.com?subject=Cubacadabra%20safety%20report")!
}

struct GamePackageLoader {
    var baseURL = ClientConfiguration.gameBaseURL
    // The generated Luau package format changed with the Build Together UI.
    // Versioning these keys prevents an older cached script from overriding a
    // corrected bundle on the first launch after an app update.
    private static let cachedManifestKey = "cubacadabra.cached-manifest.v2"
    private static let cachedScriptKey = "cubacadabra.cached-script.v2"
    private static let maximumManifestBytes = 512_000
    private static let maximumScriptBytes = 512_000

    func load() async throws -> LoadedGamePackage {
        let bundled = try loadBundledPackage()
        if let cachedManifest = cachedManifestData(),
           let cachedScript = cachedScriptData(),
           let cachedPackage = try? makePackage(manifestData: cachedManifest, script: cachedScript) {
            return cachedPackage
        }
        return bundled
    }

    /// Refreshes the validated package for the next launch. The bundled
    /// package remains the offline fallback if the host is unavailable.
    func refreshPackage() async {
        let manifestURL = baseURL.appendingPathComponent("manifest.json")
        let scriptURL = baseURL.appendingPathComponent("game.luau")
        guard let manifestData = try? await fetch(manifestURL, maximumBytes: Self.maximumManifestBytes),
              let scriptData = try? await fetch(scriptURL, maximumBytes: Self.maximumScriptBytes),
              let script = String(data: scriptData, encoding: .utf8),
              (try? makePackage(manifestData: manifestData, script: script)) != nil else {
            return
        }
        UserDefaults.standard.set(manifestData, forKey: Self.cachedManifestKey)
        UserDefaults.standard.set(script, forKey: Self.cachedScriptKey)
    }

    private func loadBundledPackage() throws -> LoadedGamePackage {
        guard let manifestURL = Bundle.main.url(forResource: "manifest", withExtension: "json"),
              let scriptURL = Bundle.main.url(forResource: "game", withExtension: "luau"),
              let manifestData = try? Data(contentsOf: manifestURL),
              let scriptData = try? Data(contentsOf: scriptURL),
              let script = String(data: scriptData, encoding: .utf8) else {
            throw GamePackageError.missingBundledPackage
        }
#if DEBUG
        NSLog("Cubacadabra using game.luau at %@\n%@", scriptURL.path, script)
#endif
        return try makePackage(manifestData: manifestData, script: script)
    }

    private func cachedManifestData() -> Data? {
        guard let data = UserDefaults.standard.data(forKey: Self.cachedManifestKey),
              data.count <= Self.maximumManifestBytes else { return nil }
        return data
    }

    private func cachedScriptData() -> String? {
        guard let script = UserDefaults.standard.string(forKey: Self.cachedScriptKey),
              script.utf8.count <= Self.maximumScriptBytes else { return nil }
        return script
    }

    private func makePackage(manifestData: Data, script: String) throws -> LoadedGamePackage {
        guard !script.isEmpty, script.utf8.count <= Self.maximumScriptBytes else {
            throw GamePackageError.invalidScript
        }
        guard manifestData.count <= Self.maximumManifestBytes,
              let manifest = String(data: manifestData, encoding: .utf8) else {
            throw GamePackageError.invalidBundledPackage
        }
        let package: GamePackage
        do {
            package = try JSONDecoder().decode(GamePackage.self, from: manifestData)
        } catch {
            throw GamePackageError.invalidBundledPackage
        }
        guard package.worldDefinition(named: package.startWorld) != nil else {
            throw GamePackageError.missingWorld(package.startWorld)
        }
        return LoadedGamePackage(package: package, manifest: manifest, script: script)
    }

    private func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GamePackageError.httpFailure((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard data.count <= maximumBytes else {
            throw GamePackageError.invalidBundledPackage
        }
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
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}
