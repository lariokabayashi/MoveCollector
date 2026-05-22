import SwiftUI
import CoreData
import CoreMotion
import UniformTypeIdentifiers

@available(iOS 26.0, *)
struct ContentView: View {
    @ObservedObject var sensorManager: SensorManagerViewModel
    @Environment(\.managedObjectContext) private var context
    @State private var isUserStopped = false
    @State private var csvURL: URL?
    @State private var combinedCSVURL: URL?  // Novo: URL para CSV combinado
    @State private var startTime = Date()
    private let appConstants = AppConstants()
    private let utils = Utils()
    
    @State private var targetEpisodes = 10
    @State private var availableTargets = [5, 6, 7, 8, 9, 10]
    
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
                    SegmentationCardView(sensorManager: sensorManager, targetEpisodes: $targetEpisodes, availableTargets: $availableTargets)
                    
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

