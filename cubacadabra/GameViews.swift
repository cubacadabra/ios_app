import SwiftUI
struct GameSessionView: View {
    let model: GameViewModel

    var body: some View {
        GameSurface(model: model)
    }
}

struct GameSurface: View {
    @ObservedObject var model: GameViewModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let engine = model.renderEngine {
                RustGameSurface(
                    engine: engine,
                    isActive: true,
                    onLookChanged: { model.lookChanged(to: $0) },
                    onLookEnded: { model.lookEnded() },
                    onZoomDelta: { model.zoomChangedBy(delta: $0) },
                    onZoomEnded: { model.zoomEnded() },
                    onWorldTap: { model.requestUsernameEdit() }
                )
                .ignoresSafeArea()
            }
            if model.worldID != "settings" {
                GameAtmosphere(isSession: model.worldID != "lobby")
            }
            VStack(alignment: .leading, spacing: 0) {
                if model.worldID != "settings" {
                    if let notice = model.presenceNotice {
                        PresenceNoticeView(notice: notice)
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let notice = model.moderationNotice {
                        ModerationNoticeView(notice: notice) {
                            model.dismissModerationNotice()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                Spacer()
            }
            .ignoresSafeArea(edges: .bottom)
            .animation(.easeOut(duration: 0.22), value: model.presenceNotice)
            if model.usernameEditorOpen {
                UsernameEditorView(model: model)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .background(Color.black)
    }
}

private struct UsernameEditorView: View {
    @ObservedObject var model: GameViewModel
    @State private var draftUsername = ""
    @FocusState private var usernameFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 15) {
                Text("PLAYER IDENTITY")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                Text("Edit username")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                TextField("Player name", text: $draftUsername)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($usernameFocused)
                    .onSubmit { model.saveUsername(draftUsername) }
                Text(model.usernameStatus)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("CANCEL") { model.cancelUsernameEdit() }
                    Spacer()
                    Button("SAVE NAME") { model.saveUsername(draftUsername) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(22)
            .frame(maxWidth: 430)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.primary.opacity(0.12), lineWidth: 1))
            .shadow(radius: 24)
            .padding(18)
        }
        .onAppear {
            draftUsername = model.username
            usernameFocused = true
        }
    }
}

private struct GameAtmosphere: View {
    let isSession: Bool

    private var topTint: Color {
        isSession
            ? Color(red: 8 / 255, green: 24 / 255, blue: 36 / 255)
            : Color(red: 15 / 255, green: 53 / 255, blue: 63 / 255)
    }

    private var bottomTint: Color {
        isSession
            ? Color(red: 5 / 255, green: 24 / 255, blue: 29 / 255)
            : Color(red: 14 / 255, green: 39 / 255, blue: 40 / 255)
    }

    private var vignetteTint: Color {
        isSession
            ? Color(red: 8 / 255, green: 27 / 255, blue: 35 / 255)
            : Color(red: 32 / 255, green: 57 / 255, blue: 55 / 255)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        topTint.opacity(isSession ? 0.32 : 0.18),
                        .clear,
                    ],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: isSession ? 0.24 : 0.20)
                )
                LinearGradient(
                    colors: [
                        bottomTint.opacity(isSession ? 0.30 : 0.22),
                        .clear,
                    ],
                    startPoint: .bottom,
                    endPoint: UnitPoint(x: 0.5, y: isSession ? 0.34 : 0.30)
                )
                RadialGradient(
                    stops: [
                        .init(color: .clear, location: 0.23),
                        .init(
                            color: vignetteTint.opacity(isSession ? 0.18 : 0.10),
                            location: 1
                        ),
                    ],
                    center: UnitPoint(x: 0.53, y: 0.39),
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.72
                )
            }
            .compositingGroup()
            .blendMode(.multiply)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
