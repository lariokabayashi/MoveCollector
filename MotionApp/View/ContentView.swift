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
    @State private var startTime = Date()
    private let appConstants = AppConstants()

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
                    ActivityCard(activity: sensorManager.predictedActivity)
                    
//                    ResampleComparisonChartView(viewModel: sensorManager)

                    // Actions
                    VStack(spacing: 8) {
                        Button {
                            isUserStopped.toggle()
                            if isUserStopped {
                                csvURL = sensorManager.exportToCSV()
                                sensorManager.requestStopBackgroundCollection()
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

                        if let csvURL = csvURL {
                            ShareLink(item: csvURL) {
                                Label("Exportar CSV", systemImage: "square.and.arrow.up")
                                    .font(.subheadline)
                            }
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
