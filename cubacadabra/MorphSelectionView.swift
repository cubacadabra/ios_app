import SwiftUI

private let morphCoral = Color(red: 0.91, green: 0.39, blue: 0.29)

struct MorphOption: Identifiable, Hashable {
    let id: String
    let label: String
    let imageName: String

    static let all = [
        MorphOption(id: "cuba:person.v1", label: "Boy", imageName: "MorphBoy"),
        MorphOption(id: "cuba:person-girl.v1", label: "Girl", imageName: "MorphGirl"),
        MorphOption(id: "cuba:person-nb.v1", label: "Nonbinary", imageName: "MorphNonbinary"),
    ]

    static let fallback = all[0]

    static func option(for bodyID: String?) -> MorphOption {
        all.first { $0.id == bodyID } ?? fallback
    }
}

struct MorphSelectionView: View {
    @ObservedObject var model: AppViewModel
    @State private var selectedMorphID = MorphOption.fallback.id

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Choose how you appear in a game.")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                    ForEach(MorphOption.all) { morph in
                        morphCard(morph)
                    }
                }

                if let feedback = model.profileUsername.bodyFeedback {
                    Label(feedback.message, systemImage: feedback.kind == .error ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(feedback.kind == .error ? .red : .green)
                }

                Button {
                    saveMorph()
                } label: {
                    HStack(spacing: 10) {
                        if model.profileUsername.bodyIsSaving { ProgressView().tint(.white) }
                        Text(model.profileUsername.bodyIsSaving ? "SAVING…" : "SAVE MORPH")
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 56)
                    .background(morphCoral, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(model.profileUsername.bodyIsSaving)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .navigationTitle("Choose your morph")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear {
            selectedMorphID = MorphOption.option(for: model.profileUsername.bodyId).id
            model.beginMorphEdit()
        }
    }

    private func morphCard(_ morph: MorphOption) -> some View {
        let isSelected = morph.id == selectedMorphID

        return Button {
            selectedMorphID = morph.id
            model.changeMorph(morph.id)
        } label: {
            VStack(spacing: 10) {
                Image(morph.imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
                    .padding(.horizontal, 8)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                HStack(spacing: 7) {
                    Text(morph.label)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                    }
                }
                .foregroundStyle(isSelected ? morphCoral : .primary)
                .frame(minHeight: 24)
            }
            .padding(10)
            .background(.secondary.opacity(isSelected ? 0.13 : 0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? morphCoral : .primary.opacity(0.10), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(morph.label) morph")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func saveMorph() {
        model.saveMorph()
    }
}
