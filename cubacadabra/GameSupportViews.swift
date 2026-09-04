import SwiftUI
struct GameControls: View {
    @ObservedObject var model: GameViewModel
    @State private var joystick = CGSize.zero

    var body: some View {
        HStack(alignment: .bottom) {
            ZStack {
                Circle().fill(.black.opacity(0.3)).frame(width: 108, height: 108)
                    .overlay(Circle().stroke(.white.opacity(0.24), lineWidth: 1))
                Circle().fill(.white.opacity(0.84)).frame(width: 48, height: 48)
                    .offset(x: joystick.width, y: joystick.height)
            }
            .frame(width: 120, height: 120)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                joystick = value.translation
                let limit: CGFloat = 38
                model.setMove(
                    strafe: Float(max(-limit, min(limit, value.translation.width)) / limit),
                    forward: Float(-max(-limit, min(limit, value.translation.height)) / limit)
                )
            }.onEnded { _ in
                joystick = .zero
                model.setMove(strafe: 0, forward: 0)
            })
            .accessibilityLabel("Movement joystick")
            Spacer()
            VStack(spacing: 10) {
                Button("JUMP") { model.jump() }.buttonStyle(GameButtonStyle())
                Button(model.sprinting ? "RUNNING" : "RUN") { model.toggleSprinting() }
                    .buttonStyle(GameButtonStyle(active: model.sprinting))
            }
        }
    }
}

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

