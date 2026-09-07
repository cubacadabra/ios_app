import Foundation
import simd
import OSLog

extension GameViewModel {
    internal func handleExperienceEvent(_ event: WorldExperienceEvent) {
        if event.type == "experience_launch",
           event.playerIDs.contains(worldSocket.playerID),
           let sessionWorldID = event.sessionWorldID,
           let sessionIndex = runtimeWorldIDs.firstIndex(of: "real-game") {
            pendingSessionWorldID = sessionWorldID
            engine?.startWorld(sessionIndex)
            return
        }
        if event.type == "experience_state", event.kind == "lobby" {
            lobbyLaunchStartsAt = event.startsAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            lobbyLaunchClockOffset = Date().timeIntervalSince1970 - Double(event.serverNow ?? Int64(Date().timeIntervalSince1970 * 1000)) / 1000
            return
        }
        guard event.type == "experience_state", event.kind == "build" else { return }
        buildPhase = event.phase ?? "build"
        buildPrompt = event.prompt ?? "Build together."
        buildBlockCount = event.blockCount ?? 0
        buildBlocks = event.blocks
        engine?.setBuildBlocks(event.blocks.map(engineBlock))
    }

    private func engineBlock(_ block: WorldBuildBlock) -> EngineBuildBlock {
        let size: SIMD3<Float> = switch block.shape {
        case "beam": SIMD3(3, 1, 1)
        case "slab": SIMD3(2, 0.5, 2)
        default: SIMD3(repeating: 1)
        }
        let colors: [String: UInt32] = ["coral": 0xed725b, "butter": 0xf2c764, "periwinkle": 0x7898dc, "ink": 0x264b4b, "paper": 0xf6f1e7]
        return EngineBuildBlock(position: SIMD3(block.x, block.y, block.z), size: size, color: colors[block.color] ?? colors["coral"]!, rotation: UInt8(block.rotation))
    }

    func cycleBuildShape() {
        let shapes = ["cube", "beam", "slab"]
        buildShape = shapes[((shapes.firstIndex(of: buildShape) ?? 0) + 1) % shapes.count]
    }

    func cycleBuildColor() {
        let colors = ["coral", "butter", "periwinkle", "ink", "paper"]
        buildColor = colors[(colors.firstIndex(of: buildColor).map { ($0 + 1) % colors.count } ?? 0)]
    }

    func performBuildAction() {
        guard worldID == "real-game" else {
            gameLog.error("Build action ignored outside real-game; world=\(self.worldID, privacy: .public)")
            showBuildActionNotice("Building is unavailable here")
            return
        }
        guard let frame else {
            gameLog.error("Build action ignored because no engine frame is available")
            showBuildActionNotice("World is still loading")
            return
        }
        let shapes: [String: SIMD3<Float>] = ["cube": SIMD3(repeating: 1), "beam": SIMD3(3, 1, 1), "slab": SIMD3(2, 0.5, 2)]
        let size = shapes[buildShape] ?? SIMD3(repeating: 1)
        let target = SIMD3(
            round((frame.player.position.x + sin(frame.camera.x) * 4) * 2) / 2,
            size.y / 2,
            round((frame.player.position.z - cos(frame.camera.x) * 4) * 2) / 2
        )
        if buildTool == "place" {
            let result = worldSocket.sendExperience("build_action", payload: ["action": "place", "block": ["x": target.x, "y": target.y, "z": target.z, "shape": buildShape, "color": buildColor]])
            handleBuildSendResult(result, action: "place")
            return
        }
        guard let nearest = buildBlocks.min(by: { lhs, rhs in
            distance(SIMD3(lhs.x, lhs.y, lhs.z), target) < distance(SIMD3(rhs.x, rhs.y, rhs.z), target)
        }), distance(SIMD3(nearest.x, nearest.y, nearest.z), target) < 2.1 else {
            showBuildActionNotice("Look toward a nearby block")
            return
        }
        var payload: [String: Any] = ["action": buildTool, "id": nearest.id]
        if buildTool == "recolor" { payload["color"] = buildColor }
        let result = worldSocket.sendExperience("build_action", payload: payload)
        handleBuildSendResult(result, action: buildTool)
    }

    private func handleBuildSendResult(_ result: ExperienceSendResult, action: String) {
        switch result {
        case .sent: gameLog.debug("Build action sent: \(action, privacy: .public)")
        case .queued:
            gameLog.info("Build action queued while reconnecting: \(action, privacy: .public)")
            showBuildActionNotice("Reconnecting — action queued")
        case .unavailable:
            gameLog.error("Build action unavailable: \(action, privacy: .public)")
            showBuildActionNotice("Can’t reach the shared build")
        case .invalid:
            gameLog.error("Build action could not be encoded: \(action, privacy: .public)")
            showBuildActionNotice("Couldn’t send that action")
        }
    }

    private func showBuildActionNotice(_ message: String) {
        buildActionNotice = message
        buildActionNoticeTask?.cancel()
        buildActionNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, self?.buildActionNotice == message else { return }
            self?.buildActionNotice = nil
        }
    }

    func saveBuild() { worldSocket.sendExperience("build_save") }

    func returnToLobby() {
        pendingSessionWorldID = nil
        guard lobbyEnabled else { return }
        guard let index = runtimeWorldIDs.firstIndex(of: "lobby"), engine?.startWorld(index) == true else { return }
        worldID = "lobby"
        buildPhase = "build"
        buildPrompt = ""
        buildBlocks = []
        buildBlockCount = 0
        engine?.setBuildBlocks([])
        worldSocket.setHidden(false)
        connectWorld("lobby")
    }

    func lobbyLaunchStatus(for pad: LaunchPadDefinition, live: EnginePad?) -> String {
        guard pad.enabled else { return pad.availabilityLabel }
        guard let startsAt = lobbyLaunchStartsAt else { return status(for: live) }
        let remaining = startsAt.timeIntervalSince1970 - (Date().timeIntervalSince1970 - lobbyLaunchClockOffset)
        return remaining > 0 ? String(format: "%.1fs", remaining) : "LAUNCHING"
    }

    private func status(for pad: EnginePad?) -> String {
        guard let pad else { return "WAITING" }
        if pad.phase == 2 { return "LAUNCHING" }
        if pad.seconds > 0 { return String(format: "%.1fs · %d", pad.seconds, pad.occupants) }
        return pad.occupants == 0 ? "WAITING" : "ASSEMBLING"
    }
}
