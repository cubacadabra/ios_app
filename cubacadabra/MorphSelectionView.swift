import SwiftUI

private let morphCoral = Color(red: 0.91, green: 0.39, blue: 0.29)

struct MorphOption {
    let label: String
    static func option(for bodyID: String?) -> MorphOption {
        MorphOption(label: bodyID == "cuba:person.v1" ? "Person 1" : "Custom morph")
    }
}

struct MorphSelectionView: View {
    @ObservedObject var model: AppViewModel
    @State private var tab = 0
    @State private var previewAction: String?
    private var appearance: AppRuntimeAppearanceSnapshot { model.appearanceSnapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Choose a starter, then customize the details.").font(.system(size: 17, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                Picker("Morph editor", selection: $tab) { Text("Starters").tag(0); Text("Customize").tag(1) }.pickerStyle(.segmented)
                if appearance.isLoading { ProgressView("Loading morphs…") } else if tab == 0 { starterList } else { customizeList }
                preview
                if let feedback = appearance.feedback { Label(feedback.message, systemImage: feedback.kind == .error ? "exclamationmark.circle" : "checkmark.circle").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(feedback.kind == .error ? .red : .green) }
                Button { model.saveMorph() } label: {
                    HStack { if appearance.isSaving { ProgressView().tint(.white) }; Text(appearance.isSaving ? "SAVING…" : "SAVE MORPH"); Spacer(); Image(systemName: "checkmark") }
                        .font(.system(size: 15, weight: .bold, design: .rounded)).tracking(1.1).foregroundStyle(.white).padding(.horizontal, 20).frame(minHeight: 56).background(morphCoral, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }.buttonStyle(.plain).disabled(appearance.isSaving || !appearance.draftCanSave)
            }.frame(maxWidth: 620, alignment: .leading).padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 28)
        }.navigationTitle("Choose your morph").navigationBarTitleDisplayMode(.inline).background(Color(.systemBackground).ignoresSafeArea()).onAppear { model.beginMorphEdit() }
    }

    private var starterList: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
            ForEach(appearance.presets) { preset in
                Button { model.chooseMorphPreset(preset.id) } label: {
                    VStack(alignment: .leading, spacing: 5) { Text(preset.displayName).font(.system(size: 16, weight: .bold, design: .rounded)); Text(preset.parts.isEmpty ? "Base morph" : "Ready to play").font(.caption).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading).padding(14).background(.secondary.opacity(preset.base == appearance.draftBase ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous)).overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(preset.base == appearance.draftBase ? morphCoral : .clear, lineWidth: 2) }
                }.buttonStyle(.plain).disabled(appearance.isSaving)
            }
        }
    }

    private var customizeList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Dictionary(grouping: appearance.assets.filter { $0.kind != "base" }, by: { $0.kind }).sorted(by: { $0.key < $1.key }), id: \.key) { kind, assets in
                let selected = assets.first(where: { appearance.draftParts.contains($0.id) })?.id ?? appearance.draftFace
                Menu { Button("None") { if let selected { model.clearMorphPart(selected) } }; ForEach(assets) { asset in Button(asset.displayName) { model.setMorphPart(asset.id) } } } label: {
                    HStack { Text(kind.capitalized).foregroundStyle(.secondary); Spacer(); Text(assets.first(where: { $0.id == selected })?.displayName ?? "None"); Image(systemName: "chevron.up.chevron.down") }.padding(14).background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview").font(.headline)
            HStack(alignment: .bottom, spacing: 14) {
                Image("MorphBoy").resizable().scaledToFit().frame(width: 150, height: 190).background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous)).rotation3DEffect(.degrees(previewAction == "turn" ? 180 : 0), axis: (0, 1, 0)).offset(x: previewAction == "walk" ? 8 : 0, y: previewAction == "jump" ? -22 : 0).animation(.easeInOut(duration: 0.55), value: previewAction)
                HStack(spacing: 8) { ForEach(["walk", "jump", "turn"], id: \.self) { action in Button(action.capitalized) { previewAction = action; DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { if previewAction == action { previewAction = nil } } }.buttonStyle(.bordered) } }
            }
        }
    }
}
