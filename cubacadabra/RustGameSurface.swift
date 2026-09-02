import MetalKit
import SwiftUI

struct RustGameSurface: UIViewRepresentable {
    let engine: EngineBridge
    let isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        // Match the native renderer's unorm surface so palette hex values are
        // presented with the same contrast as the browser client.
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = !isActive
        view.delegate = context.coordinator
        context.coordinator.update(engine, isActive: isActive, view: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.update(engine, isActive: isActive, view: view)
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.shutdown()
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private var renderer: OpaquePointer?
        private var engine: EngineBridge?

        func update(_ engine: EngineBridge, isActive: Bool, view: MTKView) {
            self.engine = engine
            view.isPaused = !isActive
            guard isActive else { return }
            attachIfNeeded(to: view)
            syncEngine()
        }

        func draw(in view: MTKView) {
            guard !view.isPaused else { return }
            attachIfNeeded(to: view)
            syncEngine()
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
            engine = nil
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

        private func syncEngine() {
            guard let renderer, let engine else { return }
            engine.sync(renderer: renderer)
        }
    }
}
