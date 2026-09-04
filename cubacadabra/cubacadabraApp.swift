//
//  cubacadabraApp.swift
//  cubacadabra
//
//  Created by aa on 9/1/26.
//

import Combine
import SwiftUI
import UIKit

@main
struct cubacadabraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Coordinates the gameplay orientation preference with the scene geometry.
/// iPadOS can decline a geometry request while the app is windowed, so the
/// renderer and SwiftUI surface still receive every size the scene gives them.
@MainActor
final class AppOrientationController: ObservableObject {
    @Published private(set) var isGameActive = false
    private(set) var shouldLockLandscape = false
    private weak var windowScene: UIWindowScene?

    func connect(to windowScene: UIWindowScene) {
        self.windowScene = windowScene
        if windowScene.traitCollection.userInterfaceIdiom == .pad {
            windowScene.sizeRestrictions?.minimumSize = CGSize(width: 600, height: 400)
        }
        if isGameActive {
            shouldLockLandscape = interfaceOrientationIsLandscape
            updateOrientationPreferences()
            requestLandscape()
        }
    }

    func setGameActive(_ isActive: Bool) {
        isGameActive = isActive
        shouldLockLandscape = isActive && interfaceOrientationIsLandscape
        updateOrientationPreferences()
        if isActive {
            requestLandscape()
        }
    }

    @available(iOS 26.0, *)
    func sceneGeometryDidChange() {
        let shouldLock = isGameActive
            && windowScene?.effectiveGeometry.interfaceOrientation.isLandscape == true
        guard shouldLockLandscape != shouldLock else { return }
        shouldLockLandscape = shouldLock
        updateOrientationPreferences()
    }

    private func requestLandscape() {
        guard let windowScene else { return }
        windowScene.requestGeometryUpdate(
            .iOS(interfaceOrientations: .landscape)
        ) { error in
            #if DEBUG
            print("Couldn't switch Cubacadabra to landscape:", error.localizedDescription)
            #endif
        }
    }

    private func updateOrientationPreferences() {
        guard let rootViewController = windowScene?.windows.first(where: \.isKeyWindow)?.rootViewController else {
            return
        }
        rootViewController.setNeedsUpdateOfSupportedInterfaceOrientations()
        if #available(iOS 26.0, *) {
            rootViewController.setNeedsUpdateOfPrefersInterfaceOrientationLocked()
        }
    }

    private var interfaceOrientationIsLandscape: Bool {
        if #available(iOS 26.0, *) {
            return windowScene?.effectiveGeometry.interfaceOrientation.isLandscape == true
        }
        return windowScene?.interfaceOrientation.isLandscape == true
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = AppSceneDelegate.self
        return configuration
    }
}

final class AppSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var orientationController: AppOrientationController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let orientationController = AppOrientationController()
        self.orientationController = orientationController
        orientationController.connect(to: windowScene)

        let rootViewController = GameHostingController(
            rootView: ContentView(orientationController: orientationController),
            orientationController: orientationController
        )
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = rootViewController
        self.window = window
        window.makeKeyAndVisible()
    }

    @available(iOS 26.0, *)
    func windowScene(
        _ windowScene: UIWindowScene,
        didUpdateEffectiveGeometry previousGeometry: UIWindowScene.Geometry
    ) {
        orientationController?.sceneGeometryDidChange()
    }
}

final class GameHostingController: UIHostingController<ContentView> {
    private let orientationController: AppOrientationController

    init(rootView: ContentView, orientationController: AppOrientationController) {
        self.orientationController = orientationController
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GameHostingController must be created in the scene delegate")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let windowScene = view.window?.windowScene {
            orientationController.connect(to: windowScene)
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if #available(iOS 26.0, *) {
            return .all
        }
        return orientationController.isGameActive ? .landscape : .all
    }

    @available(iOS 26.0, *)
    override var prefersInterfaceOrientationLocked: Bool {
        orientationController.shouldLockLandscape
    }
}
