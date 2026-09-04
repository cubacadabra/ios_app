import Combine
import SwiftUI

struct ContentView: View {
    @StateObject private var model = GameViewModel()
    @State private var gamePresented = false
    @State private var safetyCenterPresented = false
    @State private var pausedForSafety = false
    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

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
        .onDisappear { model.disconnect() }
    }
}

#Preview {
    ContentView()
}
