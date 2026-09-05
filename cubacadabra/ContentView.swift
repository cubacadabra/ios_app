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
    @State private var didAutoEnterGame = false
    @State private var safetyCenterPresented = false
    @State private var pausedForSafety = false
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
            ZStack {
                if model.isLoading {
                    LoadingView()
                } else if let message = model.errorMessage {
                    ErrorView(message: message, retry: model.retry)
                } else {
                    HomeView(
                        model: model,
                        safetyCenterPresented: $safetyCenterPresented,
                        enterGame: enterGame,
                        leaveGame: { model.leaveGame() }
                    )
                }
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .game:
                    GameSessionView(model: model)
                }
            }
        }
        .task {
            await model.load()
            autoEnterGameIfReady()
        }
        .onReceive(tick) { date in
            if gameIsPresented {
                model.tick(at: date)
            }
        }
        .onChange(of: model.safetyRequestID) { _ in
            guard gameIsPresented else { return }
            pausedForSafety = true
            model.pauseGame()
            path.removeAll()
            DispatchQueue.main.async {
                safetyCenterPresented = true
            }
        }
        .onChange(of: model.gameExitRequestID) { _ in
            guard gameIsPresented else { return }
            path.removeAll()
        }
        .onChange(of: model.isLoading) { _ in
            autoEnterGameIfReady()
        }
        .onChange(of: path) { newPath in
            let isPresented = newPath.contains(.game)
            orientationController.setGameActive(isPresented)
            if isPresented {
                pausedForSafety = false
                model.enterGame()
            } else if !pausedForSafety {
                safetyCenterPresented = false
                model.exitToHome()
            } else {
                pausedForSafety = false
            }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            model.refreshAuthentication()
        }
        .onDisappear { model.disconnect() }
    }

    private var gameIsPresented: Bool {
        path.contains(.game)
    }

    private func enterGame() {
        guard !gameIsPresented else { return }
        path.append(.game)
    }

    private func autoEnterGameIfReady() {
        guard !didAutoEnterGame,
              !model.isLoading,
              model.errorMessage == nil else { return }
        didAutoEnterGame = true
        enterGame()
    }
}

#Preview {
    ContentView()
}
