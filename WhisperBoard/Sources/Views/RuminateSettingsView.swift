import SwiftUI

struct SettingsView: View {
    @StateObject private var model = RuminateSettingsViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Ruminate Connection") {
                    TextField("Funnel URL", text: $model.config.baseURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if model.config.warnsOnHostChange {
                        Label("This host differs from the expected Funnel. Verify it before entering a token.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    SecureField("Bearer token", text: $model.tokenDraft)
                    Button("Save token") { model.saveToken() }
                    Toggle("Read new replies aloud", isOn: $model.autoRead)
                }

                Section("Status") {
                    HStack {
                        Circle().fill(model.health.color).frame(width: 9, height: 9)
                        Text(model.health.label)
                        Spacer()
                        if let checked = model.lastChecked { Text(checked, style: .time).font(.caption).foregroundStyle(.secondary) }
                    }
                    Button("Check connection") { Task { await model.checkHealth() } }
                    Button("Refresh seat", role: .destructive) { model.confirmRefresh = true }
                }

                Section("WhisperBoard") {
                    NavigationLink("Model and keyboard settings") { WhisperSettingsView() }
                }
            }
            .navigationTitle("Settings")
            .task { await model.checkHealth() }
            .confirmationDialog("Refresh the RUMINATE seat? Conversation history is preserved.", isPresented: $model.confirmRefresh) {
                Button("Refresh seat", role: .destructive) { Task { await model.refresh() } }
            }
            .alert("Settings error", isPresented: $model.showingError) { Button("OK", role: .cancel) {} } message: { Text(model.errorMessage) }
        }
    }
}

@MainActor
final class RuminateSettingsViewModel: ObservableObject {
    enum HealthState {
        case unconfigured, checking, unauthorized, networkUnavailable, bridgeUpSeatDown, reseeding, ready
        var label: String {
            switch self {
            case .unconfigured: return "Not configured"
            case .checking: return "Checking..."
            case .unauthorized: return "Token rejected"
            case .networkUnavailable: return "Network unavailable"
            case .bridgeUpSeatDown: return "Bridge up, seat down"
            case .reseeding: return "Seat reseeding"
            case .ready: return "Ready"
            }
        }
        var color: Color {
            switch self { case .ready: return .green; case .checking, .reseeding: return .orange; default: return .red }
        }
    }

    let config = RuminateConfig.shared
    @Published var tokenDraft: String
    @Published var autoRead = UserDefaults.standard.bool(forKey: "ruminateAutoRead") {
        didSet { UserDefaults.standard.set(autoRead, forKey: "ruminateAutoRead") }
    }
    @Published var health: HealthState = .unconfigured
    @Published var lastChecked: Date?
    @Published var confirmRefresh = false
    @Published var showingError = false
    @Published var errorMessage = ""

    init() { tokenDraft = RuminateConfig.shared.token }

    func saveToken() {
        do { try config.saveToken(tokenDraft); health = .unconfigured }
        catch { present(error) }
    }

    func checkHealth() async {
        guard let client = client() else { health = .unconfigured; return }
        health = .checking
        do {
            let result = try await client.health()
            if result.seat == "reseeding" { health = .reseeding }
            else if result.ok && result.seat == "up" { health = .ready }
            else { health = .bridgeUpSeatDown }
            lastChecked = Date()
        } catch RuminateError.unauthorized { health = .unauthorized; lastChecked = Date() }
        catch { health = .networkUnavailable; lastChecked = Date() }
    }

    func refresh() async {
        guard let client = client() else { health = .unconfigured; return }
        do { try await client.refresh(); health = .reseeding; lastChecked = Date() }
        catch { present(error) }
    }

    private func client() -> RuminateClient? {
        guard config.isConfigured, let url = config.normalizedBaseURL else { return nil }
        return RuminateClient(baseURL: url, tokenProvider: { try? KeychainStore().get(key: RuminateConfig.tokenKey) })
    }

    private func present(_ error: Error) { errorMessage = error.localizedDescription; showingError = true }
}
