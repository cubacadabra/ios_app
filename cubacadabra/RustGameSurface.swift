import MetalKit
import OSLog
import SwiftUI
import UIKit

private let rustSurfaceLog = Logger(subsystem: "com.cubacadabra.app", category: "rust-surface")

struct RustGameSurface: UIViewRepresentable {
    let engine: EngineBridge
    let isActive: Bool
    var avatarPreviewMode: Bool = false
    var handlesPinchZoom: Bool = true
    var onMoveChanged: (CGSize) -> Void = { _ in }
    var onMoveEnded: () -> Void = {}
    var onLookChanged: (CGSize) -> Void = { _ in }
    var onLookEnded: () -> Void = {}
    var onZoomDelta: (CGFloat) -> Void = { _ in }
    var onZoomEnded: () -> Void = {}
    var onInteractionChanged: (Bool) -> Void = { _ in }
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
        private var packageImagesEngine: EngineBridge?
        private var uploadedMorphPackVersion = -1
        private var uploadedMorphPackCount = 0
        private var lastViewportDescription = ""
        private var lastDrawableSize = CGSize.zero
        private var avatarPreviewMode = false

        func update(_ surface: RustGameSurface, view: InteractiveGameView) {
            engine = surface.engine
            avatarPreviewMode = surface.avatarPreviewMode
            view.isPaused = !surface.isActive
            view.onViewportChange = { [weak self] size, scale, safeArea in
                let description = "\(Int(size.width))x\(Int(size.height)) @\(scale), safe=\(Int(safeArea.top))/\(Int(safeArea.right))/\(Int(safeArea.bottom))/\(Int(safeArea.left))"
                if self?.lastViewportDescription != description {
                    self?.lastViewportDescription = description
                    rustSurfaceLog.info("Rust UI viewport \(description, privacy: .public)")
                }
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
            view.onDrawableSizeChange = { [weak self, weak view] size in
                guard let view else { return }
                self?.resizeRenderer(to: size, view: view)
            }
            view.onPointer = { [weak self] pointerID, phase, point in
                guard let self, !self.avatarPreviewMode, let engine = self.engine else { return false }
                return engine.uiPointer(
                    pointerID: pointerID,
                    phase: phase,
                    x: Float(point.x),
                    y: Float(point.y)
                )
            }
            view.usesSplitPreviewControls = surface.avatarPreviewMode
            view.handlesPinchZoom = surface.handlesPinchZoom
            view.onMoveChanged = surface.onMoveChanged
            view.onMoveEnded = surface.onMoveEnded
            view.onLookChanged = surface.onLookChanged
            view.onLookEnded = surface.onLookEnded
            view.onZoomDelta = surface.onZoomDelta
            view.onZoomEnded = surface.onZoomEnded
            view.onInteractionChanged = surface.onInteractionChanged
            view.onWorldTap = surface.onWorldTap
            view.onViewportChange?(view.bounds.size, view.contentScaleFactor, view.safeAreaInsets)
            resizeRenderer(to: view.drawableSize, view: view)
            guard surface.isActive else { return }
            attachIfNeeded(to: view)
            if let renderer {
                surface.engine.setAvatarPreviewMode(surface.avatarPreviewMode, renderer: renderer)
            }
            uploadPackageImagesIfNeeded()
            syncEngine()
        }

        func draw(in view: MTKView) {
            guard !view.isPaused else { return }
            attachIfNeeded(to: view)
            uploadPackageImagesIfNeeded()
            syncEngine()
            if let renderer { engine_renderer_draw(renderer) }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            guard let view = view as? InteractiveGameView else { return }
            resizeRenderer(to: size, view: view)
        }

        func shutdown() {
            if let renderer {
                engine_renderer_destroy(renderer)
                self.renderer = nil
            }
            packageImagesEngine = nil
            uploadedMorphPackVersion = -1
            uploadedMorphPackCount = 0
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
            if let renderer, let engine {
                engine.setAvatarPreviewMode(avatarPreviewMode, renderer: renderer)
            }
            lastDrawableSize = size
        }

        private func resizeRenderer(to size: CGSize, view: InteractiveGameView) {
            guard size.width > 0, size.height > 0 else { return }
            attachIfNeeded(to: view, drawableSize: size)
            guard lastDrawableSize != size else { return }
            if let renderer {
                engine_renderer_resize(renderer, Float(size.width), Float(size.height))
                lastDrawableSize = size
            }
        }

        private func syncEngine() {
            guard let renderer, let engine else { return }
            engine.sync(renderer: renderer)
        }

        private func uploadPackageImagesIfNeeded() {
            guard let renderer, let engine else { return }
            let needsImages = packageImagesEngine !== engine
            let engineChanged = packageImagesEngine !== engine
            if engineChanged {
                uploadedMorphPackVersion = -1
                uploadedMorphPackCount = 0
            }
            let needsMorphs = engineChanged || uploadedMorphPackVersion != engine.morphPackVersion
            let uploadedImages = !needsImages || engine.uploadPackageImageAtlas(to: renderer)
            let previousMorphPackCount = uploadedMorphPackCount
            if needsMorphs {
                uploadedMorphPackCount = engine.uploadMorphPacks(
                    to: renderer,
                    startingAt: uploadedMorphPackCount
                )
            }
            let uploadedMorphs = !needsMorphs || uploadedMorphPackCount == engine.morphPackCount
            let registeredNewMorphs = uploadedMorphPackCount > previousMorphPackCount
            if needsImages && !uploadedImages { rustSurfaceLog.error("Package image atlas upload failed") }
            if needsMorphs && !uploadedMorphs { rustSurfaceLog.error("Morph pack upload failed") }
            if registeredNewMorphs && !engine.refreshLocalAppearanceAfterMorphPackUpload() {
                rustSurfaceLog.error("Morph appearance refresh after pack upload failed")
            }
            if uploadedImages && uploadedMorphs {
                packageImagesEngine = engine
                uploadedMorphPackVersion = engine.morphPackVersion
            }
        }
    }
}

final class InteractiveGameView: MTKView {
    var onViewportChange: ((CGSize, CGFloat, UIEdgeInsets) -> Void)?
    var onDrawableSizeChange: ((CGSize) -> Void)?
    var onPointer: ((UInt64, UInt8, CGPoint) -> Bool)?
    var usesSplitPreviewControls = false
    var handlesPinchZoom = true {
        didSet { pinchRecognizer?.isEnabled = handlesPinchZoom }
    }
    var onMoveChanged: ((CGSize) -> Void)?
    var onMoveEnded: (() -> Void)?
    var onLookChanged: ((CGSize) -> Void)?
    var onLookEnded: (() -> Void)?
    var onZoomDelta: ((CGFloat) -> Void)?
    var onZoomEnded: (() -> Void)?
    var onInteractionChanged: ((Bool) -> Void)?
    var onWorldTap: (() -> Void)?

    private var nextPointerID: UInt64 = 1
    private var pointerIDs: [ObjectIdentifier: UInt64] = [:]
    private var uiPointers = Set<UInt64>()
    private var cameraTouches: [UInt64: CGPoint] = [:]
    private var cameraTouchStarts: [UInt64: CGPoint] = [:]
    private var cameraTouchMoved = false
    private var pinchActive = false
    private var previousPinchScale: CGFloat = 1
    private weak var pinchRecognizer: UIPinchGestureRecognizer?

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        installPinchRecognizer()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        installPinchRecognizer()
    }

    private func installPinchRecognizer() {
        let recognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.isEnabled = handlesPinchZoom
        addGestureRecognizer(recognizer)
        pinchRecognizer = recognizer
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchActive = true
            previousPinchScale = recognizer.scale
            onMoveEnded?()
            onInteractionChanged?(true)
        case .changed:
            guard previousPinchScale > 0, recognizer.scale > 0 else { return }
            onZoomDelta?(log(recognizer.scale / previousPinchScale))
            previousPinchScale = recognizer.scale
        case .ended, .cancelled, .failed:
            pinchActive = false
            previousPinchScale = 1
            onZoomEnded?()
            if cameraTouches.isEmpty { onInteractionChanged?(false) }
        default:
            break
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // MTKView normally tracks this automatically, but an iPhone rotation
        // can lay out the view before delivering drawableSizeWillChange.
        let scale = max(contentScaleFactor, 1.0)
        let layoutDrawableSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )
        if layoutDrawableSize.width > 0, layoutDrawableSize.height > 0 {
            if drawableSize != layoutDrawableSize {
                drawableSize = layoutDrawableSize
            }
            onDrawableSizeChange?(layoutDrawableSize)
        }
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
                cameraTouchStarts[pointerID] = point
                if cameraTouches.count >= 2 {
                    // A second camera finger is a gesture, never a world tap.
                    onMoveEnded?()
                    cameraTouchMoved = true
                }
            }
        }
        if !cameraTouches.isEmpty { onInteractionChanged?(true) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let pointerID = pointerID(for: touch)
            let point = touch.location(in: self)
            if uiPointers.contains(pointerID) {
                _ = onPointer?(pointerID, UInt8(CUBACADABRA_UI_POINTER_MOVE), point)
            } else if cameraTouches[pointerID] != nil {
                if cameraTouches.count == 1, let previous = cameraTouches[pointerID] {
                    if usesSplitPreviewControls,
                       let start = cameraTouchStarts[pointerID],
                       start.x < bounds.midX {
                        onMoveChanged?(CGSize(width: point.x - start.x, height: point.y - start.y))
                    } else {
                        onLookChanged?(CGSize(width: point.x - previous.x, height: point.y - previous.y))
                    }
                    cameraTouchMoved = true
                }
                cameraTouches[pointerID] = point
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, phase: UInt8(CUBACADABRA_UI_POINTER_UP))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, phase: UInt8(CUBACADABRA_UI_POINTER_CANCEL))
    }

    private func finish(_ touches: Set<UITouch>, phase: UInt8) {
        let wasCameraInteraction = !cameraTouches.isEmpty
        onMoveEnded?()
        for touch in touches {
            let pointerID = pointerID(for: touch)
            let point = touch.location(in: self)
            if uiPointers.remove(pointerID) != nil {
                _ = onPointer?(pointerID, phase, point)
            } else {
                cameraTouches.removeValue(forKey: pointerID)
                cameraTouchStarts.removeValue(forKey: pointerID)
            }
            pointerIDs.removeValue(forKey: ObjectIdentifier(touch))
        }
        if cameraTouches.isEmpty {
            if !pinchActive { onInteractionChanged?(false) }
            onLookEnded?()
            if phase == UInt8(CUBACADABRA_UI_POINTER_UP)
                && wasCameraInteraction
                && !cameraTouchMoved
                && uiPointers.isEmpty {
                onWorldTap?()
            }
            cameraTouchMoved = false
        } else if cameraTouches.count == 1 {
            // A finger remaining after a pinch begins a fresh move/orbit gesture.
            for (pointerID, point) in cameraTouches {
                cameraTouchStarts[pointerID] = point
            }
        }
    }

    private func pointerID(for touch: UITouch) -> UInt64 {
        let identity = ObjectIdentifier(touch)
        if let pointerID = pointerIDs[identity] { return pointerID }
        let pointerID = nextPointerID
        nextPointerID &+= 1
        pointerIDs[identity] = pointerID
        return pointerID
    }

}
