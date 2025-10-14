import SwiftUI
import CoreData
import CoreMotion
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.managedObjectContext) private var context
    @StateObject private var motionManager: SensorManager
    @State private var isCollecting = false
    @State private var csvURL: URL?
    
    init(context: NSManagedObjectContext) {
        _motionManager = StateObject(wrappedValue: SensorManager(context: context))
    }
    
    var body: some View {
        VStack(spacing: 40) {
            Text("Move Collector")
                .font(.title2)
                .bold()
            
            Spacer()
            
            VStack(alignment: .leading, spacing: 8) {
                
                Text("Acelerômetro: x: \(motionManager.accelX, specifier: "%.2f") y: \(motionManager.accelY, specifier: "%.2f") z: \(motionManager.accelZ, specifier: "%.2f")")
                Text("Giroscópio: x: \(motionManager.gyroX, specifier: "%.2f") y: \(motionManager.gyroY, specifier: "%.2f") z: \(motionManager.gyroZ, specifier: "%.2f")")
                Text("Magnetômetro: x: \(motionManager.magX, specifier: "%.2f") y: \(motionManager.magY, specifier: "%.2f") z: \(motionManager.magZ, specifier: "%.2f")")
                Text("Bateria: \(Int(motionManager.batteryLevel * 100))%")
            }
            .font(.system(.body, design: .monospaced))
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            
            Button{
                if isCollecting {
                    motionManager.stopCollection()
                    csvURL = motionManager.exportToCSV()
                } else {
                    motionManager.setupBackgroundTask()
                }
                isCollecting.toggle()
            }
            label: {
                isCollecting ? Text("Stop").font(.title).foregroundStyle(.red) : Text("Start").font(.title).foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            
            if let csvURL = csvURL {
                ShareLink(
                    item: csvURL,
                    preview: SharePreview("Sensor Data", image: Image(systemName: "square.and.arrow.up"))
                ) {
                    Image(systemName: "square.and.arrow.up")
                        .resizable()
                        .frame(width: 30, height: 40)
                }
            }
            
            Spacer()
        }
        .padding()
    }
}
