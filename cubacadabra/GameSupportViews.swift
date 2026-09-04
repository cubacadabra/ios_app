import SwiftUI
struct GameButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .tracking(1.1)
            .foregroundStyle(.white)
            .frame(minWidth: 86, minHeight: 44)
            .background(.white.opacity(active ? 0.42 : 0.2), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct LoadingView: View {
    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.18, blue: 0.21).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(.white)
                Text("LOADING FIRST GAME")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.76))
            }
        }
    }
}

struct ErrorView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.18, blue: 0.21).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("GAME UNAVAILABLE")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.62))
                Text("Couldn’t load the first game.")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                Button("TRY AGAIN", action: retry).buttonStyle(GameButtonStyle())
            }
            .frame(maxWidth: 360, alignment: .leading)
            .padding(28)
        }
    }
}
