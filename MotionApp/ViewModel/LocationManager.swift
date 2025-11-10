//
//  LocationManager.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 10/11/25.
//

import CoreLocation

class LocationManager: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func startCollection() {
        // Important: First request “When In Use”, then “Always”
        locationManager.requestWhenInUseAuthorization()
        locationManager.requestAlwaysAuthorization()
        locationManager.startUpdatingLocation()
    }

    func stopCollection() {
        locationManager.stopUpdatingLocation()
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways:
            print("✅ Authorized Always")
        case .authorizedWhenInUse:
            print("🟡 Authorized When In Use — needs Always for background")
        case .denied, .restricted:
            print("🚫 Permission denied")
        case .notDetermined:
            print("⏳ Waiting for user decision")
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations {
            print("📍 Nova localização: \(loc.coordinate)")
            // Salvar ou processar seus dados aqui
        }
    }
}
