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
/// iPadOS can ignore the lock while the app is windowed, so the renderer and
/// SwiftUI surface still receive every size the scene gives them.
@MainActor
final class AppOrientationController: ObservableObject {
    @Published private(set) var isGameActive = false
    private weak var windowScene: UIWindowScene?

    func connect(to windowScene: UIWindowScene) {
        self.windowScene = windowScene
        if windowScene.traitCollection.userInterfaceIdiom == .pad {
            windowScene.sizeRestrictions?.minimumSize = CGSize(width: 600, height: 400)
        }
        if isGameActive {
            requestLandscape()
        }
    }

    func setGameActive(_ isActive: Bool) {
        isGameActive = isActive
        if isActive {
            requestLandscape()
        }
        updateOrientationLockPreference()
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

    private func updateOrientationLockPreference() {
        guard #available(iOS 26.0, *) else { return }
        windowScene?.windows.first(where: \.isKeyWindow)?
            .rootViewController?
            .setNeedsUpdateOfPrefersInterfaceOrientationLocked()
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

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let orientationController = AppOrientationController()
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

    @available(iOS 26.0, *)
    override var prefersInterfaceOrientationLocked: Bool {
        orientationController.isGameActive
    }
}
