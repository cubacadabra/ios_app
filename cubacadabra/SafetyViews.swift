import SwiftUI
struct PresenceNoticeView: View {
    let notice: PresenceNotice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.joined ? "person.badge.plus" : "person.badge.minus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(notice.joined ? Color.green : Color.orange)
            Text(notice.message)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.primary.opacity(0.12), lineWidth: 1))
        .frame(maxWidth: 390)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(notice.message)
    }
}

struct ModerationNoticeView: View {
    let notice: ModerationNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.green)
            Text(notice.message)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss safety message")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.primary.opacity(0.12), lineWidth: 1))
        .frame(maxWidth: 430)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

struct SafetyCenterView: View {
    let model: GameViewModel
    @State private var activePlayers: [RemotePlayerSummary]
    @State private var blockedPlayerIDs: Set<String>
    @State private var reportTarget: RemotePlayerSummary?
    @State private var blockTarget: RemotePlayerSummary?

    init(model: GameViewModel) {
        self.model = model
        _activePlayers = State(initialValue: model.activeRemotePlayers)
        _blockedPlayerIDs = State(initialValue: model.blockedPlayerIDs)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Use Players & Safety to report a concern, block another player, or manage people you have blocked. Reports are reviewed by the Cubacadabra team.")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Community safety")
                }

                Section("Players here") {
                    if activePlayers.isEmpty {
                        Text("No other players are visible right now.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(activePlayers) { player in
                            PlayerSafetyRow(player: player) {
                                reportTarget = player
                            } block: {
                                blockTarget = player
                            }
                        }
                    }
                }

                Section("Blocked on this device") {
                    if blockedPlayerIDs.isEmpty {
                        Text("No blocked players.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(blockedPlayerIDs.sorted(), id: \.self) { playerID in
                            HStack(spacing: 12) {
                                Image(systemName: "hand.raised.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28)
                                Text("Player \(String(playerID.suffix(4)).uppercased())")
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                                Spacer()
                                Button("Unblock") {
                                    model.unblockPlayer(playerID)
                                }
                                .buttonStyle(.bordered)
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }

                Section("Legal and support") {
                    Link(destination: AppLinks.privacy) {
                        Label("Privacy Policy", systemImage: "lock.shield.fill")
                    }
                    Link(destination: AppLinks.terms) {
                        Label("Terms of Use", systemImage: "doc.text.fill")
                    }
                    Link(destination: AppLinks.support) {
                        Label("Contact support", systemImage: "envelope.fill")
                    }
                }
            }
            .navigationTitle("Players & Safety")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(
                isPresented: Binding(
                    get: { reportTarget != nil },
                    set: { if !$0 { reportTarget = nil } }
                )
            ) {
                if let player = reportTarget {
                    ReportPlayerView(player: player) { reason, details in
                        model.reportPlayer(player, reason: reason, details: details)
                    }
                }
            }
            .confirmationDialog(
                "Block \(blockTarget?.username ?? "this player")?",
                isPresented: Binding(
                    get: { blockTarget != nil },
                    set: { if !$0 { blockTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Block", role: .destructive) {
                    if let blockTarget {
                        model.blockPlayer(blockTarget)
                    }
                    blockTarget = nil
                }
                Button("Cancel", role: .cancel) { blockTarget = nil }
            } message: {
                Text("You will no longer see this player or their presence. You can unblock them later.")
            }
        }
        .onReceive(model.$remotePlayerNames) { _ in
            activePlayers = model.activeRemotePlayers
        }
        .onReceive(model.$blockedPlayerIDs) { playerIDs in
            blockedPlayerIDs = playerIDs
            activePlayers = model.activeRemotePlayers
        }
    }
}

private struct PlayerSafetyRow: View {
    let player: RemotePlayerSummary
    let report: () -> Void
    let block: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.fill")
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.username)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                Text("In this world")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Report player", systemImage: "exclamationmark.bubble") { report() }
                Button("Block player", systemImage: "hand.raised.fill", role: .destructive) { block() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Actions for \(player.username)")
        }
        .frame(minHeight: 52)
    }
}

private struct ReportPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    let player: RemotePlayerSummary
    let report: (ReportReason, String) -> Void
    @State private var reason: ReportReason = .inappropriateName
    @State private var details = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Report \(player.username)")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                    Text("Tell us what happened. Do not include private information.")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Section("Reason") {
                    Picker("Reason", selection: $reason) {
                        ForEach(ReportReason.allCases) { reason in
                            Text(reason.title).tag(reason)
                        }
                    }
                }

                Section("Details (optional)") {
                    TextEditor(text: $details)
                        .frame(minHeight: 88)
                        .overlay(alignment: .topLeading) {
                            if details.isEmpty {
                                Text("What should we review?")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .textInputAutocapitalization(.sentences)
                }

                Section {
                    Button("Send Report") {
                        report(reason, details)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Report Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
