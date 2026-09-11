import Foundation

struct EnginePlayer {
    var position: SIMD3<Float>
    var yaw: Float
    var walkCycle: Float
    var grounded: Bool
    var moving: Bool
    var sprinting: Bool
}

struct EngineBuildBlock {
    var position: SIMD3<Float>
    var size: SIMD3<Float>
    var color: UInt32
    var rotation: UInt8
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
    var playerRespawnEventID: UInt32
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
    private let clientHandle: OpaquePointer
    private let handle: OpaquePointer
    private var packageImageAtlas: GameImageAtlas?
    private var morphPacks: [Data] = []

    init(manifest: String, script: String) throws {
        let manifestBytes = Array(manifest.utf8)
        let scriptBytes = Array(script.utf8)
        let created = manifestBytes.withUnsafeBytes { manifestBuffer in
            scriptBytes.withUnsafeBytes { scriptBuffer in
                client_create(
                    manifestBuffer.bindMemory(to: UInt8.self).baseAddress,
                    UInt(manifestBytes.count),
                    scriptBuffer.bindMemory(to: UInt8.self).baseAddress,
                    UInt(scriptBytes.count)
                )
            }
        }
        guard let clientHandle = created, let handle = client_engine(clientHandle) else {
            if let created { client_destroy(created) }
            throw EngineBridgeError.creationFailed
        }
        self.clientHandle = clientHandle
        self.handle = handle
    }

    deinit {
        client_destroy(clientHandle)
    }

    func transportConnected() {
        client_transport_connected(clientHandle)
    }

    func transportDisconnected() {
        client_transport_disconnected(clientHandle)
    }

    func requestTransport() {
        client_request_transport(clientHandle)
    }

    @discardableResult
    func receiveTransportMessage(_ data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            client_receive_text(
                clientHandle,
                rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                UInt(data.count)
            ) != 0
        }
    }

    func setIgnoredPlayerIDs(_ playerIDs: Set<String>) {
        guard let data = try? JSONEncoder().encode(playerIDs.sorted()) else { return }
        data.withUnsafeBytes { rawBuffer in
            _ = client_set_ignored_player_ids_json(
                clientHandle,
                rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                UInt(data.count)
            )
        }
    }

    func pollClientActions() -> [EngineClientAction] {
        var actions: [EngineClientAction] = []
        while true {
            let kind = client_poll_action(clientHandle)
            guard kind != CUBACADABRA_CLIENT_ACTION_NONE else { return actions }
            let length = Int(client_action_len(clientHandle))
            guard length > 0, let pointer = client_action_ptr(clientHandle) else { continue }
            let source = String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
            if kind == CUBACADABRA_CLIENT_ACTION_SET_WORLD {
                actions.append(.setWorld(source))
            } else if kind == CUBACADABRA_CLIENT_ACTION_SEND_TEXT {
                actions.append(.sendText(source))
            }
        }
    }

    @discardableResult
    func setLocalAppearance(_ source: String) -> UInt8 {
        let bytes = Array(source.utf8)
        return bytes.withUnsafeBytes { rawBuffer in
            let pointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return engine_set_local_appearance_json(handle, pointer, UInt(bytes.count))
        }
    }

    func resetView() {
        engine_reset_view(handle)
    }

    var appearanceRevision: UInt32 {
        engine_appearance_revision(handle)
    }

    var appearanceStatus: UInt8 {
        engine_appearance_status(handle)
    }

    func pollAudioMessage() -> Data? {
        guard engine_audio_poll_message(handle) != 0 else { return nil }
        let length = Int(engine_audio_message_len(handle))
        guard length > 0, let pointer = engine_audio_message_ptr(handle) else {
            return Data()
        }
        return Data(bytes: pointer, count: length)
    }

    func setInput(
        forward: Float,
        strafe: Float,
        sprint: Bool,
        jump: Bool,
        climb: Bool,
        lookX: Float = 0,
        lookY: Float = 0,
        zoomDelta: Float = 0
    ) {
        engine_set_input(handle, forward, strafe, sprint ? 1 : 0, jump ? 1 : 0, climb ? 1 : 0, lookX, lookY, zoomDelta)
    }

    func setUIViewport(
        width: Float,
        height: Float,
        scale: Float,
        safeTop: Float,
        safeRight: Float,
        safeBottom: Float,
        safeLeft: Float
    ) {
        engine_set_ui_viewport(
            handle,
            width,
            height,
            scale,
            safeTop,
            safeRight,
            safeBottom,
            safeLeft
        )
    }

    func setAuthenticated(_ authenticated: Bool) {
        engine_set_authenticated(handle, authenticated ? 1 : 0)
    }

    @discardableResult
    func uiPointer(pointerID: UInt64, phase: UInt8, x: Float, y: Float) -> Bool {
        engine_ui_pointer(handle, pointerID, phase, x, y) != 0
    }

    func pollUIEvent() -> Data? {
        guard engine_ui_poll_event(handle) != 0 else { return nil }
        let length = Int(engine_ui_event_len(handle))
        guard length > 0, let pointer = engine_ui_event_ptr(handle) else {
            return Data()
        }
        return Data(bytes: pointer, count: length)
    }

    var uiNodeCount: Int {
        Int(engine_ui_node_count(handle))
    }

    func setBuildBlocks(_ blocks: [EngineBuildBlock]) {
        engine_set_build_block_count(handle, UInt(blocks.count))
        for (index, block) in blocks.enumerated() {
            engine_set_build_block(
                handle,
                UInt(index),
                block.position.x,
                block.position.y,
                block.position.z,
                block.size.x,
                block.size.y,
                block.size.z,
                block.color,
                block.rotation
            )
        }
    }

    func setPackageImageAtlas(_ atlas: GameImageAtlas?) {
        packageImageAtlas = atlas
    }

    func setMorphPacks(_ packs: [Data]) {
        morphPacks = packs
    }

    /// Enables the shared neutral character preview scene for an editor
    /// surface. Normal game surfaces leave this disabled.
    func setAvatarPreviewMode(_ enabled: Bool, renderer: OpaquePointer) {
        _ = engine_renderer_set_avatar_preview_mode(renderer, enabled ? 1 : 0)
    }

    @discardableResult
    func uploadMorphPacks(to renderer: OpaquePointer) -> Bool {
        for pack in morphPacks {
            let accepted = pack.withUnsafeBytes { buffer in
                engine_renderer_register_morph_pack(
                    renderer,
                    buffer.bindMemory(to: UInt8.self).baseAddress,
                    UInt(pack.count)
                ) != 0
            }
            if !accepted { return false }
        }
        return true
    }

    @discardableResult
    func uploadPackageImageAtlas(to renderer: OpaquePointer) -> Bool {
        guard let atlas = packageImageAtlas else { return true }
        let regionData = Data(atlas.regionsJSON.utf8)
        return atlas.pixels.withUnsafeBytes { pixelBuffer in
            regionData.withUnsafeBytes { regionBuffer in
                engine_renderer_set_package_image_atlas(
                    renderer,
                    UInt32(atlas.width),
                    UInt32(atlas.height),
                    pixelBuffer.bindMemory(to: UInt8.self).baseAddress,
                    UInt(atlas.pixels.count),
                    regionBuffer.bindMemory(to: UInt8.self).baseAddress,
                    UInt(regionData.count)
                ) != 0
            }
        }
    }

    @discardableResult
    func setUsername(_ username: String) -> Bool {
        let bytes = Array(username.utf8)
        guard let pointer = engine_username_buffer_ptr(handle, UInt(bytes.count)) else {
            return false
        }
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            pointer.update(from: baseAddress.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        }
        return engine_load_username_buffer(handle) != 0
    }

    func step(_ delta: Float) {
        engine_step(handle, delta)
    }

    @discardableResult
    func startWorld(_ index: Int) -> Bool {
        engine_start_world(handle, UInt(index)) != 0
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
            yaw: engine_player_facing_yaw(handle),
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
            playerRespawnEventID: engine_player_respawn_event_id(handle),
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

    var errorDescription: String? {
        switch self {
        case .creationFailed: return "The Rust game engine could not be created."
        }
    }
}

enum EngineClientAction {
    case setWorld(String)
    case sendText(String)
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
