import Foundation

struct EnginePlayer {
    var position: SIMD3<Float>
    var yaw: Float
    var walkCycle: Float
    var grounded: Bool
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

    func configure(package: GamePackage) throws -> [String] {
        let entries = package.runtimeWorldEntries()
        let worldIndices = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })
        engine_set_world_count(handle, UInt(entries.count))

        for (worldIndex, entry) in entries.enumerated() {
            let world = entry.definition
            engine_set_world_spawn(
                handle,
                UInt(worldIndex),
                world.world.spawn[safe: 0] ?? 0,
                world.world.spawn[safe: 1] ?? 0,
                world.world.spawn[safe: 2] ?? 0
            )
            engine_set_world_launch_pad_count(handle, UInt(worldIndex), UInt(world.launchPads.count))
            for (padIndex, pad) in world.launchPads.enumerated() {
                engine_set_world_launch_pad(
                    handle,
                    UInt(worldIndex),
                    UInt(padIndex),
                    pad.position[safe: 0] ?? 0,
                    pad.position[safe: 2] ?? pad.position[safe: 1] ?? 0,
                    pad.radius,
                    pad.countdown
                )
                let destinationID = pad.destinationWorld ?? (entry.id == "lobby" ? package.launch.destinationWorld : nil)
                engine_set_world_launch_destination(
                    handle,
                    UInt(worldIndex),
                    UInt(padIndex),
                    Int32(destinationID.flatMap { worldIndices[$0] } ?? -1)
                )
            }
            engine_set_world_obstacle_count(handle, UInt(worldIndex), UInt(world.blocks.count))
            for (blockIndex, block) in world.blocks.enumerated() {
                engine_set_world_obstacle(
                    handle,
                    UInt(worldIndex),
                    UInt(blockIndex),
                    block.position[safe: 0] ?? 0,
                    block.position[safe: 1] ?? 0,
                    block.position[safe: 2] ?? 0,
                    block.size[safe: 0] ?? 0,
                    block.size[safe: 1] ?? 0,
                    block.size[safe: 2] ?? 0
                )
            }
        }

        guard let startIndex = worldIndices[package.startWorld],
              engine_start_world(handle, UInt(startIndex)) != 0 else {
            throw EngineBridgeError.worldStartFailed(package.startWorld)
        }
        return entries.map(\.id)
    }

    func setInput(forward: Float, strafe: Float, sprint: Bool, jump: Bool, lookX: Float = 0, lookY: Float = 0) {
        engine_set_input(handle, forward, strafe, sprint ? 1 : 0, jump ? 1 : 0, lookX, lookY, 0)
    }

    func step(_ delta: Float) {
        engine_step(handle, delta)
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
            lastWorldDestination: Int(engine_last_world_destination(handle))
        )
    }
}

enum EngineBridgeError: LocalizedError {
    case creationFailed
    case scriptBufferFailed
    case scriptLoadFailed
    case worldStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .creationFailed: return "The Rust game engine could not be created."
        case .scriptBufferFailed: return "The Rust game engine could not receive the game script."
        case .scriptLoadFailed: return "The Luau game script could not be loaded."
        case .worldStartFailed(let id): return "The Rust game engine could not start world \"\(id)\"."
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
