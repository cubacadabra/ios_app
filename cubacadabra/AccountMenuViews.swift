import SwiftUI

struct MainMenuView: View {
    @ObservedObject var model: GameViewModel
    let openGame: (GameCatalogEntry) async throws -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var gameError: String?
    @State private var showingLogoutConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    BrandMark()
                    Spacer()
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Your cubes")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(colorScheme == .dark ? .primary : cubacadabraInk)
                    Text("Choose a game to enter its lobby.")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 58)

                menuSectionTitle("CUBES")
                    .padding(.top, 38)

                VStack(spacing: 0) {
                    ForEach(GameCatalogEntry.available) { game in
                        cubeRow(game)
                        if game.id != GameCatalogEntry.available.last?.id { Divider().padding(.leading, 60) }
                    }
                    Divider().padding(.leading, 60)
                    NavigationLink {
                        MoreCubesView(model: model, openGame: openGame)
                    } label: {
                        menuRow(icon: "ellipsis.circle", title: "More", detail: "Browse uploaded cubes")
                    }
                }
                .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                if let gameError {
                    Label(gameError, systemImage: "exclamationmark.circle")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.red)
                        .padding(.top, 12)
                }

                menuSectionTitle("ACCOUNT")
                    .padding(.top, 36)

                VStack(spacing: 0) {
                    NavigationLink {
                        AccountUsernameEditorView(model: model)
                    } label: {
                        menuRow(icon: "person.crop.circle", title: "Change your username", detail: model.username.isEmpty ? "Player" : model.username)
                    }
                    Divider().padding(.leading, 60)
                    NavigationLink {
                        MorphSelectionView(model: model)
                    } label: {
                        menuRow(icon: "person.3", title: "Choose your morph", detail: MorphOption.option(for: model.authUser?.bodyID).label)
                    }
                    Divider().padding(.leading, 60)
                    NavigationLink {
                        SafetyCenterView(model: model)
                    } label: {
                        menuRow(icon: "checkmark.shield", title: "Block or unblock players", detail: "Players & safety")
                    }
                }
                .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                menuSectionTitle("ABOUT")
                    .padding(.top, 36)

                VStack(spacing: 0) {
                    Link(destination: AppLinks.privacy) { menuRow(icon: "lock.shield", title: "Privacy policy") }
                    Divider().padding(.leading, 60)
                    Link(destination: AppLinks.terms) { menuRow(icon: "doc.text", title: "Terms of use") }
                    Divider().padding(.leading, 60)
                    Link(destination: AppLinks.support) { menuRow(icon: "envelope", title: "Contact support") }
                }
                .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Button(role: .destructive) {
                    showingLogoutConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("Log out")
                        Spacer()
                    }
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .frame(minHeight: 52)
                }
                .buttonStyle(.plain)
                .padding(.top, 22)
                .confirmationDialog("Log out of cubacadabra?", isPresented: $showingLogoutConfirmation, titleVisibility: .visible) {
                    Button("Log out", role: .destructive) { model.logOut() }
                    Button("Cancel", role: .cancel) {}
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 36)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
    }

    private func cubeRow(_ game: GameCatalogEntry) -> some View {
        Button {
            guard !model.isSelectingGame else { return }
            gameError = nil
            Task {
                do { try await openGame(game) }
                catch { gameError = gameSelectionErrorMessage(for: error) }
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: game.id == "second-game" ? "dot.radiowaves.left.and.right" : "cube.transparent")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(cubacadabraCoral)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.title)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(game.subtitle)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isSelectingGame { ProgressView() }
                else { Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .frame(minHeight: 76)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the \(game.title) lobby")
    }

    private func menuRow(icon: String, title: String, detail: String? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(cubacadabraCoral)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.primary)
                if let detail { Text(detail).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.secondary) }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 16)
        .frame(minHeight: 60)
    }

    private func menuSectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .bold, design: .rounded)).tracking(1.5).foregroundStyle(.secondary)
    }

    private func gameSelectionErrorMessage(for error: Error) -> String {
        if let packageError = error as? GamePackageError, case .httpFailure = packageError {
            return "That cube is unavailable right now. Check your connection and try again."
        }
        return "We couldn’t open that cube. Please try again."
    }
}

struct AccountUsernameEditorView: View {
    @ObservedObject var model: GameViewModel
    @FocusState private var usernameFocused: Bool
    private var profile: AppRuntimeProfileSnapshot { model.profileUsername }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Choose a name other players can find you by.")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 9) {
                    Text("USERNAME").font(.system(size: 12, weight: .bold, design: .rounded)).tracking(1.4).foregroundStyle(.secondary)
                    TextField("Your username", text: usernameBinding)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($usernameFocused)
                        .font(.system(size: 17, weight: .regular, design: .rounded))
                        .padding(.horizontal, 15)
                        .frame(minHeight: 52)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                Text("Use 2–24 letters, numbers, _ or -.").font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                if let feedback = profile.usernameFeedback {
                    Label(feedback.message, systemImage: feedback.kind == .error ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(feedback.kind == .error ? .red : .green)
                }
                Button { model.saveProfileUsername() } label: {
                    HStack {
                        if profile.usernameIsSaving { ProgressView().tint(.white) }
                        Text(profile.usernameIsSaving ? "SAVING…" : "SAVE USERNAME")
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 56)
                    .background(cubacadabraCoral, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!profile.usernameCanSave)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 24)
        }
        .navigationTitle("Username")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear { model.beginProfileUsernameEdit() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { usernameFocused = false }
            }
        }
    }

    private var usernameBinding: Binding<String> {
        Binding(
            get: { profile.usernameDraft },
            set: { model.changeProfileUsername($0) }
        )
    }

}
