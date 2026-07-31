import SwiftUI

struct BoardChatView: View {
    @StateObject private var model = BoardChatViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            boardBar
            if model.isSeat {
                ChatView()
            } else {
                BoardThreadView(model: model)
            }
        }
        .task { await model.load() }
        .onDisappear { model.stopPolling() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.foreground() } }
            else { model.stopPolling() }
        }
    }

    private var boardBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(model.boards) { board in
                    Button {
                        model.select(board)
                    } label: {
                        if board.boardID == model.selectedBoard?.boardID {
                            Label(board.title, systemImage: "checkmark")
                        } else {
                            Text(board.title)
                        }
                    }
                }
            } label: {
                Label(model.selectedBoard?.title ?? "Ruminate", systemImage: "chevron.up.chevron.down")
                    .font(.headline)
            }
            Spacer()
            if model.boardListIsStale {
                Label("Stale", systemImage: "wifi.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button { Task { await model.refreshBoards() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Refresh boards")
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(.bar)
    }
}

private struct BoardThreadView: View {
    @ObservedObject var model: BoardChatViewModel
    @ObservedObject private var thread: BoardThreadController
    @FocusState private var focused: Bool

    init(model: BoardChatViewModel) {
        self.model = model
        thread = model.thread
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("History mode", selection: $model.mode) {
                Text("Conversation").tag(BoardHistoryMode.conversation)
                Text("Full ledger").tag(BoardHistoryMode.full)
            }
            .pickerStyle(.segmented)
            .padding()
            .onChange(of: model.mode) { _, _ in model.restartPolling() }

            ScrollView {
                LazyVStack(spacing: 10) {
                    if model.mode == .conversation {
                        ForEach(thread.asks) { ask in
                            BoardAskBubble(ask: ask, retry: { model.retry(ask) })
                        }
                        ForEach(thread.rows) { row in
                            if row.replyTo != nil {
                                let voiceAnswer = thread.asks.first {
                                    $0.voiceTurnID != nil
                                        && $0.claimID == row.replyTo
                                        && $0.state == .answered
                                }
                                BoardReplyBubble(
                                    row: row,
                                    canSpeak: voiceAnswer != nil,
                                    speak: { model.speak(row) }
                                )
                            }
                        }
                    } else {
                        ForEach(thread.rows) { row in
                            LedgerRow(row: row)
                        }
                    }
                }
                .padding()
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button { model.captureDraft() } label: {
                    Image(systemName: model.isCapturing ? "stop.circle.fill" : "mic.fill")
                }
                TextField("Message \(model.selectedBoard?.title ?? "board")", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...5).focused($focused)
                Button { focused = false; model.sendDraft() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(!model.canSend)
            }
            .padding().background(.bar)
        }
    }
}

private struct BoardAskBubble: View {
    let ask: OutgoingBoardAsk
    let retry: () -> Void
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack { Spacer(minLength: 52); Text(ask.text).padding(12).background(Color.accentColor).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 16)) }
            switch ask.state {
            case .delivered:
                Text(BoardDeliveryCopy.posted).font(.caption).foregroundStyle(.secondary)
            case .posted:
                Text(BoardDeliveryCopy.posted).font(.caption).foregroundStyle(.secondary)
            case .wakeReceipted:
                Label("HELM wake receipted", systemImage: "bell.badge")
                    .font(.caption).foregroundStyle(.secondary)
            case .answered:
                Label("Answered", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .expired:
                Text("Expired — no HELM answer within five minutes")
                    .font(.caption).foregroundStyle(.orange)
            case .queued:
                Label("Queued", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
            case .sending:
                ProgressView().controlSize(.small)
            case .failed, .failedAuth:
                Button("Retry", action: retry).font(.caption).foregroundStyle(.red)
            case .ambiguous:
                Text("Delivery ambiguous — check the ledger before retrying").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

private struct BoardReplyBubble: View {
    let row: BoardJournalRow
    let canSpeak: Bool
    let speak: () -> Void
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.text)
                if canSpeak {
                    Button(action: speak) {
                        Label("Speak", systemImage: "speaker.wave.2.fill")
                            .font(.caption)
                    }
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 52)
        }
    }
}

private struct LedgerRow: View {
    let row: BoardJournalRow
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(row.author).font(.caption.bold()); Text(row.kind).font(.caption).foregroundStyle(.secondary); Spacer(); Text("#\(row.ord)").font(.caption.monospacedDigit()) }
            Text(row.text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10).background(Color(.tertiarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor
final class BoardChatViewModel: ObservableObject {
    @Published private(set) var boards: [BoardSummary] = []
    @Published private(set) var selectedBoard: BoardSummary?
    @Published private(set) var asks: [OutgoingBoardAsk] = []
    @Published private(set) var boardListIsStale = false
    @Published var mode: BoardHistoryMode = .conversation
    @Published var draft = ""
    @Published private(set) var isCapturing = false

    let thread = BoardThreadController()
    private let config = RuminateConfig.shared
    private let defaults = UserDefaults.standard
    private let selectionKey = "ruminateSelectedBoard"
    private let cacheKey = "ruminateBoardList"
    private let directory: URL
    private var stores: [BoardID: BoardStore] = [:]
    private var draftIsVoice = false
    private lazy var speechReader = SpeechReader()

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Ruminate/boards")
        if let data = defaults.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode([BoardSummary].self, from: data) {
            boards = cached
            restoreSelection()
        }
    }

    var isSeat: Bool { selectedBoard?.lane != .board }
    var canSend: Bool { !isSeat && config.isConfigured && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func load() async {
        await refreshBoards()
        await flushAll()
        restartPolling()
    }

    func foreground() async {
        await refreshBoards()
        await flushAll()
        restartPolling()
    }

    func refreshBoards() async {
        guard let client = makeClient() else { return }
        do {
            let response = try await client.fetchBoards()
            boards = response.boards
            boardListIsStale = false
            if let data = try? JSONEncoder().encode(boards) { defaults.set(data, forKey: cacheKey) }
            restoreSelection()
        } catch {
            boardListIsStale = !boards.isEmpty
        }
    }

    func select(_ board: BoardSummary) {
        selectedBoard = board
        defaults.set(board.boardID.rawValue, forKey: selectionKey)
        mode = .conversation
        restartPolling()
    }

    func restartPolling() {
        thread.stop()
        guard let board = selectedBoard, board.lane == .board, let client = makeClient(),
              let store = try? store(for: board.boardID) else { return }
        Task { asks = await store.asks() }
        thread.start(boardID: board.boardID, mode: mode, store: store, client: client)
    }

    func stopPolling() { thread.stop() }

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let board = selectedBoard, board.lane == .board, !text.isEmpty,
              let client = makeClient(), let store = try? store(for: board.boardID) else { return }
        draft = ""
        let voice = draftIsVoice
        draftIsVoice = false
        Task {
            _ = try await store.enqueue(text: text, voice: voice)
            asks = await store.asks()
            await BoardDeliveryActor(store: store, client: client).flush()
            asks = await store.asks()
            await thread.refreshNow()
        }
    }

    func retry(_ ask: OutgoingBoardAsk) {
        guard let client = makeClient(), let store = stores[ask.boardID] else { return }
        Task {
            try? await store.updateAsk(id: ask.id) { $0.state = .queued; $0.errorMessage = nil }
            await BoardDeliveryActor(store: store, client: client).flush()
            asks = await store.asks()
        }
    }

    func captureDraft() {
        if isCapturing { TranscriptionService.shared.stopCapture(owner: .chat); return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            if let result = try? await TranscriptionService.shared.recordAndTranscribe(owner: .chat) {
                draft = result.text
                draftIsVoice = true
            }
        }
    }

    func speak(_ row: BoardJournalRow) {
        _ = speechReader.speak(text: row.text, turnId: row.claimID)
    }

    private func restoreSelection() {
        let persisted = defaults.string(forKey: selectionKey)
        selectedBoard = boards.first { $0.boardID.rawValue == persisted }
            ?? boards.first { $0.lane == .seat }
        if let selectedBoard { defaults.set(selectedBoard.boardID.rawValue, forKey: selectionKey) }
    }

    private func store(for boardID: BoardID) throws -> BoardStore {
        if let existing = stores[boardID] { return existing }
        let created = try BoardStore(boardID: boardID, directory: directory)
        stores[boardID] = created
        return created
    }

    private func makeClient() -> BoardClient? {
        guard let url = config.normalizedBaseURL else { return nil }
        return BoardClient(baseURL: url, tokenProvider: { try? KeychainStore().get(key: RuminateConfig.tokenKey) })
    }

    private func flushAll() async {
        guard let url = config.normalizedBaseURL else { return }
        let coordinator = BoardDeliveryCoordinator(directory: directory) { _ in
            BoardClient(baseURL: url, tokenProvider: { try? KeychainStore().get(key: RuminateConfig.tokenKey) })
        }
        for store in stores.values { await coordinator.register(store: store) }
        await coordinator.discoverAndFlush()
        if let board = selectedBoard, let store = try? store(for: board.boardID) { asks = await store.asks() }
    }
}
