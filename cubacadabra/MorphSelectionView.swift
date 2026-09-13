import Combine
import Foundation
import OSLog
import SwiftUI

private let morphAccent = Color(red: 0.36, green: 0.37, blue: 0.98)
private let morphAccentBright = Color(red: 0.50, green: 0.43, blue: 1.00)
private let morphStageInk = Color(red: 0.035, green: 0.055, blue: 0.12)

private struct MorphPreviewSelection: Equatable {
    let release: String?
    let base: String?
    let parts: [String]
    let face: String?
    let loadoutJSON: String?
    let assets: [AppRuntimeMorphAsset]
    let presets: [AppRuntimeMorphPreset]
}

private struct MorphAssetGroup: Identifiable {
    let id: String
    let assets: [AppRuntimeMorphAsset]
}

private struct MorphEditorCategory: Identifiable {
    let id: String
    let title: String
    let icon: String
    let kind: String?
}

private struct MorphAssetOption: Identifiable {
    let id: String
    let asset: AppRuntimeMorphAsset?
}

struct MorphSelectionView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject var gameModel: GameViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var tab = 0
    @State private var selectedKind: String?
    @State private var appeared = false
    @State private var canvasInteractionActive = false
    @State private var categoryPage = 0
    @State private var starterPage = 0
    @State private var assetPage = 0
    private let previewClock = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    private var appearance: AppRuntimeAppearanceSnapshot { model.appearanceSnapshot }

    private var previewSelection: MorphPreviewSelection {
        MorphPreviewSelection(
            release: appearance.release,
            base: appearance.draftBase,
            parts: appearance.draftParts,
            face: appearance.draftFace,
            loadoutJSON: appearance.draftLoadoutJson,
            assets: appearance.assets,
            presets: appearance.presets
        )
    }

    private var assetGroups: [MorphAssetGroup] {
        Dictionary(grouping: appearance.assets.filter { $0.kind != "base" }, by: { $0.kind })
            .map { MorphAssetGroup(id: $0.key, assets: $0.value.sorted { $0.displayName < $1.displayName }) }
            .sorted { categoryOrder($0.id) < categoryOrder($1.id) }
    }

    private var activeGroup: MorphAssetGroup? {
        assetGroups.first { $0.id == selectedKind } ?? assetGroups.first
    }

    private var selectedPreviewPresetIndex: Int {
        guard let presetID = appearance.draftPresetId,
              let index = appearance.presets.firstIndex(where: { $0.id == presetID }) else { return 0 }
        return index
    }

    private var selectedPreviewThumbnailPath: String? {
        guard let presetID = appearance.draftPresetId else { return nil }
        return appearance.presets.first(where: { $0.id == presetID })?.thumbnail
    }

    private var editorCategories: [MorphEditorCategory] {
        [MorphEditorCategory(id: "starters", title: "Starters", icon: "person.3.fill", kind: nil)]
            + assetGroups.map {
                MorphEditorCategory(
                    id: $0.id,
                    title: categoryName($0.id),
                    icon: categoryIcon($0.id),
                    kind: $0.id
                )
            }
    }

    private var categoryItemsPerPage: Int { horizontalSizeClass == .regular ? 8 : 4 }
    private var starterItemsPerPage: Int { horizontalSizeClass == .regular ? 4 : 2 }
    private var assetItemsPerPage: Int { horizontalSizeClass == .regular ? 5 : 2 }

    private var stageTextColor: Color {
        colorScheme == .dark ? .white : Color(red: 0.08, green: 0.10, blue: 0.17)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                stageBackdrop

                VStack(spacing: 0) {
                    editorHeader
                        .padding(.horizontal, 20)
                        .padding(.top, 4)

                    modePicker
                        .frame(maxWidth: 500)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)

                    previewStage(height: min(max(proxy.size.height * 0.28, 220), 300))
                        .frame(maxWidth: 760)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)

                    editorPanel
                        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .top)
                        .padding(.top, -6)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationBarHidden(true)
        .safeAreaInset(edge: .bottom, spacing: 0) { saveArea }
        .onAppear {
            model.loadAppearanceCatalog()
            model.beginMorphEdit()
            syncPreviewAppearance()
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.38)) { appeared = true }
            }
        }
        .onChange(of: previewSelection) { _ in syncPreviewAppearance() }
        .onReceive(previewClock) { date in gameModel.tickMorphPreview(at: date) }
    }

    private var stageBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.08, green: 0.12, blue: 0.25), morphStageInk, Color(red: 0.07, green: 0.045, blue: 0.13)]
                    : [Color(red: 0.91, green: 0.94, blue: 1.00), Color(red: 0.80, green: 0.85, blue: 0.95), Color(red: 0.94, green: 0.93, blue: 0.99)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(morphAccent.opacity(0.24))
                .frame(width: 310, height: 310)
                .blur(radius: 76)
                .offset(x: 150, y: -220)
            Circle()
                .fill(Color(red: 0.95, green: 0.37, blue: 0.46).opacity(0.10))
                .frame(width: 250, height: 250)
                .blur(radius: 70)
                .offset(x: -170, y: 170)
        }
        .ignoresSafeArea()
    }

    private var editorHeader: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(stageTextColor.opacity(0.08), in: Circle())
                    .overlay { Circle().stroke(stageTextColor.opacity(0.14), lineWidth: 1) }
            }
            .buttonStyle(MorphPressButtonStyle())
            .accessibilityLabel("Back")

            VStack(spacing: 2) {
                Text("Edit Morph")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(previewName)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(stageTextColor.opacity(0.62))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            Color.clear.frame(width: 44, height: 44)
        }
        .foregroundStyle(stageTextColor)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : -8)
    }

    private var modePicker: some View {
        HStack(spacing: 4) {
            modeButton(title: "Starters", icon: "sparkles", value: 0)
            modeButton(title: "Customize", icon: "slider.horizontal.3", value: 1)
        }
        .padding(4)
        .background(stageTextColor.opacity(0.07), in: Capsule())
        .overlay { Capsule().stroke(stageTextColor.opacity(0.13), lineWidth: 1) }
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 8)
    }

    private func modeButton(title: String, icon: String, value: Int) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.20)) {
                tab = value
                if value == 1, selectedKind == nil { selectedKind = assetGroups.first?.id }
            }
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(tab == value ? Color.white : stageTextColor.opacity(0.68))
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(tab == value ? morphAccent : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: tab)
    }

    private func previewStage(height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.08), .white.opacity(0.025)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            stageScenery

            if let engine = gameModel.morphPreviewEngine {
                RustGameSurface(
                    engine: engine,
                    isActive: true,
                    avatarPreviewMode: true,
                    onMorphUploadComplete: { gameModel.recordMorphPreviewGPUUpload(seconds: $0) },
                    onMoveChanged: { gameModel.morphPreviewMoveChanged(to: $0) },
                    onMoveEnded: { gameModel.morphPreviewMoveEnded() },
                    onLookChanged: { gameModel.morphPreviewLookChanged(to: $0) },
                    onLookEnded: { gameModel.morphPreviewLookEnded() },
                    onZoomDelta: { gameModel.morphPreviewZoomChangedBy(delta: $0) },
                    onInteractionChanged: { canvasInteractionActive = $0 }
                )
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .transition(.opacity)
            } else {
                ZStack {
                    if let thumbnail = selectedPreviewThumbnailPath {
                        morphThumbnail(path: thumbnail, fallbackIndex: selectedPreviewPresetIndex)
                            .frame(maxHeight: 250)
                            .padding(.horizontal, 72)
                            .padding(.vertical, 18)
                            .opacity(0.86)
                    }
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("Building your morph…")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.78))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.38), in: Capsule())
                    }
                }
            }

            LinearGradient(
                colors: [.clear, morphStageInk.opacity(0.02), morphStageInk.opacity(0.48)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack {
                HStack {
                    Label("LIVE PREVIEW", systemImage: "sparkles")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(.black.opacity(0.28), in: Capsule())
                        .allowsHitTesting(false)
                    Spacer()
                    if let diagnostics = gameModel.morphPreviewDiagnostics {
                        morphDiagnosticsBadge(diagnostics)
                    }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    Text("Left: move · Right: orbit · Pinch: zoom")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .allowsHitTesting(false)
                    Spacer()
                    previewActions
                }
            }
            .padding(16)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.13), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.30), radius: 24, y: 14)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.97)
        .opacity(appeared || reduceMotion ? 1 : 0)
    }

    private func morphDiagnosticsBadge(_ diagnostics: MorphPreviewDiagnostics) -> some View {
        let status = diagnostics.errorMessage == nil
            ? (diagnostics.gpuSeconds == nil ? "…" : "✓")
            : "!"
        let gpu = diagnostics.gpuSeconds.map(formatPreviewSeconds) ?? "—"
        let cache = diagnostics.cacheHits > 0 ? " · cache \(diagnostics.cacheHits)" : ""
        return VStack(alignment: .trailing, spacing: 1) {
            Text("\(status) \(diagnostics.completedPacks)/\(diagnostics.totalPacks) packs · \(formatPreviewBytes(diagnostics.loadedBytes))\(cache)")
            Text("net \(formatPreviewBytes(diagnostics.networkBytes)) / \(formatPreviewSeconds(diagnostics.networkSeconds)) · gpu \(gpu)")
        }
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white.opacity(0.80))
        .multilineTextAlignment(.trailing)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityLabel("Morph preview loading diagnostics")
        .accessibilityValue("\(diagnostics.completedPacks) of \(diagnostics.totalPacks) packs, \(formatPreviewBytes(diagnostics.loadedBytes)), network \(formatPreviewSeconds(diagnostics.networkSeconds)), GPU \(gpu)")
    }

    private func formatPreviewBytes(_ bytes: Int) -> String {
        if bytes < 1_000_000 { return "\(max(0, bytes / 1_000)) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    private func formatPreviewSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.1fs", seconds)
    }

    private var stageScenery: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(morphAccent.opacity(0.18))
                .frame(width: 110, height: 180)
                .rotationEffect(.degrees(-8))
                .offset(x: 145, y: 46)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: 125, height: 120)
                .rotationEffect(.degrees(7))
                .offset(x: -145, y: 105)
            Circle()
                .fill(morphAccentBright.opacity(0.22))
                .frame(width: 170, height: 42)
                .blur(radius: 14)
                .offset(y: 150)
        }
        .allowsHitTesting(false)
    }

    private var previewActions: some View {
        HStack(spacing: 8) {
            previewAction("walk", icon: "figure.walk")
            previewAction("jump", icon: "figure.jumprope")
            previewAction("turn", icon: "arrow.clockwise")
        }
    }

    private func previewAction(_ action: String, icon: String) -> some View {
        Button { gameModel.playMorphPreview(action) } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.42), in: Circle())
                .overlay { Circle().stroke(.white.opacity(0.16), lineWidth: 1) }
        }
        .buttonStyle(MorphPressButtonStyle())
        .accessibilityLabel(action.capitalized)
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(.secondary.opacity(0.30))
                .frame(width: 42, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)

            categoryStrip
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if appearance.isLoading {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Loading morphs…")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 190)
                    } else if tab == 0 {
                        starterList
                    } else {
                        customizeList
                    }
                }
                .padding(.top, 16)

                if let feedback = appearance.feedback {
                    Label(
                        feedback.message,
                        systemImage: feedback.kind == .error ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
                    )
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(feedback.kind == .error ? Color.red : Color.green)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                }
            }
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.primary.opacity(colorScheme == .dark ? 0.10 : 0.04), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.20 : 0.10), radius: 22, y: -2)
        .offset(y: appeared || reduceMotion ? 0 : 18)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .allowsHitTesting(!canvasInteractionActive)
    }

    private var categoryStrip: some View {
        let page = clampedPage(categoryPage, itemCount: editorCategories.count, pageSize: categoryItemsPerPage)
        let categories = pageSlice(editorCategories, page: page, pageSize: categoryItemsPerPage)
        return HStack(spacing: 4) {
            pagerButton(
                icon: "chevron.left",
                label: "Previous categories",
                enabled: page > 0
            ) { categoryPage = page - 1 }

            HStack(spacing: 8) {
                ForEach(categories) { category in
                    categoryButton(
                        title: category.title,
                        icon: category.icon,
                        selected: category.kind == nil ? tab == 0 : tab == 1 && activeGroup?.id == category.kind
                    ) {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.20)) {
                            if let kind = category.kind {
                                tab = 1
                                selectedKind = kind
                                assetPage = 0
                            } else {
                                tab = 0
                            }
                        }
                    }
                }
            }

            pagerButton(
                icon: "chevron.right",
                label: "Next categories",
                enabled: page + 1 < pageCount(itemCount: editorCategories.count, pageSize: categoryItemsPerPage)
            ) { categoryPage = page + 1 }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }

    private func categoryButton(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.76))
                    .background(selected ? morphAccent : Color.secondary.opacity(0.10), in: Circle())
                Text(title)
                    .font(.system(size: 11, weight: selected ? .bold : .semibold, design: .rounded))
                    .foregroundStyle(selected ? morphAccent : Color.secondary)
                    .lineLimit(1)
            }
            .frame(width: 64)
            .frame(minHeight: 70)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: selected)
    }

    private var starterList: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: "Starters", detail: "Pick a base, then make it yours.")

            if appearance.presets.isEmpty {
                Text("No starter morphs are available right now.")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 120)
            } else {
                let indexedPresets = Array(appearance.presets.enumerated())
                let page = clampedPage(starterPage, itemCount: indexedPresets.count, pageSize: starterItemsPerPage)
                let presets = pageSlice(indexedPresets, page: page, pageSize: starterItemsPerPage)
                HStack(alignment: .center, spacing: 4) {
                    pagerButton(
                        icon: "chevron.left",
                        label: "Previous starters",
                        enabled: page > 0
                    ) { starterPage = page - 1 }

                    HStack(alignment: .top, spacing: 12) {
                        ForEach(presets, id: \.element.id) { index, preset in
                            starterTile(preset, index: index)
                        }
                    }
                    .padding(.vertical, 2)

                    pagerButton(
                        icon: "chevron.right",
                        label: "Next starters",
                        enabled: page + 1 < pageCount(itemCount: indexedPresets.count, pageSize: starterItemsPerPage)
                    ) { starterPage = page + 1 }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
            }
        }
    }

    private func starterTile(_ preset: AppRuntimeMorphPreset, index: Int) -> some View {
        let isSelected = preset.id == appearance.draftPresetId
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                model.chooseMorphPreset(preset.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.secondary.opacity(colorScheme == .dark ? 0.13 : 0.075))
                    morphThumbnail(path: preset.thumbnail, fallbackIndex: index)
                        .padding(.top, 10)
                        .padding(.horizontal, 8)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 27, height: 27)
                            .background(morphAccent, in: Circle())
                            .padding(8)
                    }
                }
                .frame(width: 132, height: 158)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isSelected ? morphAccent : Color.primary.opacity(0.06), lineWidth: isSelected ? 2.5 : 1)
                }

                Text(preset.displayName)
                    .font(.system(size: 14, weight: isSelected ? .bold : .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? morphAccent : Color.primary)
                    .lineLimit(1)
                    .frame(width: 132)
            }
        }
        .buttonStyle(MorphPressButtonStyle())
        .disabled(appearance.isSaving)
        .animation(.easeOut(duration: 0.18), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func morphThumbnail(path: String?, fallbackIndex: Int) -> some View {
        if let url = thumbnailURL(path) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else if phase.error != nil {
                    fallbackMorphImage(index: fallbackIndex)
                } else {
                    ProgressView().tint(morphAccent)
                }
            }
        } else {
            fallbackMorphImage(index: fallbackIndex)
        }
    }

    private func fallbackMorphImage(index: Int) -> some View {
        Image(["MorphNonbinary", "MorphBoy", "MorphGirl"][index % 3])
            .resizable()
            .scaledToFit()
    }

    @ViewBuilder
    private var customizeList: some View {
        if let group = activeGroup {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(title: categoryName(group.id), detail: "Choose the look that feels right.")

                let options = [MorphAssetOption(id: "none", asset: nil)]
                    + group.assets.map { MorphAssetOption(id: $0.id, asset: $0) }
                let page = clampedPage(assetPage, itemCount: options.count, pageSize: assetItemsPerPage)
                let visibleOptions = pageSlice(options, page: page, pageSize: assetItemsPerPage)
                HStack(alignment: .center, spacing: 4) {
                    pagerButton(
                        icon: "chevron.left",
                        label: "Previous \(categoryName(group.id)) options",
                        enabled: page > 0
                    ) { assetPage = page - 1 }

                    HStack(alignment: .top, spacing: 12) {
                        ForEach(visibleOptions) { option in
                            if let asset = option.asset {
                                assetTile(asset, kind: group.id)
                            } else {
                                noneTile(for: group)
                            }
                        }
                    }
                    .padding(.vertical, 2)

                    pagerButton(
                        icon: "chevron.right",
                        label: "Next \(categoryName(group.id)) options",
                        enabled: page + 1 < pageCount(itemCount: options.count, pageSize: assetItemsPerPage)
                    ) { assetPage = page + 1 }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
            }
        } else {
            Text("Customization options are unavailable right now.")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .frame(minHeight: 140)
        }
    }

    private func noneTile(for group: MorphAssetGroup) -> some View {
        let selected = selectedAssetID(for: group) == nil
        return Button {
            if let assetID = selectedAssetID(for: group) { model.clearMorphPart(assetID) }
        } label: {
            VStack(spacing: 9) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.secondary.opacity(colorScheme == .dark ? 0.13 : 0.075))
                    Image(systemName: "circle.slash")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.secondary)
                    if selected { selectedBadge }
                }
                .frame(width: 108, height: 116)
                .overlay { selectionOutline(selected, cornerRadius: 16) }
                Text("None")
                    .font(.system(size: 13, weight: selected ? .bold : .semibold, design: .rounded))
                    .foregroundStyle(selected ? morphAccent : Color.primary)
                    .lineLimit(1)
                    .frame(width: 108)
            }
        }
        .buttonStyle(MorphPressButtonStyle())
        .disabled(selected || appearance.isSaving)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func assetTile(_ asset: AppRuntimeMorphAsset, kind: String) -> some View {
        let selected = selectedAssetID(forKind: kind) == asset.id
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                model.setMorphPart(asset.id)
            }
        } label: {
            VStack(spacing: 9) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.secondary.opacity(colorScheme == .dark ? 0.13 : 0.075))
                    if let url = thumbnailURL(asset.thumbnail) {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFit()
                            } else if phase.error != nil {
                                assetFallback(kind: kind)
                            } else {
                                ProgressView().tint(morphAccent)
                            }
                        }
                        .padding(10)
                    } else {
                        assetFallback(kind: kind)
                    }
                    if selected { selectedBadge }
                }
                .frame(width: 108, height: 116)
                .overlay { selectionOutline(selected, cornerRadius: 16) }
                Text(asset.displayName)
                    .font(.system(size: 13, weight: selected ? .bold : .semibold, design: .rounded))
                    .foregroundStyle(selected ? morphAccent : Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 108, height: 34, alignment: .top)
            }
        }
        .buttonStyle(MorphPressButtonStyle())
        .disabled(appearance.isSaving)
        .animation(.easeOut(duration: 0.18), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var selectedBadge: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(morphAccent, in: Circle())
            .padding(7)
    }

    private func selectionOutline(_ selected: Bool, cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(selected ? morphAccent : Color.primary.opacity(0.06), lineWidth: selected ? 2.5 : 1)
    }

    private func assetFallback(kind: String) -> some View {
        Image(systemName: categoryIcon(kind))
            .font(.system(size: 30, weight: .light))
            .foregroundStyle(morphAccent.opacity(0.72))
    }

    private func sectionHeader(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
    }

    private func pagerButton(icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? Color.primary.opacity(0.78) : Color.secondary.opacity(0.28))
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(MorphPressButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func pageCount(itemCount: Int, pageSize: Int) -> Int {
        max((itemCount + pageSize - 1) / pageSize, 1)
    }

    private func clampedPage(_ page: Int, itemCount: Int, pageSize: Int) -> Int {
        min(max(page, 0), pageCount(itemCount: itemCount, pageSize: pageSize) - 1)
    }

    private func pageSlice<Element>(_ items: [Element], page: Int, pageSize: Int) -> [Element] {
        guard !items.isEmpty else { return [] }
        let safePage = clampedPage(page, itemCount: items.count, pageSize: pageSize)
        let start = safePage * pageSize
        let end = min(start + pageSize, items.count)
        return Array(items[start..<end])
    }

    private var saveArea: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.45)
            Button { model.saveMorph() } label: {
                HStack(spacing: 12) {
                    if appearance.isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.down.fill")
                            .font(.system(size: 18, weight: .bold))
                    }
                    Text(appearance.isSaving ? "Saving…" : "Save Morph")
                    Spacer()
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                }
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(
                    LinearGradient(colors: [morphAccent, morphAccentBright], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .shadow(color: morphAccent.opacity(0.24), radius: 16, y: 8)
            }
            .buttonStyle(MorphPressButtonStyle())
            .disabled(appearance.isSaving || !appearance.draftCanSave)
            .opacity(appearance.isSaving || !appearance.draftCanSave ? 0.52 : 1)
            .frame(maxWidth: 720)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.ultraThinMaterial)
    }

    private var previewName: String {
        appearance.presets.first { $0.id == appearance.draftPresetId }?.displayName ?? "Custom morph"
    }

    private func selectedAssetID(for group: MorphAssetGroup) -> String? {
        selectedAssetID(forKind: group.id)
    }

    private func selectedAssetID(forKind kind: String) -> String? {
        if kind == "face" { return appearance.draftFace }
        let ids = Set(appearance.draftParts)
        return assetGroups.first(where: { $0.id == kind })?.assets.first(where: { ids.contains($0.id) })?.id
    }

    private func thumbnailURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if let url = URL(string: path), url.scheme != nil { return url }
        return URL(string: path, relativeTo: ClientConfiguration.backendAPIURL)?.absoluteURL
    }

    private func categoryName(_ kind: String) -> String {
        switch kind.lowercased() {
        case "body", "body_type": return "Body"
        case "clothes", "clothing", "outfit": return "Clothing"
        case "hair", "hairstyle": return "Hair"
        case "face", "identity": return "Face"
        case "accessory", "accessories", "equipment": return "Accessories"
        default: return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func categoryIcon(_ kind: String) -> String {
        switch kind.lowercased() {
        case "body", "body_type": return "figure.stand"
        case "clothes", "clothing", "outfit": return "tshirt"
        case "hair", "hairstyle": return "comb"
        case "face", "identity": return "face.smiling"
        case "accessory", "accessories", "equipment": return "sunglasses"
        default: return "square.grid.2x2"
        }
    }

    private func categoryOrder(_ kind: String) -> String {
        switch kind.lowercased() {
        case "body", "body_type": return "0"
        case "clothes", "clothing", "outfit": return "1"
        case "hair", "hairstyle": return "2"
        case "face", "identity": return "3"
        case "accessory", "accessories", "equipment": return "4"
        default: return "9-\(kind)"
        }
    }

    private func syncPreviewAppearance() {
        guard let base = appearance.draftBase,
              let source = appearance.draftLoadoutJson else { return }
        let ids = [base] + appearance.draftParts + (appearance.draftFace.map { [$0] } ?? [])
        var urls: [URL] = []
        for id in ids {
            guard let asset = appearance.assets.first(where: { $0.id == id }) else {
                gameLog.error("Morph preview catalog is missing asset \(id, privacy: .public)")
                return
            }
            if asset.kind == "face" { continue }
            guard let path = asset.artifactURL,
                  let url = URL(string: path, relativeTo: ClientConfiguration.backendAPIURL)?.absoluteURL else {
                gameLog.error("Morph asset \(id, privacy: .public) has no schema-5 artifact")
                return
            }
            urls.append(url)
        }
        gameModel.updateMorphPreview(
            source: source,
            packURLs: urls,
            catalogRelease: appearance.release
        )
    }

}

private struct MorphPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
