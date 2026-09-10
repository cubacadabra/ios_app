import Foundation

extension AppViewModel {
    var profileAge: Int? {
        guard let dob = authUser?.dateOfBirth else { return nil }
        return Self.calculateAge(from: dob)
    }

    var needsBirthday: Bool { isAuthenticated && authUser?.dateOfBirth == nil }
    var isUnderThirteen: Bool { profileAge.map { $0 < 13 } ?? false }

    func storedParentEmail() -> String {
        guard let userID = authUser?.id else { return "" }
        return UserDefaults.standard.string(forKey: "cubacadabra.parent-email.\(userID)") ?? ""
    }

    func saveParentEmail(_ email: String) {
        guard let userID = authUser?.id else { return }
        UserDefaults.standard.set(email, forKey: "cubacadabra.parent-email.\(userID)")
    }

    static func calculateAge(from dob: String) -> Int? {
        let values = dob.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        let (year, month, day) = (values[0], values[1], values[2])
        let now = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        guard let currentYear = now.year else { return nil }
        var age = currentYear - year
        if (now.month ?? 0, now.day ?? 0) < (month, day) { age -= 1 }
        return age
    }
}
