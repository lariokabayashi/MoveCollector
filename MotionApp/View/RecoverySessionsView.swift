//
//  RecoverySessionsView.swift
//  MotionApp
//
//  Tela de recuperação de coletas persistidas. Mesmo quando o BGTask é
//  terminado pelo sistema no meio de uma coleta longa, as amostras já estão
//  no Core Data (SensorReading + LocationEntity). Esta tela lista todas as
//  sessões persistidas e permite, para cada uma:
//    - Exportar o CSV (exportSession).
//    - Recomputar os episódios a partir do disco (clusterStoreDetached) —
//      reconstrói as janelas e roda o mesmo pipeline da coleta ao vivo.
//    - Abrir o mapa de episódios e o gráfico de sensores combinados.
//    - Apagar a sessão.
//
//  Também permite UPLOAD de um CSV externo (mesmo formato do exportSession):
//  o arquivo é validado e re-hidratado como uma nova sessão persistida, então
//  passa a suportar exatamente o mesmo fluxo (computar episódios, mapa, gráfico,
//  exportar) das coletas nativas. Estados cobertos: loading, vazio, importando,
//  sucesso (push automático para o detalhe) e erro (alerta).
//

import SwiftUI
import UniformTypeIdentifiers

@available(iOS 26.0, *)
struct RecoverySessionsView: View {
    @ObservedObject var sensorManager: SensorManagerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var sessions: [SensorManagerViewModel.SessionSummary] = []
    @State private var isLoading = true

    // Pilha de navegação por VALOR: tanto as linhas da lista quanto o push
    // automático pós-upload usam o mesmo destino (`navigationDestination(for:)`),
    // então conseguimos abrir o detalhe da sessão recém-importada sem duplicar a
    // tela nem perder a sincronização com a lista.
    @State private var path: [SensorManagerViewModel.SessionSummary] = []

    // Estado do fluxo de upload.
    @State private var showImporter = false
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground.ignoresSafeArea())
                .navigationTitle("Recuperar coletas")
                .navigationDestination(for: SensorManagerViewModel.SessionSummary.self) { s in
                    RecoverySessionDetailView(sensorManager: sensorManager, summary: s)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Fechar") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showImporter = true } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .disabled(isImporting)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                            .disabled(isLoading || isImporting)
                    }
                }
                .overlay { if isImporting { importingOverlay } }
                .fileImporter(
                    isPresented: $showImporter,
                    allowedContentTypes: [.commaSeparatedText, .plainText, .text],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        if let url = urls.first { startImport(url) }
                    case .failure(let err):
                        importError = err.localizedDescription
                    }
                }
                .alert(
                    "Falha no upload",
                    isPresented: Binding(
                        get: { importError != nil },
                        set: { if !$0 { importError = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) { importError = nil }
                } message: {
                    Text(importError ?? "")
                }
                .task { reload() }
        }
    }

    // MARK: - Estados (loading / empty / success)
    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Procurando coletas no disco…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sessions.isEmpty {
            ContentUnavailableView {
                Label("Nenhuma coleta persistida", systemImage: "tray")
            } description: {
                Text("Coletas aparecem aqui assim que dados são gravados, mesmo que a "
                     + "task tenha sido interrompida. Você também pode fazer upload de um "
                     + "CSV exportado anteriormente.")
            } actions: {
                Button { showImporter = true } label: {
                    Label("Fazer upload de CSV", systemImage: "square.and.arrow.down")
                        .foregroundStyle(Color.onAccent)
                }
                .buttonStyle(.borderedProminent)
                .tint(.brandLime)
                .disabled(isImporting)
            }
        } else {
            List {
                Section {
                    ForEach(sessions) { s in
                        NavigationLink(value: s) { row(for: s) }
                    }
                    .listRowBackground(Color.cardSurface)
                } footer: {
                    Text("Toque numa coleta para computar episódios, ver no mapa, "
                         + "abrir o gráfico de sensores ou exportar.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground.ignoresSafeArea())
        }
    }

    private var importingOverlay: some View {
        ZStack {
            Color(.systemBackground).opacity(0.75).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Importando coleta…")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private func row(for s: SensorManagerViewModel.SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(RecoveryFormat.dayTime(s.startDate))
                    .font(.subheadline).bold()
                Spacer()
                if s.isExported {
                    Label("CSV", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(Color.brandGreen)
                }
            }
            Text("\(RecoveryFormat.duration(s.durationSec)) · \(s.rowCount) amostras")
                .font(.caption).foregroundStyle(.secondary)
            Text(s.id.uuidString.prefix(8) + "…")
                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        isLoading = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                sensorManager.allPersistedSessions()
            }.value
            await MainActor.run {
                self.sessions = result
                self.isLoading = false
            }
        }
    }

    /// Importa o CSV escolhido como uma nova sessão e, ao concluir, recarrega a
    /// lista e abre direto o detalhe — onde o usuário computa episódios e abre as
    /// visualizações. Mantém a UI responsiva: o trabalho roda fora da main thread
    /// e um overlay sinaliza o progresso.
    private func startImport(_ url: URL) {
        isImporting = true
        Task {
            do {
                let summary = try await sensorManager.importSession(from: url)
                await MainActor.run {
                    isImporting = false
                    reload()
                    path.append(summary)
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    importError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Detalhe / ações de uma sessão

@available(iOS 26.0, *)
struct RecoverySessionDetailView: View {
    @ObservedObject var sensorManager: SensorManagerViewModel
    let summary: SensorManagerViewModel.SessionSummary

    @Environment(\.dismiss) private var dismiss

    @State private var targetEpisodes = 10
    @State private var csvURL: URL?
    @State private var isComputing = false
    @State private var episodesReady = false

    @State private var mapPoints: [EpisodePoint] = []
    @State private var groupSeries: [SensorGroupSeries] = []
    @State private var showMap = false
    @State private var showChart = false
    @State private var isLoadingViz = false

    /// Episódios desta coleta de recuperação/upload — guardados LOCALMENTE, fora
    /// do estado compartilhado do SensorManager. Assim a tela de upload não
    /// sobrescreve a coleta atual da home (e vice-versa).
    @State private var recoveredEpisodes: [Episode] = []

    private var maxK: Int {
        // 1 janela ≈ 15 s; estimativa de janelas a partir da duração.
        let approxWindows = max(2, Int(summary.durationSec / 15))
        return min(30, approxWindows)
    }

    var body: some View {
        Form {
            Section("Coleta") {
                LabeledContent("Início", value: RecoveryFormat.dayTime(summary.startDate))
                LabeledContent("Fim", value: RecoveryFormat.dayTime(summary.endDate))
                LabeledContent("Duração", value: RecoveryFormat.duration(summary.durationSec))
                LabeledContent("Amostras", value: "\(summary.rowCount)")
                LabeledContent("Exportada", value: summary.isExported ? "Sim" : "Não")
            }

            Section("Episódios") {
                Stepper(value: $targetEpisodes, in: 2...max(2, maxK)) {
                    Text("Episódios alvo (K): \(targetEpisodes)")
                        .font(.subheadline)
                }
                Button {
                    computeEpisodes()
                } label: {
                    HStack {
                        if isComputing { ProgressView().controlSize(.small) }
                        Label("Computar episódios", systemImage: "wand.and.stars")
                    }
                }
                .disabled(isComputing)

                if !sensorManager.mlStatusMessage.isEmpty {
                    Text(sensorManager.mlStatusMessage)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if episodesReady {
                    Text("\(recoveredEpisodes.count) episódios prontos")
                        .font(.caption).foregroundStyle(Color.brandGreen)
                }
            }

            Section("Visualizar") {
                Button {
                    openMap()
                } label: {
                    HStack {
                        if isLoadingViz { ProgressView().controlSize(.small) }
                        Label("Abrir mapa de episódios", systemImage: "map")
                    }
                }
                .disabled(!episodesReady || isLoadingViz)

                Button {
                    openChart()
                } label: {
                    Label("Abrir gráfico de sensores", systemImage: "chart.xyaxis.line")
                }
                .disabled(!episodesReady || isLoadingViz)
            }

            Section("Exportar / apagar") {
                Button {
                    csvURL = sensorManager.exportSession(summary.id)
                } label: {
                    Label("Gerar CSV", systemImage: "doc.text")
                }
                if let url = csvURL {
                    ShareLink(item: url) {
                        Label(url.lastPathComponent, systemImage: "square.and.arrow.up")
                            .font(.caption)
                    }
                }
                Button(role: .destructive) {
                    sensorManager.deleteSession(summary.id)
                    dismiss()
                } label: {
                    Label("Apagar coleta", systemImage: "trash")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Coleta \(summary.id.uuidString.prefix(6))")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { targetEpisodes = min(targetEpisodes, max(2, maxK)) }
        .sheet(isPresented: $showMap) {
            EpisodesMapView(points: mapPoints)
        }
        .sheet(isPresented: $showChart) {
            CombinedSensorsChartView(
                groupSeries: groupSeries,
                episodes: recoveredEpisodes,
                displayTimezone: TimeZone.current
            )
            .padding()
        }
    }

    private func computeEpisodes() {
        isComputing = true
        episodesReady = false
        sensorManager.clusterStoreDetached(sessionId: summary.id, t: targetEpisodes) { episodes, _ in
            recoveredEpisodes = episodes
            isComputing = false
            episodesReady = !episodes.isEmpty
        }
    }

    private func openMap() {
        isLoadingViz = true
        Task {
            let pts = await sensorManager.gatherEpisodePoints(
                forSession: summary.id, episodes: recoveredEpisodes)
            await MainActor.run {
                self.mapPoints = pts
                self.isLoadingViz = false
                self.showMap = !pts.isEmpty
            }
        }
    }

    private func openChart() {
        isLoadingViz = true
        Task {
            let series = await sensorManager.populateGroupSeries(forSession: summary.id)
            await MainActor.run {
                self.groupSeries = series
                self.isLoadingViz = false
                self.showChart = !series.isEmpty
            }
        }
    }
}

// MARK: - Formatação

enum RecoveryFormat {
    static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm"
        f.timeZone = .current
        return f
    }()

    static func dayTime(_ date: Date) -> String { dayTimeFormatter.string(from: date) }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)min" }
        if m > 0 { return "\(m)min \(s)s" }
        return "\(s)s"
    }
}


