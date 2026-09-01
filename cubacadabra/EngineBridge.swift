import Foundation

struct EnginePlayer {
    var position: SIMD3<Float>
    var yaw: Float
    var grounded: Bool
    var moving: Bool
    var sprinting: Bool
}

struct EngineAgent {
    var position: SIMD3<Float>
    var yaw: Float
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
    var playerLaunchPad: Int
    var launchEventID: UInt32
    var lastLaunchPad: Int
    var lastLaunchOccupants: Int
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

    func configure(world: WorldDefinition) {
        engine_set_launch_pad_count(handle, UInt(world.launchPads.count))
        for (index, pad) in world.launchPads.enumerated() {
            engine_set_launch_pad(
                handle,
                UInt(index),
                pad.position[safe: 0] ?? 0,
                pad.position[safe: 2] ?? pad.position[safe: 1] ?? 0,
                pad.radius,
                pad.countdown
            )
        }
        configureObstacles(world.blocks)
    }

    func configureObstacles(_ blocks: [BlockDefinition]) {
        engine_set_obstacle_count(handle, UInt(blocks.count))
        for (index, block) in blocks.enumerated() {
            engine_set_obstacle(
                handle,
                UInt(index),
                block.position[safe: 0] ?? 0,
                block.position[safe: 1] ?? 0,
                block.position[safe: 2] ?? 0,
                block.size[safe: 0] ?? 0,
                block.size[safe: 1] ?? 0,
                block.size[safe: 2] ?? 0
            )
        }
    }

    func setInput(forward: Float, strafe: Float, sprint: Bool, jump: Bool, lookX: Float = 0, lookY: Float = 0) {
        engine_set_input(handle, forward, strafe, sprint ? 1 : 0, jump ? 1 : 0, lookX, lookY, 0)
    }

    func step(_ delta: Float) {
        engine_step(handle, delta)
    }

    @discardableResult
    func enterSession(launchPadIndex: Int, spawn: [Float]) -> Int {
        Int(engine_enter_session(
            handle,
            UInt(launchPadIndex),
            spawn[safe: 0] ?? 0,
            spawn[safe: 1] ?? 0,
            spawn[safe: 2] ?? 0
        ))
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
            playerLaunchPad: Int(engine_player_launch_pad(handle)),
            launchEventID: engine_launch_event_id(handle),
            lastLaunchPad: Int(engine_last_launch_pad(handle)),
            lastLaunchOccupants: Int(engine_last_launch_occupants(handle))
        )
    }
}

enum EngineBridgeError: LocalizedError {
    case creationFailed
    case scriptBufferFailed
    case scriptLoadFailed

    var errorDescription: String? {
        switch self {
        case .creationFailed: return "The Rust game engine could not be created."
        case .scriptBufferFailed: return "The Rust game engine could not receive the game script."
        case .scriptLoadFailed: return "The Luau game script could not be loaded."
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
