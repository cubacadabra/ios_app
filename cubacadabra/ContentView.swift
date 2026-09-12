import Combine
import SwiftUI

@MainActor
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appModel = AppViewModel()
    @StateObject private var model: GameViewModel
    @StateObject private var orientationController: AppOrientationController
    @State private var gamePresented = false
    @State private var didAutoEnterGuestGame = false
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
        NavigationStack {
            rootView
            .navigationDestination(isPresented: $gamePresented) {
                GameSessionView(model: model)
            }
        }
        .task {
            model.onAccountRequested = {
                appModel.clearAuthenticationNotice()
                gamePresented = false
            }
            model.onSessionRejected = { appModel.gameSessionRejected($0) }
            await appModel.start()
            if appModel.isAuthenticated { appModel.loadBlockedUsers() }
            model.applyAccountSession(appModel.gameSession)
            if !appModel.isAuthenticated {
                await model.load()
                autoEnterGuestGameIfReady()
            }
        }
        .onReceive(appModel.$gameSession) { session in
            model.applyAccountSession(session)
        }
        .onChange(of: appModel.authUser?.id) { accountID in
            gamePresented = false
            if accountID != nil { appModel.loadBlockedUsers() }
        }
        .onChange(of: appModel.logoutRequestID) { _ in
            gamePresented = false
            Task { await openGuestGame() }
        }
        .onReceive(tick) { date in
            if gamePresented { model.tick(at: date) }
        }
        .onChange(of: model.safetyRequestID) { _ in
            guard gamePresented else { return }
            model.pauseGame()
            gamePresented = false
            DispatchQueue.main.async { safetyCenterPresented = true }
        }
        .onChange(of: model.gameExitRequestID) { _ in
            guard gamePresented else { return }
            gamePresented = false
        }
        .onChange(of: gamePresented) { isPresented in
            orientationController.setGameActive(isPresented)
            if isPresented {
                model.enterGame()
            } else {
                model.exitToHome()
            }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            appModel.refreshAuthentication()
        }
        .onDisappear { model.disconnect() }
        .sheet(isPresented: $safetyCenterPresented) {
            SafetyCenterView(appModel: appModel, gameModel: model)
        }
    }

    private func openGuestGame() async {
        let sessionID = appModel.gameSession.sessionID
        do {
            try await model.selectGame(GameCatalogEntry.available[0])
            guard sessionID == appModel.gameSession.sessionID, !appModel.isAuthenticated else { return }
            gamePresented = true
        } catch is CancellationError {
            return
        } catch {
            guard sessionID == appModel.gameSession.sessionID else { return }
            model.errorMessage = error.localizedDescription
            model.isLoading = false
        }
    }

    private func autoEnterGuestGameIfReady() {
        guard !appModel.isRestoring, !appModel.isAuthenticated, !appModel.isSigningIn,
              !didAutoEnterGuestGame,
              !model.isLoading,
              model.errorMessage == nil,
              model.engine != nil,
              !gamePresented else { return }
        didAutoEnterGuestGame = true
        gamePresented = true
    }

    @ViewBuilder
    private var rootView: some View {
        if appModel.isRestoring {
            LoadingView()
        } else if !appModel.isAuthenticated {
            SignInChoiceView(model: appModel, onInteraction: { didAutoEnterGuestGame = true })
                .safeAreaInset(edge: .bottom) {
                    if model.errorMessage != nil {
                        VStack(spacing: 8) {
                            Text("The game couldn’t load. You can still sign in.")
                                .font(.footnote)
                            Button("Retry game") {
                                Task { await openGuestGame() }
                            }
                            .disabled(model.isSelectingGame)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                    }
                }
        } else if appModel.needsBirthday {
            BirthdayGateView(model: appModel)
        } else if appModel.isUnderThirteen {
            ParentEmailGateView(model: appModel)
        } else {
            MainMenuView(model: appModel, gameModel: model, safetyDestination: SafetyCenterView(appModel: appModel, gameModel: model)) { game in
                let sessionID = appModel.gameSession.sessionID
                try await model.selectGame(game)
                guard sessionID == appModel.gameSession.sessionID else { return }
                gamePresented = true
            }
        }
    }
}

#Preview {
    ContentView()
}
