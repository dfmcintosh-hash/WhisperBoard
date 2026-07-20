import SwiftUI

struct ChatView: View {
    @StateObject private var model = ChatViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !model.config.isConfigured {
                    Label("Set up the Funnel URL and token in Settings", systemImage: "gearshape.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding()
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(model.turns) { turn in
                                TurnBubble(turn: turn, retry: { model.retry(turn) })
                                    .id(turn.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: model.turns.count) { _, _ in
                        if let id = model.turns.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }

                HStack(alignment: .bottom, spacing: 10) {
                    Button { model.captureDraft() } label: {
                        Image(systemName: "mic.fill").font(.title3)
                    }
                    .disabled(!model.config.isConfigured)

                    TextField("Message RUMINATE", text: $model.draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)

                    Button { model.sendDraft() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(!model.canSend)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Ruminate")
            .task { await model.load() }
            .alert("Ruminate", isPresented: $model.showingError) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.errorMessage) }
        }
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var draft = ""
    @Published private(set) var turns: [LocalTurn] = []
    @Published var showingError = false
    @Published var errorMessage = ""

    let config = RuminateConfig.shared
    private let store: ChatStore
    private var delivery: DeliveryActor?
    private var deliveryURL: URL?

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.store = try! ChatStore(fileURL: directory.appendingPathComponent("Ruminate/turns.json"))
    }

    var canSend: Bool { config.isConfigured && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func load() async {
        try? await store.demoteStaleSending()
        turns = await store.turns()
        await ensureDelivery()?.reconcile()
        turns = await store.turns()
    }

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task {
            do {
                _ = try await store.append(text: text)
                turns = await store.turns()
                await ensureDelivery()?.kick()
                await monitorUpdates()
            } catch { present(error) }
        }
    }

    func retry(_ turn: LocalTurn) {
        Task {
            do {
                try await store.update(turn.id) { $0.state = .queued; $0.errorMessage = nil }
                await ensureDelivery()?.kick()
                await monitorUpdates()
            } catch { present(error) }
        }
    }

    func captureDraft() {
        errorMessage = "Voice capture is being connected in the next build step."
        showingError = true
    }

    private func ensureDelivery() -> DeliveryActor? {
        guard let url = config.normalizedBaseURL else { return nil }
        if delivery == nil || deliveryURL != url {
            let client = RuminateClient(baseURL: url, tokenProvider: {
                try? KeychainStore().get(key: RuminateConfig.tokenKey)
            })
            delivery = DeliveryActor(store: store, client: client)
            deliveryURL = url
        }
        return delivery
    }

    private func monitorUpdates() async {
        for _ in 0..<25 {
            turns = await store.turns()
            if !turns.contains(where: { $0.state == .sending || $0.state == .accepted }) { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showingError = true
    }
}

private struct TurnBubble: View {
    let turn: LocalTurn
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            bubble(turn.text, outgoing: true)
            if let reply = turn.reply { bubble(reply, outgoing: false) }
            stateRow
        }
    }

    private func bubble(_ text: String, outgoing: Bool) -> some View {
        HStack {
            if outgoing { Spacer(minLength: 52) }
            Text(text)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(outgoing ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(outgoing ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            if !outgoing { Spacer(minLength: 52) }
        }
    }

    @ViewBuilder private var stateRow: some View {
        switch turn.state {
        case .queued:
            Label("Offline - queued", systemImage: "icloud.slash").font(.caption).foregroundStyle(.secondary)
        case .sending, .accepted:
            HStack { ProgressView().controlSize(.small); Text("Still working...").font(.caption) }
        case .failed, .failedAuth:
            Button(action: retry) { Label(turn.state == .failedAuth ? "Token?" : "Retry", systemImage: "exclamationmark.circle") }
                .font(.caption).foregroundStyle(.red)
        case .indeterminate:
            Text("May or may not have landed - check history before resending")
                .font(.caption).foregroundStyle(.orange)
        case .complete:
            EmptyView()
        }
    }
}

#Preview { ChatView() }
