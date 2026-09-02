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

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The game package URL is invalid."
        case .httpFailure(let status): return "The game package server returned HTTP \(status)."
        case .invalidScript: return "The game script was not valid UTF-8."
        case .missingWorld(let id): return "The game world \"\(id)\" was not found."
        }
    }
}

enum ClientConfiguration {
    #if DEBUG
    private static let defaultBackendURL = "ws://127.0.0.1:8787"
    private static let defaultGameBaseURL = "http://127.0.0.1:5173/games/first-game/"
    #else
    private static let defaultBackendURL = "wss://cubacadabra.andrew-f97.workers.dev"
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

struct GamePackageLoader {
    var baseURL = ClientConfiguration.gameBaseURL

    func load() async throws -> LoadedGamePackage {
        let manifestURL = baseURL.appendingPathComponent("manifest.json")
        let scriptURL = baseURL.appendingPathComponent("game.luau")
        async let manifestData = fetch(manifestURL)
        async let scriptData = fetch(scriptURL)
        let loadedManifestData = try await manifestData
        let loadedScriptData = try await scriptData
        let package = try JSONDecoder().decode(GamePackage.self, from: loadedManifestData)
        guard let manifest = String(data: loadedManifestData, encoding: .utf8),
              let script = String(data: loadedScriptData, encoding: .utf8) else {
            throw GamePackageError.invalidScript
        }
        guard package.worldDefinition(named: package.startWorld) != nil else {
            throw GamePackageError.missingWorld(package.startWorld)
        }
        return LoadedGamePackage(package: package, manifest: manifest, script: script)
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GamePackageError.httpFailure((response as? HTTPURLResponse)?.statusCode ?? 0)
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
