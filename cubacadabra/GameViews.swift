import SwiftUI
struct GameSessionView: View {
    let model: GameViewModel
    let openSafety: () -> Void

    var body: some View {
        GameSurface(
            model: model,
            onSafety: openSafety
        )
    }
}

struct GameSurface: View {
    @ObservedObject var model: GameViewModel
    let onSafety: () -> Void

    init(
        model: GameViewModel,
        onSafety: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onSafety = onSafety
    }

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
                    if model.worldID == "lobby" {
                        GameHeader(model: model, onSafety: onSafety)
                            .padding(.horizontal, 20)
                            .padding(.top, 18)
                    }
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
                if model.worldID == "lobby" {
                    GameControls(model: model)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)
                }
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

struct GameHeader: View {
    @ObservedObject var model: GameViewModel
    let onSafety: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.world()?.scene.eyebrow.uppercased() ?? "CUBACADABRA")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.8)
                        .foregroundStyle(.white.opacity(0.64))
                    Text(model.world()?.scene.title ?? "First Game")
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(model.world()?.scene.description ?? "")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        Button(action: onSafety) {
                            Image(systemName: "person.2.badge.gearshape")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.white.opacity(0.14), in: Circle())
                        }
                        .accessibilityLabel("Players and safety")
                    }
                    Text(model.worldID == "lobby" ? "LOBBY" : "SESSION")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(0.64))
                    Text("\((model.frame?.agents.count ?? 0) + 1) PLAYERS")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(connectionColor)
                            .frame(width: 7, height: 7)
                        Text(model.connectionState.label)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(0.9)
                            .foregroundStyle(.white.opacity(0.68))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Cloud connection \(model.connectionState.label.lowercased())")
                }
            }
            if model.worldID == "lobby" {
                HStack(spacing: 8) {
                    ForEach(Array((model.world()?.launchPads ?? []).enumerated()), id: \.element.id) { index, pad in
                        let live = model.frame?.pads[safe: index]
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pad.code)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .tracking(0.8)
                            Text(model.lobbyLaunchStatus(for: pad, live: live))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(pad.enabled ? 0.78 : 0.48))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.white.opacity(pad.enabled ? 0.09 : 0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            if !pad.enabled {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                            }
                        }
                        .opacity(pad.enabled ? 1 : 0.72)
                    }
                }
            }
        }
        .padding(16)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
    }

    private func status(for pad: EnginePad?) -> String {
        guard let pad else { return "WAITING" }
        if pad.phase == 2 { return "LAUNCHING" }
        if pad.seconds > 0 { return String(format: "%.1fs · %d", pad.seconds, pad.occupants) }
        return pad.occupants == 0 ? "WAITING" : "ASSEMBLING"
    }

    private var connectionColor: Color {
        switch model.connectionState {
        case .connected: return Color(red: 0.39, green: 0.68, blue: 0.45)
        case .connecting, .reconnecting: return Color(red: 0.88, green: 0.72, blue: 0.29)
        case .disconnected: return Color(red: 0.76, green: 0.37, blue: 0.34)
        }
    }
}
