import SwiftUI
import CoreData
import CoreMotion
import UniformTypeIdentifiers

@available(iOS 26.0, *)
struct ContentView: View {
    @ObservedObject var sensorManager: SensorManagerViewModel
    @Environment(\.managedObjectContext) private var context
    @StateObject private var labelStore = EpisodeLabelStore()

    /// Onboarding "How to use this app" — exibido só no primeiro uso.
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false
    @State private var csvURL: URL?
    @State private var combinedCSVURL: URL?  // Novo: URL para CSV combinado

    /// Início da coleta atual. Reiniciado a cada "Iniciar coleta".
    @State private var startTime = Date()
    /// Instante em que a coleta foi parada. Enquanto não-nil, congela o contador
    /// de Duração no valor final; volta a nil ao iniciar uma nova coleta.
    @State private var stopTime: Date?
    private let appConstants = AppConstants()
    private let utils = Utils()

    /// Duração exibida: ao vivo enquanto grava, congelada após parar, 0 antes da
    /// 1ª coleta. Deriva de `sensorManager.isRecording` (fonte única de verdade),
    /// então fica correta mesmo quando o sistema encerra a coleta sozinho.
    private var collectionDuration: TimeInterval {
        if sensorManager.isRecording { return Date().timeIntervalSince(startTime) }
        if let stopTime { return stopTime.timeIntervalSince(startTime) }
        return 0
    }
    
    // Default K = 10. O Stepper em SegmentationCardView clampa automaticamente
    // ao range válido [2, min(W, 30)] sempre que `windowCount` mudar.
    @State private var targetEpisodes = 10
    
    /// Tela de recuperação de coletas persistidas (ex.: após BGTask terminado).
    @State private var showRecovery = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Top metrics
                    HStack(spacing: 12) {
                        MetricCard(title: "Duração", value: "\(String(format: "%.2f", collectionDuration)) s")
                            .accessibilityIdentifier("DurationTimerLabel")
                        MetricCard(title: "Bateria", value: "\(Int(sensorManager.batteryLevel * 100))%")
                    }
                    
                    // Sensors
                    SensorCard(title: "Acelerômetro", unit: "m/s²", x: sensorManager.accelX, y: sensorManager.accelY, z: sensorManager.accelZ)
                        .accessibilityIdentifier("AccelXLabel")
                    
                    SensorCard(title: "Giroscópio", unit: "rad/s", x: sensorManager.gyroX, y: sensorManager.gyroY, z: sensorManager.gyroZ)
                    
                    // Predicted activity
                    //                    ActivityCard(activity: sensorManager.predictedActivity)
                    
                    // Clustering
                    SegmentationCardView(sensorManager: sensorManager,
                                         labelStore: labelStore,
                                         targetEpisodes: $targetEpisodes)
                    
                    // Actions
                    VStack(spacing: 8) {
                        Button {
                            // Estado do botão deriva de `sensorManager.isRecording`
                            // (fonte única de verdade) — assim ele fica correto
                            // mesmo se o sistema encerrar a coleta sozinho.
                            if sensorManager.isRecording {
                                // Ordem importa (mudou na Etapa C): primeiro pedimos o stop —
                                // que faz flush SÍNCRONO do writeContext — para depois exportar
                                // lendo do disco. Sem essa ordem, o export perderia o último
                                // batch parcial (< saveThreshold amostras).
                                stopTime = Date()
                                sensorManager.requestStopBackgroundCollection()
                                combinedCSVURL = sensorManager.exportCombinedDataToCSV()
                            } else {
                                // Nova coleta: reinicia o cronômetro do zero e some
                                // com o link de export da coleta anterior.
                                startTime = Date()
                                stopTime = nil
                                combinedCSVURL = nil
                                sensorManager.submitBackgroundCollection()
                            }
                        } label: {
                            Label(sensorManager.isRecording ? "Parar coleta" : "Iniciar coleta",
                                  systemImage: sensorManager.isRecording ? "stop.fill" : "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(sensorManager.isRecording ? Color.white : Color.onAccent)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(sensorManager.isRecording ? .brandRed : .brandLime)
                        .controlSize(.large)
                        .accessibilityIdentifier("StartStopButton")
                        
                        if let combinedCSVURL = combinedCSVURL {
                            ShareLink(item: combinedCSVURL) {
                                Label("Exportar CSV", systemImage: "square.and.arrow.up")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.bordered)
                            .tint(.brandBlue)
                        }
                    }
                }
                .padding()
            }
            .background {
                Image("Wireframes")
                    .resizable()
                    .scaledToFill()          // preenche a tela, corta o excesso
                    .overlay(Color.appBackground.opacity(0.7)) // scrim p/ legibilidade
                    .ignoresSafeArea()
            }
            .navigationTitle("Move Collector")
            .onChange(of: sensorManager.isRecording) { _, recording in
                // Congela a Duração quando a coleta termina por QUALQUER caminho —
                // inclusive expiração da BGTask pelo sistema, em que o botão não
                // foi tocado. O guard evita sobrescrever o stopTime do stop manual.
                if !recording && stopTime == nil { stopTime = Date() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showOnboarding = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityIdentifier("OpenOnboardingButton")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showRecovery = true
                    } label: {
                        Image(systemName: "tray.and.arrow.down")
                    }
                    .accessibilityIdentifier("OpenRecoveryButton")
                }
            }
            .sheet(isPresented: $showRecovery) {
                RecoverySessionsView(sensorManager: sensorManager)
            }
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView {
                    hasSeenOnboarding = true
                    showOnboarding = false
                }
            }
            .onAppear {
                // Em UI tests pulamos o onboarding (passam "-skipOnboarding")
                // para não bloquear a tela principal.
                let skipForTests = ProcessInfo.processInfo.arguments.contains("-skipOnboarding")
                if !hasSeenOnboarding && !skipForTests {
                    showOnboarding = true
                }
            }
        }
    }
}

#Preview {
    if #available(iOS 26.0, *) {
        ContentView(sensorManager: AppDelegate().sensorManager)
            .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
            .preferredColorScheme(.dark)
    } else {
        // Fallback on earlier versions
    }
}



