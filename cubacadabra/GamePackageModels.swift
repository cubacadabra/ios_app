import Foundation

struct GamePackage: Decodable {
    let startWorld: String
    let lobby: Bool?
    let launch: LaunchRoute
    let scene: SceneDefinition
    let palette: [String: String]
    let world: WorldSettings
    let launchPads: [LaunchPadDefinition]
    let blocks: [BlockDefinition]
    let worlds: [String: WorldDefinition]

    var lobbyEnabled: Bool { lobby != false }

    var initialWorld: String {
        if lobbyEnabled || startWorld != "lobby" { return startWorld }
        return launch.destinationWorld
    }

    func worldDefinition(named id: String) -> WorldDefinition? {
        if id == "lobby" {
            return WorldDefinition(scene: scene, palette: palette, world: world, launchPads: launchPads, blocks: blocks)
        }
        return worlds[id]
    }

    func runtimeWorldEntries() -> [(id: String, definition: WorldDefinition)] {
        let lobby = worldDefinition(named: "lobby").map { [(id: "lobby", definition: $0)] } ?? []
        return lobby + worlds.keys.sorted().compactMap { id in worlds[id].map { (id: id, definition: $0) } }
    }
}

struct GameCatalogEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String

    static let available = [
        GameCatalogEntry(id: "first-game", title: "First Game", subtitle: "Build together in the clearing"),
        GameCatalogEntry(id: "second-game", title: "Second Game", subtitle: "Drop signals in the relay yard"),
    ]
}

struct LaunchRoute: Decodable { let destinationWorld: String }

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

    private enum CodingKeys: String, CodingKey { case groundSize, gridSize, gridDivisions, spawn, showSpawnPad, clouds }
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

    private enum CodingKeys: String, CodingKey { case id, code, label, position, color, radius, countdown, destinationWorld, enabled, availabilityLabel }
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

    private enum CodingKeys: String, CodingKey { case position, size, color, outline }
}

enum JSONValue: Decodable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

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
    case invalidURL, invalidGameID, httpFailure(Int), invalidScript, missingWorld(String), missingBundledPackage, invalidBundledPackage

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The game package URL is invalid."
        case .invalidGameID: return "That game could not be opened."
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
    private static let defaultLoginURL = "http://localhost:5173/login/"
#else
    private static let defaultBackendURL = "wss://api.cubacadabra.com"
    private static let defaultGameBaseURL = "https://cubacadabra.com/games/first-game/"
    private static let defaultLoginURL = "https://cubacadabra.com/login/"
#endif

    static var backendURL: URL { configuredURL(forKey: "CUBACADABRA_BACKEND_URL", fallback: defaultBackendURL) }
    static var gameBaseURL: URL { configuredURL(forKey: "CUBACADABRA_GAME_BASE_URL", fallback: defaultGameBaseURL) }
    static var backendAPIURL: URL {
        var components = URLComponents(url: backendURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "wss" ? "https" : "http"
        return components.url!
    }
    static var loginURL: URL { URL(string: defaultLoginURL)! }
    static let authCallbackURL = URL(string: "cubacadabra://auth/callback")!

    private static func configuredURL(forKey key: String, fallback: String) -> URL {
        if let configured = ProcessInfo.processInfo.environment[key], let url = URL(string: configured), url.scheme != nil, url.host != nil { return url }
        return URL(string: fallback)!
    }
}

enum AppLinks {
#if DEBUG
    static let about = URL(string: "http://localhost:5173/about/")!
    static let privacy = URL(string: "http://localhost:5173/privacy/")!
    static let terms = URL(string: "http://localhost:5173/terms/")!
#else
    static let about = URL(string: "https://cubacadabra.com/about/")!
    static let privacy = URL(string: "https://cubacadabra.com/privacy/")!
    static let terms = URL(string: "https://cubacadabra.com/terms/")!
#endif
    static let support = URL(string: "mailto:support@cubacadabra.com?subject=Cubacadabra%20safety%20report")!
}
