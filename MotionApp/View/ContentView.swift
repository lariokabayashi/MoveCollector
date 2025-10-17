import SwiftUI
import CoreData
import CoreMotion
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.managedObjectContext) private var context
    @StateObject private var sensorManager: SensorManagerViewModel
    @State private var isCollecting = false
    @State private var csvURL: URL?
    
    init(context: NSManagedObjectContext) {
        _sensorManager = StateObject(wrappedValue: SensorManagerViewModel(context: context))
    }
    
    var body: some View {
        VStack(spacing: 40) {
            Text("Move Collector")
                .font(.title2)
                .bold()
            
            Spacer()
            
            VStack(alignment: .leading, spacing: 8) {
                
                Text("Acelerômetro: x: \(sensorManager.accelX, specifier: "%.2f") y: \(sensorManager.accelY, specifier: "%.2f") z: \(sensorManager.accelZ, specifier: "%.2f")")
                Text("Giroscópio: x: \(sensorManager.gyroX, specifier: "%.2f") y: \(sensorManager.gyroY, specifier: "%.2f") z: \(sensorManager.gyroZ, specifier: "%.2f")")
                Text("Magnetômetro: x: \(sensorManager.magX, specifier: "%.2f") y: \(sensorManager.magY, specifier: "%.2f") z: \(sensorManager.magZ, specifier: "%.2f")")
                Text("Bateria: \(Int(sensorManager.batteryLevel * 100))%")
            }
            .font(.system(.body, design: .monospaced))
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            
            Button{
                if isCollecting {
                    sensorManager.stopBackgroundCollection()
                    csvURL = sensorManager.exportToCSV()
                } else {
                    sensorManager.setupBackgroundCollection()
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
