import Foundation
import SwiftUI

struct MyCubeView: View {
    @ObservedObject var model: GameViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var step: MyCubeStep
    @State private var selectedBirthday: Date
    @State private var birthdayWasChanged = false
    @State private var parentEmail = ""
    @State private var username = ""
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isSaving = false
    @FocusState private var focusedField: Field?

    private let coral = Color(red: 0.91, green: 0.39, blue: 0.29)
    private let ink = Color(red: 0.15, green: 0.29, blue: 0.29)

    private enum MyCubeStep: Hashable {
        case birthday
        case parentEmail
        case basics

        var title: String {
            switch self {
            case .birthday, .parentEmail: "Birthday"
            case .basics: "Basics"
            }
        }
    }

    private enum Field: Hashable {
        case parentEmail
        case username
    }

    init(model: GameViewModel) {
        self.model = model
        let initialStep: MyCubeStep
        if let dob = model.authUser?.dateOfBirth,
           let age = Self.calculateAge(from: dob) {
            initialStep = age < 13 ? .parentEmail : .basics
        } else {
            initialStep = .birthday
        }
        _step = State(initialValue: initialStep)
        _selectedBirthday = State(initialValue: Self.defaultBirthday)
        _username = State(initialValue: model.authUser?.username ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    sectionMenu
                        .padding(.top, 28)

                    Group {
                        switch step {
                        case .birthday:
                            birthdayContent
                        case .parentEmail:
                            parentEmailContent
                        case .basics:
                            basicsContent
                        }
                    }
                    .id(step)
                    .padding(.top, 30)
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(Color(.systemBackground))
            .navigationTitle("My Cube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(coral)
        .presentationDragIndicator(.visible)
        .onAppear {
            if case .basics = step {
                username = model.authUser?.username ?? model.username
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YOUR PLAYER PROFILE")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(.secondary)
            Text(step == .basics ? "The basics" : "One important detail")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(colorScheme == .dark ? .primary : ink)
            Text(headerCopy)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerCopy: String {
        switch step {
        case .birthday:
            "Your birthday helps us create the right, safer experience for your age."
        case .parentEmail:
            "Because you’re under 13, we need a parent or guardian before you can continue."
        case .basics:
            "Choose the name other players will see when you explore."
        }
    }

    private var sectionMenu: some View {
        Menu {
            switch step {
            case .birthday, .parentEmail:
                Button {
                    step = .birthday
                    clearStatus()
                } label: {
                    Label("Birthday", systemImage: "calendar")
                }
            case .basics:
                Button {
                    step = .basics
                    clearStatus()
                } label: {
                    Label("Basics", systemImage: "person.crop.circle")
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: step == .basics ? "person.crop.circle" : "calendar")
                    .font(.system(size: 16, weight: .semibold))
                Text(step.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Spacer()
                if step != .basics {
                    Text("Required to continue")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("My Cube section, \(step.title)")
        .disabled(step != .basics && step != .birthday)
    }

    private var birthdayContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            guidanceBlock(
                eyebrow: "A SAFER WORLD FOR EVERYONE",
                title: "Real age, real protections.",
                body: "cubacadabra takes COPPA and child safety seriously, so we need your real age to apply the right safeguards. If you’re a kid, please don’t lie about your age."
            )

            VStack(alignment: .leading, spacing: 14) {
                Text("YOUR BIRTHDAY")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                Text("Use the date on your official records. No time or location is needed.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                DatePicker(
                    "Date of birth",
                    selection: $selectedBirthday,
                    in: Self.earliestBirthday...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .onChange(of: selectedBirthday) { _ in
                    birthdayWasChanged = true
                    clearStatus()
                }
            }

            saveButton("Save birthday", systemImage: "checkmark") {
                saveBirthday()
            }
            .disabled(!birthdayWasChanged || isSaving)
        }
    }

    private var parentEmailContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            guidanceBlock(
                eyebrow: "WHY WE ASK",
                title: "Safety works better together.",
                body: "Ask your parent or guardian to sign up with you. They’ll be able to know which cubes you’re using while you enjoy a fun, safe experience."
            )

            VStack(alignment: .leading, spacing: 14) {
                Text("PARENT OR GUARDIAN EMAIL")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                Text("We’ll use this to start the parent sign-up step.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("Please ask a parent or guardian for permission before entering their email.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("parent@example.com", text: $parentEmail)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .parentEmail)
                    .submitLabel(.continue)
                    .onSubmit { continueWithParent() }
                    .frame(minHeight: 44)
            }

            if let statusMessage {
                statusText(statusMessage, isError: statusIsError)
            }

            saveButton("Continue with a parent", systemImage: "arrow.right") {
                continueWithParent()
            }
        }
        .onAppear {
            focusedField = .parentEmail
        }
    }

    private var basicsContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                Text("USERNAME")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                TextField("Choose a username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.nickname)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .username)
                    .submitLabel(.done)
                    .onSubmit { saveUsername() }
                    .frame(minHeight: 44)
                Text("2–24 characters: letters, numbers, _ or -")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if let statusMessage {
                statusText(statusMessage, isError: statusIsError)
            }

            saveButton("Save", systemImage: "checkmark") {
                saveUsername()
            }
            .disabled(isSaving)
        }
        .onAppear {
            username = model.authUser?.username ?? model.username
            focusedField = .username
        }
    }

    private func guidanceBlock(eyebrow: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.3)
                .foregroundStyle(coral)
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text(body)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isSaving {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .bold))
                }
                Text(isSaving ? "Saving…" : title)
                Spacer()
            }
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(minHeight: 54)
            .background(coral, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Saves this part of your player profile")
    }

    private func statusText(_ message: String, isError: Bool) -> some View {
        Label(message, systemImage: isError ? "exclamationmark.circle" : "checkmark.circle")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(isError ? .red : .green)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func saveBirthday() {
        guard birthdayWasChanged else { return }
        isSaving = true
        clearStatus()
        let dob = Self.dateString(from: selectedBirthday)
        Task {
            do {
                let result = try await model.saveBirthday(dob)
                let age = result.age ?? Self.calculateAge(from: dob) ?? 0
                step = age < 13 ? .parentEmail : .basics
                username = result.user.username ?? model.username
                isSaving = false
            } catch {
                isSaving = false
                showError(Self.birthdayErrorMessage(for: error))
            }
        }
    }

    private func continueWithParent() {
        guard Self.isValidEmail(parentEmail) else {
            focusedField = .parentEmail
            showError("Enter your parent or guardian’s email address.")
            return
        }
        showStatus("Parent sign-up will continue here next.")
    }

    private func saveUsername() {
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        username = normalized
        guard Self.isValidUsername(normalized) else {
            focusedField = .username
            showError("Use 2–24 letters, numbers, _ or -.")
            return
        }

        isSaving = true
        clearStatus()
        Task {
            do {
                let result = try await model.saveProfileUsername(normalized)
                username = result.user.username ?? normalized
                isSaving = false
                showStatus("Username saved.")
            } catch {
                isSaving = false
                showError(Self.usernameErrorMessage(for: error))
            }
        }
    }

    private func clearStatus() {
        statusMessage = nil
        statusIsError = false
    }

    private func showStatus(_ message: String) {
        statusMessage = message
        statusIsError = false
    }

    private func showError(_ message: String) {
        statusMessage = message
        statusIsError = true
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

    private static func calculateAge(from dob: String) -> Int? {
        let values = dob.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        let now = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        guard let year = values[safe: 0], let month = values[safe: 1], let day = values[safe: 2], let currentYear = now.year else {
            return nil
        }
        var age = currentYear - year
        if (now.month ?? 0, now.day ?? 0) < (month, day) {
            age -= 1
        }
        return age
    }

    private static func isValidEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && trimmed.split(separator: "@").count == 2 && !trimmed.hasSuffix("@")
    }

    private static func isValidUsername(_ username: String) -> Bool {
        username.count >= 2 && username.count <= 24 && username.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    private static func birthdayErrorMessage(for error: Error) -> String {
        if let profileError = error as? AppProfileError,
           profileError.errorCode == "invalid_date_of_birth" {
            return "That date is not valid. Check the year, month, and day, then try again."
        }
        return "We couldn’t save your birthday. Please try again."
    }

    private static func usernameErrorMessage(for error: Error) -> String {
        guard let profileError = error as? AppProfileError else {
            return "We couldn’t save your username. Please try again."
        }
        switch profileError.errorCode {
        case "username_taken":
            return "That username is already in use. Try another."
        case "username_not_allowed":
            return "That username isn’t available. Try another."
        case "invalid_username":
            return "Use 2–24 letters, numbers, _ or -."
        case "age_required":
            return "Complete the birthday step before choosing a username."
        default:
            return "We couldn’t save your username. Please try again."
        }
    }
}
