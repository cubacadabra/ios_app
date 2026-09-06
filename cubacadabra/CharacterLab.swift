import Combine
import SwiftUI

private let characterLabCoral = Color(red: 0.91, green: 0.39, blue: 0.29)

private struct CharacterLabBody: Identifiable {
    let id: String
    let label: String
    let stableID: String
    let symbol: String
}

private struct CharacterLabOutfit: Identifiable {
    let id: String
    let label: String
    let stableID: String
    let pairing: String
    let supportedBodies: Set<String>
}

private let characterLabBodies = [
    CharacterLabBody(id: "person", label: "Person", stableID: "cuba:person.v1", symbol: "person.fill"),
    CharacterLabBody(id: "cat", label: "Cat", stableID: "cuba:cat.v1", symbol: "cat.fill"),
    CharacterLabBody(id: "dragon", label: "Dragon", stableID: "cuba:dragon.v1", symbol: "flame.fill"),
]

private let characterLabExpressions = [
    "neutral", "happy", "surprised", "determined", "sad", "laughing", "smile",
    "grin", "curious", "amazed", "angry", "crying", "worried", "embarrassed",
    "sleepy", "squinting", "wink", "smirk", "confused", "excited", "unimpressed",
]

private let characterLabOutfits = [
    CharacterLabOutfit(id: "everyday-hoodie", label: "Everyday hoodie", stableID: "cuba:everyday-hoodie.v1", pairing: "All bodies", supportedBodies: ["person", "cat", "dragon"]),
    CharacterLabOutfit(id: "puffer-explorer", label: "Puffer explorer", stableID: "cuba:puffer-explorer.v1", pairing: "Cat", supportedBodies: ["cat"]),
    CharacterLabOutfit(id: "raincoat", label: "Glossy raincoat", stableID: "cuba:glossy-raincoat.v1", pairing: "All bodies", supportedBodies: ["person", "cat", "dragon"]),
    CharacterLabOutfit(id: "wizard-cloak", label: "Star wizard cloak", stableID: "cuba:star-wizard.v1", pairing: "Dragon", supportedBodies: ["dragon"]),
    CharacterLabOutfit(id: "toy-knight", label: "Toy knight armor", stableID: "cuba:toy-knight.v1", pairing: "Dragon", supportedBodies: ["dragon"]),
    CharacterLabOutfit(id: "fuzzy-pajamas", label: "Fuzzy pajamas", stableID: "cuba:fuzzy-pajamas.v1", pairing: "Person", supportedBodies: ["person"]),
]

private let characterLabMotions = [
    (id: "idle", label: "Idle", symbol: "figure.stand"),
    (id: "walk", label: "Walk", symbol: "figure.walk"),
    (id: "run", label: "Run", symbol: "figure.run"),
    (id: "jump", label: "Jump", symbol: "arrow.up"),
]

struct CharacterLabView: View {
    @ObservedObject var model: GameViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var bodyID = "person"
    @State private var expressionID = "happy"
    @State private var outfitID = "everyday-hoodie"
    @State private var motionID = "idle"
    @State private var reducedEffects = false
    @State private var status = "Live preview · choose a style to apply it"
    @State private var didStart = false
    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    private var selectedBody: CharacterLabBody {
        characterLabBodies.first { $0.id == bodyID } ?? characterLabBodies[0]
    }

    private var selectedOutfit: CharacterLabOutfit {
        characterLabOutfits.first { $0.id == outfitID } ?? characterLabOutfits[0]
    }

    private var outfitFits: Bool {
        selectedOutfit.supportedBodies.contains(bodyID)
    }

    private var expressionCountLabel: String {
        String((characterLabExpressions.firstIndex(of: expressionID) ?? 0) + 1)
            + " / " + String(characterLabExpressions.count)
    }

    private var outfitCountLabel: String {
        String((characterLabOutfits.firstIndex { $0.id == outfitID } ?? 0) + 1)
            + " / " + String(characterLabOutfits.count)
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    preview
                        .padding(.bottom, 22)
                    sectionHeader("BODY", detail: "Choose a silhouette")
                    bodyChoices
                    divider
                    sectionHeader("EXPRESSION", detail: expressionCountLabel)
                    expressionChoices
                    divider
                    sectionHeader("OUTFIT", detail: outfitCountLabel)
                    outfitChoices
                    divider
                    sectionHeader("MOTION", detail: "Live preview")
                    motionChoices
                    utilityChoices
                    Text(status)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                        .padding(.bottom, 28)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
        }
        .navigationTitle("Character lab")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            guard !didStart else { return }
            didStart = true
            model.beginCharacterLab()
            applySelection()
        }
        .onDisappear {
            model.endCharacterLab()
        }
        .onReceive(tick) { date in
            model.tick(at: date)
        }
    }

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            if let engine = model.renderEngine {
                RustGameSurface(
                    engine: engine,
                    isActive: true,
                    onLookChanged: { model.lookChanged(to: $0) },
                    onLookEnded: { model.lookEnded() },
                    onZoomDelta: { model.zoomChangedBy(delta: $0) },
                    onZoomEnded: { model.zoomEnded() }
                )
            } else {
                Color.secondary.opacity(0.12)
            }

            LinearGradient(
                colors: [.black.opacity(0.40), .clear, .black.opacity(0.28)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 4) {
                Label("LIVE PREVIEW", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.92))
                Text("\(selectedBody.label) · \(titleCase(expressionID))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
            }
            .padding(16)
        }
        .frame(height: 286)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.primary.opacity(colorScheme == .dark ? 0.18 : 0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.10), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live character preview: \(selectedBody.label), \(titleCase(expressionID)), \(selectedOutfit.label)")
    }

    private var bodyChoices: some View {
        HStack(spacing: 8) {
            ForEach(characterLabBodies) { body in
                labButton(isSelected: bodyID == body.id, label: body.label, symbol: body.symbol) {
                    bodyID = body.id
                    applySelection()
                }
            }
        }
    }

    private var expressionChoices: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
            ForEach(characterLabExpressions, id: \.self) { expression in
                labButton(isSelected: expressionID == expression, label: titleCase(expression)) {
                    expressionID = expression
                    applySelection()
                }
            }
        }
    }

    private var outfitChoices: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], spacing: 8) {
            ForEach(characterLabOutfits) { outfit in
                let fits = outfit.supportedBodies.contains(bodyID)
                VStack(alignment: .leading, spacing: 3) {
                    labButton(isSelected: outfitID == outfit.id, label: outfit.label) {
                        outfitID = outfit.id
                        applySelection()
                    }
                    Text(fits ? outfit.pairing : "Fallback on this body")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(fits ? .secondary : characterLabCoral)
                        .padding(.horizontal, 10)
                }
            }
        }
    }

    private var motionChoices: some View {
        HStack(spacing: 8) {
            ForEach(characterLabMotions, id: \.id) { motion in
                labButton(isSelected: motionID == motion.id, label: motion.label, symbol: motion.symbol) {
                    motionID = motion.id
                    model.setCharacterLabMotion(motion.id)
                }
            }
        }
    }

    private var utilityChoices: some View {
        HStack(spacing: 8) {
            Button {
                model.triggerCharacterLabWave()
                status = "Wave triggered."
            } label: {
                Label("Wave", systemImage: "hand.wave")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            Button {
                reducedEffects.toggle()
                model.renderEngine?.setReducedEffects(reducedEffects)
                status = reducedEffects ? "Reduced effects enabled." : "Full effects enabled."
            } label: {
                Label(reducedEffects ? "Reduced effects" : "Full effects", systemImage: "circle.lefthalf.filled")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            Button {
                model.renderEngine?.resetShowcaseView()
                status = "Preview camera reset. Drag the preview to look around."
            } label: {
                Label("Reset view", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 10)
    }

    private var divider: some View {
        Divider().padding(.vertical, 20)
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(.primary)
            Spacer()
            Text(detail)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 10)
    }

    private func labButton(
        isSelected: Bool,
        label: String,
        symbol: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(isSelected ? .white : .primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 8)
            .background(isSelected ? characterLabCoral : Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if !isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.primary.opacity(0.08), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func applySelection() {
        guard didStart,
              let body = characterLabBodies.first(where: { $0.id == bodyID }),
              let outfit = characterLabOutfits.first(where: { $0.id == outfitID }) else { return }
        let result = model.applyCharacterLabAppearance(
            body: body.stableID,
            face: expressionID,
            outfit: outfit.stableID
        )
        if result == 1 {
            status = "Preview applied · \(selectedBody.label) · \(titleCase(expressionID)) · \(outfit.label)"
        } else if result == 3 || !outfitFits {
            status = "Preview applied with a safe fallback for this body/outfit pairing."
        } else {
            status = "This preview is unavailable in the current engine build."
        }
    }

    private func titleCase(_ value: String) -> String {
        value.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
