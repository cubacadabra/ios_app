import Foundation

struct EnginePlayer {
    var position: SIMD3<Float>
    var yaw: Float
    var walkCycle: Float
    var grounded: Bool
    var moving: Bool
    var sprinting: Bool
}

struct EngineRemotePlayer {
    var position: SIMD3<Float>
    var yaw: Float
    var moving: Bool
    var sprinting: Bool
}

struct EngineAgent {
    var position: SIMD3<Float>
    var yaw: Float
    var walkCycle: Float
    var meetingIndex: Int
    var assembled: Bool
}

struct EnginePad {
    var occupants: Int
    var seconds: Float
    var phase: UInt8
}

struct EngineFrame {
    var elapsed: Float
    var player: EnginePlayer
    var agents: [EngineAgent]
    var pads: [EnginePad]
    var camera: SIMD3<Float>
    var playerLaunchPad: Int
    var launchEventID: UInt32
    var lastLaunchPad: Int
    var lastLaunchOccupants: Int
    var activeWorldIndex: Int
    var worldEventID: UInt32
    var lastWorldSourcePad: Int
    var lastWorldDestination: Int
    var settingsRoomState: UInt8
}

final class EngineBridge {
    private let handle: OpaquePointer

    init() throws {
        guard let handle = engine_create() else {
            throw EngineBridgeError.creationFailed
        }
        self.handle = handle
    }

    deinit {
        engine_destroy(handle)
    }

    func loadScript(_ source: String) throws {
        let bytes = Array(source.utf8)
        let pointer = engine_script_buffer_ptr(handle, UInt(bytes.count))
        guard let pointer else { throw EngineBridgeError.scriptBufferFailed }
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            pointer.update(from: baseAddress.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        }
        guard engine_load_script_buffer(handle) != 0 else {
            throw EngineBridgeError.scriptLoadFailed
        }
    }

    func loadPackage(_ source: String) throws {
        let bytes = Array(source.utf8)
        let pointer = engine_package_buffer_ptr(handle, UInt(bytes.count))
        guard let pointer else { throw EngineBridgeError.packageBufferFailed }
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            pointer.update(from: baseAddress.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        }
        guard engine_load_package_buffer(handle) != 0 else {
            throw EngineBridgeError.packageLoadFailed
        }
    }

    func setInput(
        forward: Float,
        strafe: Float,
        sprint: Bool,
        jump: Bool,
        lookX: Float = 0,
        lookY: Float = 0,
        zoomDelta: Float = 0
    ) {
        engine_set_input(handle, forward, strafe, sprint ? 1 : 0, jump ? 1 : 0, lookX, lookY, zoomDelta)
    }

    func setRemotePlayers(_ players: [EngineRemotePlayer]) {
        engine_set_remote_player_count(handle, UInt(players.count))
        for (index, player) in players.enumerated() {
            engine_set_remote_player(
                handle,
                UInt(index),
                player.position.x,
                player.position.y,
                player.position.z,
                player.yaw,
                player.moving ? 1 : 0,
                player.sprinting ? 1 : 0
            )
        }
    }

    func step(_ delta: Float) {
        engine_step(handle, delta)
    }

    func sync(renderer: OpaquePointer) {
        engine_renderer_sync(renderer, handle)
    }

    func frame() -> EngineFrame {
        let agentCount = Int(engine_agent_count(handle))
        let stride = Int(engine_snapshot_stride())
        let snapshotLength = (agentCount + 1) * stride
        let snapshot = UnsafeBufferPointer(
            start: engine_snapshot_ptr(handle),
            count: snapshotLength
        )
        let player = EnginePlayer(
            position: SIMD3(snapshot[safe: 0] ?? 0, snapshot[safe: 1] ?? 0, snapshot[safe: 2] ?? 0),
            yaw: snapshot[safe: 3] ?? 0,
            walkCycle: snapshot[safe: 4] ?? 0,
            grounded: (snapshot[safe: 5] ?? 0) > 0.5,
            moving: (snapshot[safe: 6] ?? 0) > 0.5,
            sprinting: (snapshot[safe: 7] ?? 0) > 0.5
        )
        var agents: [EngineAgent] = []
        for index in 0..<agentCount {
            let offset = (index + 1) * stride
            agents.append(EngineAgent(
                position: SIMD3(snapshot[safe: offset] ?? 0, snapshot[safe: offset + 1] ?? 0, snapshot[safe: offset + 2] ?? 0),
                yaw: snapshot[safe: offset + 3] ?? 0,
                walkCycle: snapshot[safe: offset + 4] ?? 0,
                meetingIndex: Int(snapshot[safe: offset + 6] ?? 0),
                assembled: (snapshot[safe: offset + 7] ?? 0) > 0.5
            ))
        }
        let padCount = Int(engine_launch_pad_count(handle))
        let pads = (0..<padCount).map { index in
            EnginePad(
                occupants: Int(engine_launch_pad_occupants(handle, UInt(index))),
                seconds: engine_launch_pad_seconds(handle, UInt(index)),
                phase: engine_launch_pad_phase(handle, UInt(index))
            )
        }
        return EngineFrame(
            elapsed: engine_elapsed(handle),
            player: player,
            agents: agents,
            pads: pads,
            camera: SIMD3(
                engine_camera_yaw(handle),
                engine_camera_pitch(handle),
                engine_camera_distance(handle)
            ),
            playerLaunchPad: Int(engine_player_launch_pad(handle)),
            launchEventID: engine_launch_event_id(handle),
            lastLaunchPad: Int(engine_last_launch_pad(handle)),
            lastLaunchOccupants: Int(engine_last_launch_occupants(handle)),
            activeWorldIndex: Int(engine_active_world(handle)),
            worldEventID: engine_world_event_id(handle),
            lastWorldSourcePad: Int(engine_last_world_source_pad(handle)),
            lastWorldDestination: Int(engine_last_world_destination(handle)),
            settingsRoomState: engine_settings_room_state(handle)
        )
    }
}

enum EngineBridgeError: LocalizedError {
    case creationFailed
    case scriptBufferFailed
    case scriptLoadFailed
    case packageBufferFailed
    case packageLoadFailed

    var errorDescription: String? {
        switch self {
        case .creationFailed: return "The Rust game engine could not be created."
        case .scriptBufferFailed: return "The Rust game engine could not receive the game script."
        case .scriptLoadFailed: return "The Luau game script could not be loaded."
        case .packageBufferFailed: return "The Rust game engine could not receive the game manifest."
        case .packageLoadFailed: return "The Rust game engine could not load the game manifest."
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension UnsafeBufferPointer {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
