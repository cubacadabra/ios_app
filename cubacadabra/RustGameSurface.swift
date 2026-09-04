import MetalKit
import SwiftUI
import UIKit

struct RustGameSurface: UIViewRepresentable {
    let engine: EngineBridge
    let isActive: Bool
    var onLookChanged: (CGSize) -> Void = { _ in }
    var onLookEnded: () -> Void = {}
    var onZoomDelta: (CGFloat) -> Void = { _ in }
    var onZoomEnded: () -> Void = {}
    var onWorldTap: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> InteractiveGameView {
        let view = InteractiveGameView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        // Match the native renderer's unorm surface so palette hex values are
        // presented with the same contrast as the browser client.
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = !isActive
        view.isMultipleTouchEnabled = true
        view.delegate = context.coordinator
        context.coordinator.update(self, view: view)
        return view
    }

    func updateUIView(_ view: InteractiveGameView, context: Context) {
        context.coordinator.update(self, view: view)
    }

    static func dismantleUIView(_ view: InteractiveGameView, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.shutdown()
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private var renderer: OpaquePointer?
        private var engine: EngineBridge?

        func update(_ surface: RustGameSurface, view: InteractiveGameView) {
            engine = surface.engine
            view.isPaused = !surface.isActive
            view.onViewportChange = { [weak self] size, scale, safeArea in
                self?.engine?.setUIViewport(
                    width: Float(size.width),
                    height: Float(size.height),
                    scale: Float(scale),
                    safeTop: Float(safeArea.top),
                    safeRight: Float(safeArea.right),
                    safeBottom: Float(safeArea.bottom),
                    safeLeft: Float(safeArea.left)
                )
            }
            view.onPointer = { [weak self] pointerID, phase, point in
                guard let engine = self?.engine else { return false }
                return engine.uiPointer(
                    pointerID: pointerID,
                    phase: phase,
                    x: Float(point.x),
                    y: Float(point.y)
                )
            }
            view.onLookChanged = surface.onLookChanged
            view.onLookEnded = surface.onLookEnded
            view.onZoomDelta = surface.onZoomDelta
            view.onZoomEnded = surface.onZoomEnded
            view.onWorldTap = surface.onWorldTap
            view.onViewportChange?(view.bounds.size, view.contentScaleFactor, view.safeAreaInsets)
            guard surface.isActive else { return }
            attachIfNeeded(to: view)
            syncEngine()
        }

        func draw(in view: MTKView) {
            guard !view.isPaused else { return }
            attachIfNeeded(to: view)
            syncEngine()
            if let renderer { engine_renderer_draw(renderer) }
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

final class InteractiveGameView: MTKView {
    var onViewportChange: ((CGSize, CGFloat, UIEdgeInsets) -> Void)?
    var onPointer: ((UInt64, UInt8, CGPoint) -> Bool)?
    var onLookChanged: ((CGSize) -> Void)?
    var onLookEnded: (() -> Void)?
    var onZoomDelta: ((CGFloat) -> Void)?
    var onZoomEnded: (() -> Void)?
    var onWorldTap: (() -> Void)?

    private var nextPointerID: UInt64 = 1
    private var pointerIDs: [ObjectIdentifier: UInt64] = [:]
    private var uiPointers = Set<UInt64>()
    private var cameraTouches: [UInt64: CGPoint] = [:]
    private var cameraTouchMoved = false
    private var previousPinchDistance: CGFloat?

    override func layoutSubviews() {
        super.layoutSubviews()
        onViewportChange?(bounds.size, contentScaleFactor, safeAreaInsets)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let pointerID = pointerID(for: touch)
            let point = touch.location(in: self)
            if onPointer?(pointerID, UInt8(CUBACADABRA_UI_POINTER_DOWN), point) == true {
                uiPointers.insert(pointerID)
            } else {
                cameraTouches[pointerID] = point
            }
        }
        updatePinchDistance()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let pointerID = pointerID(for: touch)
            let point = touch.location(in: self)
            if uiPointers.contains(pointerID) {
                _ = onPointer?(pointerID, UInt8(CUBACADABRA_UI_POINTER_MOVE), point)
            } else if cameraTouches[pointerID] != nil {
                if cameraTouches.count == 1, let previous = cameraTouches[pointerID] {
                    onLookChanged?(CGSize(width: point.x - previous.x, height: point.y - previous.y))
                    cameraTouchMoved = true
                }
                cameraTouches[pointerID] = point
            }
        }
        updatePinchDistance()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, phase: UInt8(CUBACADABRA_UI_POINTER_UP))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, phase: UInt8(CUBACADABRA_UI_POINTER_CANCEL))
    }

    private func finish(_ touches: Set<UITouch>, phase: UInt8) {
        let wasCameraInteraction = !cameraTouches.isEmpty
        for touch in touches {
            let pointerID = pointerID(for: touch)
            let point = touch.location(in: self)
            if uiPointers.remove(pointerID) != nil {
                _ = onPointer?(pointerID, phase, point)
            } else {
                cameraTouches.removeValue(forKey: pointerID)
            }
            pointerIDs.removeValue(forKey: ObjectIdentifier(touch))
        }
        if cameraTouches.isEmpty {
            onLookEnded?()
            if phase == UInt8(CUBACADABRA_UI_POINTER_UP) && wasCameraInteraction && !cameraTouchMoved {
                onWorldTap?()
            }
            cameraTouchMoved = false
        }
        updatePinchDistance()
    }

    private func pointerID(for touch: UITouch) -> UInt64 {
        let identity = ObjectIdentifier(touch)
        if let pointerID = pointerIDs[identity] { return pointerID }
        let pointerID = nextPointerID
        nextPointerID &+= 1
        pointerIDs[identity] = pointerID
        return pointerID
    }

    private func updatePinchDistance() {
        guard cameraTouches.count >= 2 else {
            if previousPinchDistance != nil { onZoomEnded?() }
            previousPinchDistance = nil
            return
        }
        let points = Array(cameraTouches.values.prefix(2))
        let distance = hypot(points[0].x - points[1].x, points[0].y - points[1].y)
        if let previousPinchDistance {
            onZoomDelta?((distance - previousPinchDistance) / 100)
        }
        previousPinchDistance = distance
    }
}
