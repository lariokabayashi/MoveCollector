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
        
        VStack(spacing: 40) {
            Text("Move Collector")
                .font(.title2)
                .bold()
            
            Spacer()
            
            HStack(spacing: 16){
                VStack {
                    Text("\(Date().timeIntervalSince(startTime), specifier: "%.2f") s")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.black)
                    
                    Text("Duration")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(appConstants.backgroundColor)
                )
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                
                VStack {
                    Text("\(Int(sensorManager.batteryLevel * 100))%")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.black)
                    
                    Text("Battery")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(appConstants.backgroundColor)
                )
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
            }
            
            VStack(alignment: .leading, spacing: 16) {
                VStack {
                    Text("Accelerometer: ")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    HStack(spacing: 16){
                        VStack{
                            Text("X")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                            Text("\(sensorManager.accelX, specifier: "%.2f")")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundColor(.black)
                            Text("m/sˆ2")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        VStack{
                            Text("Y")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                            Text("\(sensorManager.accelY, specifier: "%.2f")")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundColor(.black)
                            Text("m/sˆ2")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        VStack{
                            Text("Z")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                            Text("\(sensorManager.accelZ, specifier: "%.2f")")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundColor(.black)
                            Text("m/sˆ2")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(appConstants.backgroundColor)
                )
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                
                VStack(alignment: .leading, spacing: 16) {
                    VStack {
                        Text("Gyroscope: ")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                        HStack(spacing: 16){
                            VStack{
                                Text("X")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                Text("\(sensorManager.gyroX, specifier: "%.2f")")
                                    .font(.system(size: 32, weight: .bold))
                                    .foregroundColor(.black)
                                Text("∘/s")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                            VStack{
                                Text("Y")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                Text("\(sensorManager.gyroY, specifier: "%.2f")")
                                    .font(.system(size: 32, weight: .bold))
                                    .foregroundColor(.black)
                                Text("∘/s")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                            VStack{
                                Text("Z")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                Text("\(sensorManager.gyroZ, specifier: "%.2f")")
                                    .font(.system(size: 32, weight: .bold))
                                    .foregroundColor(.black)
                                Text("∘/s")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(appConstants.backgroundColor)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                }
            }
            
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
            .padding()
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(appConstants.backgroundColor)
            )
            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
            
//            if let csvURL = csvURL {
//                ShareLink(
//                    item: csvURL,
//                    preview: SharePreview("Sensor Data", image: Image(systemName: "square.and.arrow.up"))
//                ) {
//                    Image(systemName: "square.and.arrow.up")
//                        .resizable()
//                        .frame(width: 30, height: 40)
//                }
//            }
            
            Spacer()
        }
        .padding()
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
