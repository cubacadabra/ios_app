import MetalKit
import SwiftUI

struct GameRenderScene {
    let blocks: [CubacadabraRenderBlock]
    let pads: [CubacadabraRenderPad]
    let agents: [CubacadabraRenderAgent]
    let player: CubacadabraRenderAgent
    let groundSize: Float
    let palette: CubacadabraRenderPalette
    let elapsed: Float
}

struct RustGameSurface: UIViewRepresentable {
    let scene: GameRenderScene
    let isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = !isActive
        view.delegate = context.coordinator
        context.coordinator.update(scene, isActive: isActive, view: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.update(scene, isActive: isActive, view: view)
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.shutdown()
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private var renderer: OpaquePointer?
        private var pendingScene: GameRenderScene?

        func update(_ scene: GameRenderScene, isActive: Bool, view: MTKView) {
            pendingScene = scene
            view.isPaused = !isActive
            guard isActive else { return }
            attachIfNeeded(to: view)
            applyPendingScene(view: view)
        }

        func draw(in view: MTKView) {
            guard !view.isPaused else { return }
            attachIfNeeded(to: view)
            applyPendingScene(view: view)
            if let renderer {
                engine_renderer_draw(renderer)
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            attachIfNeeded(to: view, drawableSize: size)
            if let renderer {
                engine_renderer_resize(renderer, Float(size.width), Float(size.height))
            }
        }

        func shutdown() {
            if let renderer {
                engine_renderer_destroy(renderer)
                self.renderer = nil
            }
            pendingScene = nil
        }

        private func attachIfNeeded(to view: MTKView, drawableSize: CGSize? = nil) {
            guard renderer == nil else { return }
            let size = drawableSize ?? view.drawableSize
            guard size.width > 0, size.height > 0 else { return }
            guard let layer = view.layer as? CAMetalLayer else { return }
            renderer = engine_renderer_create(
                Unmanaged.passUnretained(layer).toOpaque(),
                Float(size.width),
                Float(size.height)
            )
        }

        private func applyPendingScene(view: MTKView) {
            guard let renderer, let scene = pendingScene else { return }
            scene.blocks.withUnsafeBufferPointer { blocks in
                scene.pads.withUnsafeBufferPointer { pads in
                    scene.agents.withUnsafeBufferPointer { agents in
                        engine_renderer_set_scene(
                            renderer,
                            blocks.baseAddress,
                            UInt(blocks.count),
                            pads.baseAddress,
                            UInt(pads.count),
                            agents.baseAddress,
                            UInt(agents.count),
                            scene.player,
                            scene.groundSize,
                            scene.palette,
                            scene.elapsed
                        )
                    }
                }
            }
            let size = view.drawableSize
            if size.width > 0, size.height > 0 {
                engine_renderer_resize(renderer, Float(size.width), Float(size.height))
            }
        }
    }
}

extension GameViewModel {
    private static let npcPalettes: [(skin: String, shirt: String, pants: String)] = [
        ("#f0b18a", "#e76f51", "#355070"),
        ("#d99770", "#5f8f78", "#3e5974"),
        ("#f4c39f", "#748bd2", "#43515e"),
        ("#c98263", "#f0b54d", "#385c62"),
        ("#e4a77b", "#b276a9", "#4b5e80"),
        ("#f1c29b", "#3f8884", "#414b5b")
    ]

    func renderScene() -> GameRenderScene? {
        guard let world = world(), let frame else { return nil }
        let palette = CubacadabraRenderPalette(
            sky: rgba("paper", in: world, fallback: "#101c22"),
            ground: rgba("ground", in: world, fallback: "#536e70"),
            ground_edge: rgba("groundEdge", in: world, fallback: "#2f4d52"),
            grid: rgba("grid", in: world, fallback: "#78999a"),
            ink: rgba("ink", in: world, fallback: "#172f38")
        )
        let blocks = world.blocks.map { block in
            CubacadabraRenderBlock(
                position: (
                    block.position[safe: 0] ?? 0,
                    block.position[safe: 1] ?? 0,
                    block.position[safe: 2] ?? 0
                ),
                size: (
                    block.size[safe: 0] ?? 1,
                    block.size[safe: 1] ?? 1,
                    block.size[safe: 2] ?? 1
                ),
                color: rgba(block.color, in: world, fallback: "#ffffff")
            )
        }
        let pads = world.launchPads.enumerated().map { index, pad in
            let livePad = frame.pads[safe: index]
            return CubacadabraRenderPad(
                x: pad.position[safe: 0] ?? 0,
                z: pad.position[safe: 2] ?? pad.position[safe: 1] ?? 0,
                radius: pad.radius,
                seconds: livePad?.seconds ?? 0,
                color: rgba(pad.color, in: world, fallback: "#ffffff")
            )
        }
        let agents = frame.agents.enumerated().map { index, agent in
            let colors = Self.npcPalettes[index % Self.npcPalettes.count]
            return CubacadabraRenderAgent(
                position: (agent.position.x, agent.position.y, agent.position.z),
                yaw: agent.yaw,
                walk_cycle: agent.walkCycle,
                assembled: agent.assembled ? 1 : 0,
                skin: rgba(colors.skin, in: world, fallback: "#e8ae86"),
                shirt: rgba(colors.shirt, in: world, fallback: "#2d6663"),
                pants: rgba(colors.pants, in: world, fallback: "#536a90"),
                shoes: rgba("#293a43", in: world, fallback: "#293a43")
            )
        }
        let player = CubacadabraRenderAgent(
            position: (frame.player.position.x, frame.player.position.y, frame.player.position.z),
            yaw: frame.player.yaw,
            walk_cycle: frame.player.walkCycle,
            assembled: 0,
            skin: rgba("#e8ae86", in: world, fallback: "#e8ae86"),
            shirt: rgba("#2d6663", in: world, fallback: "#2d6663"),
            pants: rgba("#536a90", in: world, fallback: "#536a90"),
            shoes: rgba("#293a43", in: world, fallback: "#293a43")
        )
        return GameRenderScene(
            blocks: blocks,
            pads: pads,
            agents: agents,
            player: player,
            groundSize: world.world.groundSize,
            palette: palette,
            elapsed: frame.elapsed
        )
    }

    private func rgba(_ token: String, in world: WorldDefinition, fallback: String) -> (Float, Float, Float, Float) {
        let value = world.palette[token] ?? (token.hasPrefix("#") ? token : fallback)
        let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let number = UInt64(cleaned, radix: 16) ?? 0xffffff
        return (
            Float((number >> 16) & 0xff) / 255,
            Float((number >> 8) & 0xff) / 255,
            Float(number & 0xff) / 255,
            1
        )
    }
}
