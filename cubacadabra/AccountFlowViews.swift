import SwiftUI

let cubacadabraCoral = Color(red: 0.91, green: 0.39, blue: 0.29)
let cubacadabraInk = Color(red: 0.15, green: 0.29, blue: 0.29)

struct SignInChoiceView: View {
    @ObservedObject var model: GameViewModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedField: Field?
    @State private var emailMode = false
    @State private var email = "play-review@cubacadabra.com"
    @State private var password = "testing"

    private enum Field: Hashable {
        case email
        case password
    }

    var body: some View {
        AccountSurface {
            VStack(alignment: .leading, spacing: 24) {
                BrandMark()
                    .padding(.bottom, 34)

                Text(emailMode ? "Sign in to cubacadabra" : "Welcome to cubacadabra")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(colorScheme == .dark ? .primary : cubacadabraInk)

                Text(emailMode
                     ? "Use your cubacadabra email and password to continue."
                     : "Sign in to create your player profile and explore the cubes.")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if emailMode {
                    Button {
                        focusedField = nil
                        emailMode = false
                    } label: {
                        Label("OTHER SIGN-IN OPTIONS", systemImage: "chevron.left")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .tracking(1.1)
                            .foregroundStyle(cubacadabraCoral)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isSigningIn)

                    VStack(alignment: .leading, spacing: 9) {
                        Text("EMAIL")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(.secondary)
                        TextField("you@example.com", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .email)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .password }
                            .font(.system(size: 17, weight: .regular, design: .rounded))
                            .padding(.horizontal, 15)
                            .frame(minHeight: 52)
                            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        Text("PASSWORD")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(.secondary)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .focused($focusedField, equals: .password)
                            .submitLabel(.go)
                            .onSubmit { submitEmailSignIn() }
                            .font(.system(size: 17, weight: .regular, design: .rounded))
                            .padding(.horizontal, 15)
                            .frame(minHeight: 52)
                            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }

                    signInNotice

                    Button {
                        submitEmailSignIn()
                    } label: {
                        HStack(spacing: 10) {
                            if model.isSigningIn { ProgressView().tint(.white) }
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
                    .disabled(model.isSigningIn || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                } else {
                    Text("Choose how you want to continue.")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    Button {
                        model.signInWithGoogle()
                    } label: {
                        HStack(spacing: 12) {
                            if model.isSigningIn {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "person.crop.circle.badge.plus")
                            }
                            Text(model.isSigningIn ? "SIGNING IN…" : "CONTINUE WITH GOOGLE")
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .tracking(1.0)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 58)
                        .background(cubacadabraCoral, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isSigningIn)

                    Button {
                        model.clearAuthenticationNotice()
                        emailMode = true
                    } label: {
                        HStack {
                            Image(systemName: "envelope")
                            Text("USE EMAIL INSTEAD")
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .tracking(1.0)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 56)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .stroke(.secondary.opacity(0.28), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isSigningIn)

                    signInNotice
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
    }

    @ViewBuilder
    private var signInNotice: some View {
        if let authenticationNotice = model.authenticationNotice {
            Label(authenticationNotice, systemImage: "exclamationmark.circle")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.red)
        }
    }

    private func submitEmailSignIn() {
        focusedField = nil
        model.signInWithEmail(email: email, password: password)
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

struct BrandMark: View {
    var body: some View {
        Text("CUBACADABRA")
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .tracking(2.6)
            .foregroundStyle(.primary)
    }
}
