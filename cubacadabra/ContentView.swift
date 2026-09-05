import Combine
import SwiftUI

@MainActor
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: GameViewModel
    @StateObject private var orientationController: AppOrientationController
    @State private var gamePresented = false
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
        ZStack {
            if model.isLoading {
                LoadingView()
            } else if let message = model.errorMessage {
                ErrorView(message: message, retry: model.retry)
            } else if gamePresented {
                GameSessionView(
                    model: model
                )
            } else {
                HomeView(
                    model: model,
                    safetyCenterPresented: $safetyCenterPresented,
                    enterGame: { gamePresented = true },
                    leaveGame: { model.leaveGame() }
                )
            }
        }
        .task { await model.load() }
        .onReceive(tick) { date in
            if gamePresented {
                model.tick(at: date)
            }
        }
        .onChange(of: model.safetyRequestID) { _ in
            guard gamePresented else { return }
            pausedForSafety = true
            model.pauseGame()
            gamePresented = false
            DispatchQueue.main.async {
                safetyCenterPresented = true
            }
        }
        .onChange(of: gamePresented) { isPresented in
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
}

#Preview {
    ContentView()
}
