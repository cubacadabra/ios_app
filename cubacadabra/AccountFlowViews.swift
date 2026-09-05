import SwiftUI

private let cubacadabraCoral = Color(red: 0.91, green: 0.39, blue: 0.29)
private let cubacadabraInk = Color(red: 0.15, green: 0.29, blue: 0.29)

struct SignInView: View {
    @ObservedObject var model: GameViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AccountSurface {
            VStack(alignment: .leading, spacing: 24) {
                BrandMark()
                    .padding(.bottom, 34)

                Text("Welcome to cubacadabra")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(colorScheme == .dark ? .primary : cubacadabraInk)

                Text("Sign in to create your player profile and explore the cubes.")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    model.signIn()
                } label: {
                    HStack(spacing: 12) {
                        if model.isSigningIn {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "person.crop.circle.badge.plus")
                        }
                        Text(model.isSigningIn ? "SIGNING IN…" : "SIGN IN")
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 58)
                    .background(cubacadabraCoral, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(model.isSigningIn)

                if let authenticationNotice = model.authenticationNotice {
                    Label(authenticationNotice, systemImage: "exclamationmark.circle")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

struct BirthdayGateView: View {
    @ObservedObject var model: GameViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var birthday = BirthdayGateView.defaultBirthday
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        AccountSurface {
            VStack(alignment: .leading, spacing: 22) {
                BrandMark()
                    .padding(.bottom, 28)

                Text("Before you explore")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(colorScheme == .dark ? .primary : cubacadabraInk)

                Text("Tell us your birthday so we can give you the right experience and protections.")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    Text("DATE OF BIRTH")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)

                    DatePicker(
                        "Date of birth",
                        selection: $birthday,
                        in: Self.earliestBirthday...Date(),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .frame(height: 152)
                    .clipped()
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                Text("Your birthday is used for safety and cannot be changed later.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.red)
                }

                Button {
                    saveBirthday()
                } label: {
                    HStack(spacing: 10) {
                        if isSaving { ProgressView().tint(.white) }
                        Text(isSaving ? "SAVING…" : "CONTINUE")
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 58)
                    .background(cubacadabraCoral, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
        }
    }

    private func saveBirthday() {
        isSaving = true
        errorMessage = nil
        let dob = Self.dateString(from: birthday)
        Task {
            do {
                _ = try await model.saveBirthday(dob)
                isSaving = false
            } catch {
                isSaving = false
                errorMessage = "We couldn’t save your birthday. Please try again."
            }
        }
    }

    private static let defaultBirthday: Date = {
        Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1)) ?? Date()
    }()

    private static let earliestBirthday: Date = {
        Calendar.current.date(from: DateComponents(year: 1900, month: 1, day: 1)) ?? Date(timeIntervalSince1970: 0)
    }()

    private static func dateString(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 2000, components.month ?? 1, components.day ?? 1)
    }
}

struct ParentEmailGateView: View {
    @ObservedObject var model: GameViewModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var emailFocused: Bool
    @State private var email = ""
    @State private var didSave = false
    @State private var errorMessage: String?

    var body: some View {
        AccountSurface {
            VStack(alignment: .leading, spacing: 22) {
                BrandMark()
                    .padding(.bottom, 28)

                Text("A parent or guardian is needed")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(colorScheme == .dark ? .primary : cubacadabraInk)

                Text("Because you’re under 13, a parent or guardian needs to help before you can use cubacadabra.")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 9) {
                    Text("PARENT OR GUARDIAN EMAIL")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(.secondary)
                    TextField("parent@example.com", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($emailFocused)
                        .font(.system(size: 17, weight: .regular, design: .rounded))
                        .padding(.horizontal, 15)
                        .frame(minHeight: 52)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }

                Text("Ask a parent or guardian for permission before entering their email.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.red)
                } else if didSave {
                    Label("Thanks — we saved the email. A parent or guardian can take the next step.", systemImage: "checkmark.circle")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.green)
                }

                Button {
                    saveParentEmail()
                } label: {
                    HStack(spacing: 10) {
                        Text(didSave ? "UPDATE EMAIL" : "SAVE EMAIL")
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 58)
                    .background(cubacadabraCoral, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            email = model.storedParentEmail()
            didSave = !email.isEmpty
        }
    }

    private func saveParentEmail() {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@"), trimmed.split(separator: "@").count == 2, !trimmed.hasSuffix("@") else {
            errorMessage = "Enter a parent or guardian’s email address."
            emailFocused = true
            return
        }
        errorMessage = nil
        email = trimmed
        model.saveParentEmail(trimmed)
        didSave = true
        emailFocused = false
    }
}

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
                        if game.id != GameCatalogEntry.available.last?.id {
                            Divider().padding(.leading, 60)
                        }
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
                        SafetyCenterView(model: model)
                    } label: {
                        menuRow(icon: "checkmark.shield", title: "Block or unblock players", detail: "Players & safety")
                    }
                }
                .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                menuSectionTitle("ABOUT")
                    .padding(.top, 36)

                VStack(spacing: 0) {
                    Link(destination: AppLinks.privacy) {
                        menuRow(icon: "lock.shield", title: "Privacy policy")
                    }
                    Divider().padding(.leading, 60)
                    Link(destination: AppLinks.terms) {
                        menuRow(icon: "doc.text", title: "Terms of use")
                    }
                    Divider().padding(.leading, 60)
                    Link(destination: AppLinks.support) {
                        menuRow(icon: "envelope", title: "Contact support")
                    }
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
                do {
                    try await openGame(game)
                } catch {
                    gameError = gameSelectionErrorMessage(for: error)
                }
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
                if model.isSelectingGame {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                }
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
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 16)
        .frame(minHeight: 60)
    }

    private func menuSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .tracking(1.5)
            .foregroundStyle(.secondary)
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
    @Environment(\.dismiss) private var dismiss
    @FocusState private var usernameFocused: Bool
    @State private var username = ""
    @State private var isSaving = false
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Choose a name other players can find you by.")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 9) {
                    Text("USERNAME")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(.secondary)
                    TextField("Your username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($usernameFocused)
                        .font(.system(size: 17, weight: .regular, design: .rounded))
                        .padding(.horizontal, 15)
                        .frame(minHeight: 52)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }

                Text("Use 2–24 letters, numbers, _ or -.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                if let message {
                    Label(message, systemImage: messageIsError ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(messageIsError ? .red : .green)
                }

                Button {
                    saveUsername()
                } label: {
                    HStack {
                        if isSaving { ProgressView().tint(.white) }
                        Text(isSaving ? "SAVING…" : "SAVE USERNAME")
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
                .disabled(isSaving)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 24)
        }
        .navigationTitle("Username")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear { username = model.authUser?.username ?? model.username }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { usernameFocused = false }
            }
        }
    }

    private func saveUsername() {
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 2,
              normalized.count <= 24,
              normalized.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            message = "Use 2–24 letters, numbers, _ or -."
            messageIsError = true
            usernameFocused = true
            return
        }

        isSaving = true
        message = nil
        Task {
            do {
                _ = try await model.saveProfileUsername(normalized)
                username = normalized
                isSaving = false
                message = "Username saved."
                messageIsError = false
                usernameFocused = false
            } catch let error as AppProfileError {
                isSaving = false
                message = switch error.errorCode {
                case "username_taken": "That username is already in use. Try another."
                case "username_not_allowed": "That username isn’t available. Try another."
                default: "We couldn’t save your username. Please try again."
                }
                messageIsError = true
            } catch {
                isSaving = false
                message = "We couldn’t save your username. Please try again."
                messageIsError = true
            }
        }
    }
}

private struct AccountSurface<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(.systemBackground).ignoresSafeArea()
            Circle()
                .fill(cubacadabraCoral.opacity(colorScheme == .dark ? 0.15 : 0.09))
                .frame(width: 330, height: 330)
                .blur(radius: 2)
                .offset(x: 125, y: -170)
                .allowsHitTesting(false)

            ScrollView {
                content
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 38)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

private struct BrandMark: View {
    var body: some View {
        Text("CUBACADABRA")
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .tracking(2.6)
            .foregroundStyle(.primary)
    }
}
