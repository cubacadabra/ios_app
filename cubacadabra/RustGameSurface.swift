import MetalKit
import OSLog
import SwiftUI
import UIKit

private let rustSurfaceLog = Logger(subsystem: "com.cubacadabra.app", category: "rust-surface")

struct RustGameSurface: UIViewRepresentable {
    let engine: EngineBridge
    let isActive: Bool
    var avatarPreviewMode: Bool = false
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
            #if DEBUG
            NSLog("[MorphGesture] coordinator configured mode=\(surface.avatarPreviewMode ? "preview" : "game") multipleTouch=\(view.isMultipleTouchEnabled) userInteraction=\(view.isUserInteractionEnabled)")
            #endif
            view.onMoveChanged = surface.onMoveChanged
            view.onMoveEnded = surface.onMoveEnded
            view.onLookChanged = surface.onLookChanged
            view.onLookEnded = surface.onLookEnded
            view.onZoomDelta = { delta in
                #if DEBUG
                NSLog("[MorphGesture] zoom callback reached RustGameSurface delta=\(delta)")
                #endif
                surface.onZoomDelta(delta)
            }
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
    // Latch on the second touch, before UIKit crosses its pinch threshold.
    // A finger left down after pinching must not become an orbit gesture.
    private var suppressSingleFingerInput = false
    private var previousPinchScale: CGFloat = 1
    // In the compact SwiftUI preview, Simulator can route the second pinch
    // contact to the HostingView outside the 220pt canvas. Track that pair
    // from UIEvent.allTouches as a preview-only fallback.
    private var externalPinchActive = false
    private var previousExternalPinchDistance: CGFloat = 0

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
        // Keep touch lifetime accounting intact while the recognizer zooms.
        // Raw touch handlers suppress movement/orbit for the entire pinch.
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        addGestureRecognizer(recognizer)
        #if DEBUG
        NSLog("[MorphGesture] installed pinch recognizer")
        #endif
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        #if DEBUG
        let stateName: String
        switch recognizer.state {
        case .possible: stateName = "possible"
        case .began: stateName = "began"
        case .changed: stateName = "changed"
        case .ended: stateName = "ended"
        case .cancelled: stateName = "cancelled"
        case .failed: stateName = "failed"
        @unknown default: stateName = "unknown"
        }
        NSLog("[MorphGesture] pinch state=\(stateName) scale=\(recognizer.scale) touches=\(cameraTouches.count) suppress=\(suppressSingleFingerInput) active=\(pinchActive)")
        #endif
        switch recognizer.state {
        case .began:
            pinchActive = true
            suppressSingleFingerInput = true
            cameraTouchMoved = true
            previousPinchScale = 1
            onMoveEnded?()
            onLookEnded?()
            onInteractionChanged?(true)
            applyPinchScale(recognizer.scale)
        case .changed:
            applyPinchScale(recognizer.scale)
        case .ended, .cancelled, .failed:
            if recognizer.state == .ended { applyPinchScale(recognizer.scale) }
            pinchActive = false
            previousPinchScale = 1
            onZoomEnded?()
            if cameraTouches.isEmpty {
                suppressSingleFingerInput = false
                onInteractionChanged?(false)
            }
        default:
            break
        }
    }

    private func applyPinchScale(_ scale: CGFloat) {
        guard scale.isFinite, scale > 0 else { return }
        let delta = log(scale / previousPinchScale)
        #if DEBUG
        NSLog("[MorphGesture] pinch zoom delta=\(delta) scale=\(scale) previous=\(previousPinchScale)")
        #endif
        onZoomDelta?(delta)
        previousPinchScale = scale
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
                    suppressSingleFingerInput = true
                    onMoveEnded?()
                    onLookEnded?()
                    cameraTouchMoved = true
                    #if DEBUG
                    NSLog("[MorphGesture] second camera touch latched; suppressing single-finger input cameraTouches=\(cameraTouches.count)")
                    #endif
                }
            }
        }
        #if DEBUG
        NSLog("[MorphGesture] touches began count=\(touches.count) eventAll=\(event?.allTouches?.count ?? -1) camera=\(cameraTouches.count) ui=\(uiPointers.count) suppress=\(suppressSingleFingerInput)")
        if let allTouches = event?.allTouches {
            let details = allTouches.map { touch in
                let viewName = touch.view.map { String(describing: type(of: $0)) } ?? "nil"
                let point = touch.location(in: self)
                return "\(viewName)@(\(point.x),\(point.y))"
            }.joined(separator: ",")
            NSLog("[MorphGesture] event touch views=\(details)")
        }
        #endif
        updateExternalPreviewPinch(with: event)
        if !cameraTouches.isEmpty { onInteractionChanged?(true) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let wasExternalPinchActive = externalPinchActive
        updateExternalPreviewPinch(with: event)
        let externalPinchEnded = wasExternalPinchActive && !externalPinchActive
        for touch in touches {
            let pointerID = pointerID(for: touch)
            let point = touch.location(in: self)
            if uiPointers.contains(pointerID) {
                _ = onPointer?(pointerID, UInt8(CUBACADABRA_UI_POINTER_MOVE), point)
            } else if cameraTouches[pointerID] != nil {
                if !externalPinchEnded,
                   !suppressSingleFingerInput, !pinchActive,
                   cameraTouches.count == 1, let previous = cameraTouches[pointerID] {
                    if usesSplitPreviewControls,
                       let start = cameraTouchStarts[pointerID],
                       start.x < bounds.midX {
                        #if DEBUG
                        NSLog("[MorphGesture] raw single-finger MOVE translation=(\(point.x - start.x),\(point.y - start.y))")
                        #endif
                        onMoveChanged?(CGSize(width: point.x - start.x, height: point.y - start.y))
                    } else {
                        #if DEBUG
                        NSLog("[MorphGesture] raw single-finger LOOK translation=(\(point.x - previous.x),\(point.y - previous.y))")
                        #endif
                        onLookChanged?(CGSize(width: point.x - previous.x, height: point.y - previous.y))
                    }
                    cameraTouchMoved = true
                } else if cameraTouches.count >= 1 {
                    #if DEBUG
                    NSLog("[MorphGesture] raw move suppressed cameraTouches=\(cameraTouches.count) pinchActive=\(pinchActive) suppress=\(suppressSingleFingerInput)")
                    #endif
                }
                cameraTouches[pointerID] = point
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, phase: UInt8(CUBACADABRA_UI_POINTER_UP), event: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, phase: UInt8(CUBACADABRA_UI_POINTER_CANCEL), event: event)
    }

    private func finish(_ touches: Set<UITouch>, phase: UInt8, event: UIEvent?) {
        let wasCameraInteraction = !cameraTouches.isEmpty
        #if DEBUG
        NSLog("[MorphGesture] touches finish phase=\(phase) ending=\(touches.count) cameraBefore=\(cameraTouches.count) pinchActive=\(pinchActive) suppress=\(suppressSingleFingerInput)")
        #endif
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
        if externalPinchActive {
            let activeTouchCount = event?.allTouches?.filter { touch in
                touch.phase == .began || touch.phase == .moved || touch.phase == .stationary
            }.count ?? cameraTouches.count
            if activeTouchCount < 2 || cameraTouches.isEmpty {
                endExternalPreviewPinch()
            }
        }
        if cameraTouches.isEmpty {
            if !pinchActive {
                suppressSingleFingerInput = false
                onInteractionChanged?(false)
            }
            onLookEnded?()
            if phase == UInt8(CUBACADABRA_UI_POINTER_UP)
                && wasCameraInteraction
                && !cameraTouchMoved
                && uiPointers.isEmpty {
                onWorldTap?()
            }
            cameraTouchMoved = false
        }
        #if DEBUG
        NSLog("[MorphGesture] touches finished cameraAfter=\(cameraTouches.count) ui=\(uiPointers.count) pinchActive=\(pinchActive) suppress=\(suppressSingleFingerInput)")
        #endif
    }

    private func updateExternalPreviewPinch(with event: UIEvent?) {
        guard usesSplitPreviewControls, let allTouches = event?.allTouches else { return }
        let activeTouches = allTouches.filter { touch in
            touch.phase == .began || touch.phase == .moved || touch.phase == .stationary
        }
        // UIKit's normal pinch recognizer handles two touches owned by this
        // view. This fallback is only for the split pair where one touch is
        // routed to a sibling/ancestor HostingView.
        guard activeTouches.count >= 2, cameraTouches.count < activeTouches.count else {
            if externalPinchActive { endExternalPreviewPinch() }
            return
        }
        let points = activeTouches.map { $0.location(in: self) }
        guard let first = points.first, let second = points.dropFirst().first else { return }
        let distance = hypot(first.x - second.x, first.y - second.y)
        guard distance.isFinite, distance > 0 else { return }

        if !externalPinchActive {
            externalPinchActive = true
            suppressSingleFingerInput = true
            cameraTouchMoved = true
            previousExternalPinchDistance = distance
            onMoveEnded?()
            onLookEnded?()
            onInteractionChanged?(true)
            #if DEBUG
            NSLog("[MorphGesture] external preview pinch began distance=\(distance) activeTouches=\(activeTouches.count)")
            #endif
            return
        }

        let delta = log(distance / previousExternalPinchDistance)
        guard delta.isFinite else { return }
        previousExternalPinchDistance = distance
        onZoomDelta?(delta)
        #if DEBUG
        NSLog("[MorphGesture] external preview pinch changed distance=\(distance) delta=\(delta)")
        #endif
    }

    private func endExternalPreviewPinch() {
        guard externalPinchActive else { return }
        externalPinchActive = false
        previousExternalPinchDistance = 0
        suppressSingleFingerInput = false
        onZoomEnded?()
        if cameraTouches.isEmpty {
            onInteractionChanged?(false)
        } else {
            // Rebase the remaining finger so it cannot turn the camera when
            // the second contact leaves the preview.
            for (pointerID, point) in cameraTouches {
                cameraTouchStarts[pointerID] = point
            }
        }
        #if DEBUG
        NSLog("[MorphGesture] external preview pinch ended remainingCameraTouches=\(cameraTouches.count)")
        #endif
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
