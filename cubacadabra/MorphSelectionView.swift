import Combine
import SwiftUI

private let morphCoral = Color(red: 0.91, green: 0.39, blue: 0.29)

struct MorphSelectionView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject var gameModel: GameViewModel
    @State private var tab = 0
    private let previewClock = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
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
        }.navigationTitle("Choose your morph").navigationBarTitleDisplayMode(.inline).background(Color(.systemBackground).ignoresSafeArea()).onAppear { model.beginMorphEdit(); syncPreviewAppearance() }.onChange(of: appearance.draftBase) { _ in syncPreviewAppearance() }.onChange(of: appearance.draftParts) { _ in syncPreviewAppearance() }.onChange(of: appearance.draftFace) { _ in syncPreviewAppearance() }.onChange(of: appearance.draftRenderJson) { _ in syncPreviewAppearance() }.onChange(of: appearance.assets) { _ in syncPreviewAppearance() }.onReceive(previewClock) { date in gameModel.tickMorphPreview(at: date) }
    }

    private var starterList: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
            ForEach(appearance.presets) { preset in
                let isSelected = preset.id == appearance.draftPresetId
                Button { model.chooseMorphPreset(preset.id) } label: {
                    VStack(alignment: .leading, spacing: 5) { Text(preset.displayName).font(.system(size: 16, weight: .bold, design: .rounded)); Text(preset.parts.isEmpty ? "Base morph" : "Ready to play").font(.caption).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading).padding(14).background(.secondary.opacity(isSelected ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous)).overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(isSelected ? morphCoral : .clear, lineWidth: 2) }
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
                if let engine = gameModel.morphPreviewEngine {
                    RustGameSurface(engine: engine, isActive: true, avatarPreviewMode: true)
                        .frame(width: 260, height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    ProgressView("Loading 3D preview…").frame(width: 260, height: 260)
                }
                Text(previewName).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) { ForEach(["walk", "jump", "turn"], id: \.self) { action in Button(action.capitalized) { gameModel.playMorphPreview(action) }.buttonStyle(.bordered) } }
            }
        }
    }

    private var previewName: String {
        appearance.presets.first { $0.id == appearance.draftPresetId }?.displayName ?? "Custom morph"
    }

    private func syncPreviewAppearance() {
        guard let base = appearance.draftBase,
              let source = appearance.draftRenderJson else { return }
        let ids = [base] + appearance.draftParts + (appearance.draftFace.map { [$0] } ?? [])
        let urls: [URL] = appearance.assets.compactMap { asset in
            guard ids.contains(asset.id), let path = asset.artifactURL else { return nil }
            return URL(string: path, relativeTo: ClientConfiguration.backendAPIURL)?.absoluteURL
        }
        gameModel.updateMorphPreview(source: source, packURLs: urls)
    }

}
