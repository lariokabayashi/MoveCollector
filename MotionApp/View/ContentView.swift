import SwiftUI
import CoreData
import CoreMotion
import UniformTypeIdentifiers

@available(iOS 26.0, *)
struct ContentView: View {
    @ObservedObject var sensorManager: SensorManagerViewModel
    @Environment(\.managedObjectContext) private var context
    @StateObject private var labelStore = EpisodeLabelStore()
    @State private var isUserStopped = false

    /// Onboarding "How to use this app" — exibido só no primeiro uso.
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false
    @State private var csvURL: URL?
    @State private var combinedCSVURL: URL?  // Novo: URL para CSV combinado
    @State private var startTime = Date()
    private let appConstants = AppConstants()
    private let utils = Utils()
    
    // Default K = 10. O Stepper em SegmentationCardView clampa automaticamente
    // ao range válido [2, min(W, 30)] sempre que `windowCount` mudar.
    @State private var targetEpisodes = 10

    /// Painel de benchmarks (avaliação de performance da tese).
    @State private var showBenchmarks = false

    /// Tela de recuperação de coletas persistidas (ex.: após BGTask terminado).
    @State private var showRecovery = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Top metrics
                    HStack(spacing: 12) {
                        MetricCard(title: "Duração", value: "\(String(format: "%.2f", Date().timeIntervalSince(startTime))) s")
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
                            isUserStopped.toggle()
                            if isUserStopped {
                                // Ordem importa (mudou na Etapa C): primeiro pedimos o stop —
                                // que faz flush SÍNCRONO do writeContext — para depois exportar
                                // lendo do disco. Sem essa ordem, o export perderia o último
                                // batch parcial (< saveThreshold amostras).
                                sensorManager.requestStopBackgroundCollection()
                                combinedCSVURL = sensorManager.exportCombinedDataToCSV()
                            } else {
                                sensorManager.submitBackgroundCollection()
                            }
                        } label: {
                            Label(isUserStopped ? "Iniciar coleta" : "Parar coleta",
                                  systemImage: isUserStopped ? "play.fill" : "stop.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isUserStopped ? .blue : .red)
                        .controlSize(.large)
                        .accessibilityIdentifier("StartStopButton")
                        
                        if let combinedCSVURL = combinedCSVURL {
                            ShareLink(item: combinedCSVURL) {
                                Label("Exportar CSV", systemImage: "square.and.arrow.up")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Move Collector")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showOnboarding = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityIdentifier("OpenOnboardingButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showBenchmarks = true
                    } label: {
                        Image(systemName: "stopwatch")
                    }
                    .accessibilityIdentifier("OpenBenchmarksButton")
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
//            .sheet(isPresented: $showBenchmarks) {
//                BenchmarkView(sensorManager: sensorManager)
//            }
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
            .preferredColorScheme(.light)
    } else {
        // Fallback on earlier versions
    }
}


