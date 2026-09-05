import Combine
import SwiftUI

private enum AppRoute: Hashable {
    case game
}

@MainActor
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: GameViewModel
    @StateObject private var orientationController: AppOrientationController
    @State private var path: [AppRoute] = []
    @State private var safetyCenterPresented = false
    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    @MainActor
    init() {
        _model = StateObject(wrappedValue: GameViewModel())
        _orientationController = StateObject(wrappedValue: AppOrientationController())
    }

    @MainActor
    init(orientationController: AppOrientationController) {
        _model = StateObject(wrappedValue: GameViewModel())
        _orientationController = StateObject(wrappedValue: orientationController)
    }

    var body: some View {
        NavigationStack(path: $path) {
            rootView
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .game:
                    GameSessionView(model: model)
                }
            }
        }
        .task {
            await model.load()
        }
        .onReceive(tick) { date in
            if path.contains(.game) { model.tick(at: date) }
        }
        .onChange(of: model.safetyRequestID) { _ in
            guard path.contains(.game) else { return }
            model.pauseGame()
            path.removeAll()
            DispatchQueue.main.async { safetyCenterPresented = true }
        }
        .onChange(of: model.gameExitRequestID) { _ in
            guard path.contains(.game) else { return }
            path.removeAll()
        }
        .onChange(of: path) { newPath in
            let isPresented = newPath.contains(.game)
            orientationController.setGameActive(isPresented)
            if isPresented {
                model.enterGame()
            } else {
                model.exitToHome()
            }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            model.refreshAuthentication()
        }
        .onChange(of: model.isAuthenticated) { isAuthenticated in
            if !isAuthenticated {
                path.removeAll()
            }
        }
        .onDisappear { model.disconnect() }
        .sheet(isPresented: $safetyCenterPresented) {
            SafetyCenterView(model: model)
        }
    }

    @ViewBuilder
    private var rootView: some View {
        if model.isLoading {
            LoadingView()
        } else if let message = model.errorMessage {
            ErrorView(message: message, retry: model.retry)
        } else if !model.isAuthenticated {
            SignInView(model: model)
        } else if model.needsBirthday {
            BirthdayGateView(model: model)
        } else if model.isUnderThirteen {
            ParentEmailGateView(model: model)
        } else {
            MainMenuView(model: model) { game in
                try await model.selectGame(game)
                path.append(.game)
            }
        }
    }
}

#Preview {
    ContentView()
}
