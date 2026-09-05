import SwiftUI
struct HomeView: View {
    @ObservedObject var model: GameViewModel
    @Binding var safetyCenterPresented: Bool
    let openMyCube: () -> Void
    let enterGame: () -> Void
    let leaveGame: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var appeared = false

    private let coral = Color(red: 0.91, green: 0.39, blue: 0.29)
    private let ink = Color(red: 0.15, green: 0.29, blue: 0.29)

    private var isWideLayout: Bool {
        horizontalSizeClass == .regular
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(.systemBackground)
                .ignoresSafeArea()
            Circle()
                .fill(coral.opacity(colorScheme == .dark ? 0.13 : 0.09))
                .frame(width: 300, height: 300)
                .blur(radius: 2)
                .offset(x: 190, y: -145)
                .allowsHitTesting(false)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center) {
                        Text("CUBACADABRA")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .tracking(2.1)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 16)
                        Button(action: openMyCube) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(.secondary.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("My Cube")
                        Button {
                            safetyCenterPresented = true
                        } label: {
                            Image(systemName: "person.2.badge.gearshape")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(.secondary.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Players and safety")
                    }

                    if isWideLayout {
                        HStack(alignment: .top, spacing: 40) {
                            heroSection
                                .frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 0) {
                                factsSection
                                Divider()
                                    .padding(.vertical, 28)
                                identitySection
                                safetyLink
                            }
                            .frame(width: 240, alignment: .leading)
                        }
                        .padding(.top, 88)
                    } else {
                        heroSection
                            .padding(.top, 58)
                        factsSection
                            .padding(.top, 42)
                        Divider()
                            .padding(.vertical, 28)
                        identitySection
                        safetyLink
                    }
                }
                .frame(maxWidth: isWideLayout ? 900 : 520, alignment: .leading)
                .padding(.horizontal, isWideLayout ? 54 : 24)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
        }
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 10)
        .onAppear {
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.35)) {
                    appeared = true
                }
            }
        }
        .sheet(isPresented: $safetyCenterPresented) {
            SafetyCenterView(model: model)
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.package?.scene.eyebrow.uppercased() ?? "A SMALL WORLD")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.8)
                .foregroundStyle(.secondary)
            Text("First Game")
                .font(.system(size: isWideLayout ? 50 : 44, weight: .bold, design: .rounded))
                .foregroundStyle(colorScheme == .dark ? Color.primary : ink)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
            Text(model.hasEnteredGame
                ? "Return to the place you left off and keep exploring."
                : "Start in the lobby, find a gate, and see who else is exploring.")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: enterGame) {
                HStack(spacing: 12) {
                    Text(model.hasEnteredGame ? "RESUME GAME" : "ENTER THE LOBBY")
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 15, weight: .bold))
                }
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(minHeight: 56)
                .background(coral, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(HomePrimaryButtonStyle())
            .accessibilityHint(
                model.hasEnteredGame
                    ? "Returns to your paused game"
                    : "Opens the interactive game lobby"
            )

            if model.hasEnteredGame {
                Button(role: .destructive, action: leaveGame) {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 14, weight: .bold))
                        Text("LEAVE GAME")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .tracking(1.1)
                        Spacer()
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 52)
                    .background(
                        Color.red.opacity(colorScheme == .dark ? 0.18 : 0.10),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.red.opacity(0.28), lineWidth: 1)
                    }
                }
                .buttonStyle(HomePrimaryButtonStyle())
                .accessibilityHint("Leaves your paused game and removes the resume option")
                .padding(.top, 2)
            }
        }
    }

    private var factsSection: some View {
        HStack(spacing: 18) {
            HomeFact(
                label: "STATUS",
                value: model.hasEnteredGame ? "PAUSED" : "READY TO ENTER"
            )
            Rectangle()
                .fill(.primary.opacity(0.14))
                .frame(width: 1, height: 34)
            HomeFact(
                label: "LOBBY SIZE",
                value: "UP TO \(model.package?.scene.maxPlayers ?? 18)"
            )
        }
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR IDENTITY")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(.secondary)
            Text(model.username.isEmpty ? "Player" : model.username)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("Change this in the settings room")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var safetyLink: some View {
        Button {
            safetyCenterPresented = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 17, weight: .semibold))
                Text("PLAYERS & SAFETY")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(1.1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .frame(minHeight: 52)
        }
        .buttonStyle(.plain)
        .padding(.top, 18)
    }
}

private struct HomeFact: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.3)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HomePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
