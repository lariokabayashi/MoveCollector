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
    
    var body: some View {
        VStack(spacing: 40) {
            Text("Move Collector")
                .font(.title2)
                .bold()
            
            Spacer()
            
            VStack(alignment: .leading, spacing: 8) {
                
                Text("Acelerômetro: x: \(sensorManager.accelX, specifier: "%.2f") y: \(sensorManager.accelY, specifier: "%.2f") z: \(sensorManager.accelZ, specifier: "%.2f")")
                Text("Giroscópio: x: \(sensorManager.gyroX, specifier: "%.2f") y: \(sensorManager.gyroY, specifier: "%.2f") z: \(sensorManager.gyroZ, specifier: "%.2f")")
                Text("Bateria: \(Int(sensorManager.batteryLevel * 100))%")
            }
            .font(.system(.body, design: .monospaced))
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            
            Button {
                isUserStopped.toggle()
                if isUserStopped {
                    csvURL = sensorManager.exportToCSV()
                    sensorManager.requestStopBackgroundCollection()
                }else{
                    sensorManager.submitBackgroundCollection()
                    
                }
           } label: {
               isUserStopped
                   ? Text("Start").font(.title).foregroundStyle(.blue)
                   : Text("Stop").font(.title).foregroundStyle(.red)
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
