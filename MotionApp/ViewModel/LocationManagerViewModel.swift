//
//  LocationManager.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 10/11/25.
//
//  Refatorado (Etapa B) — 2026-05-14:
//  - Adicionado: sessionId em LocationEntity, lido do AppDelegate
//  - Mudou: escrita imediata por reading (sem buffer) — GPS @ 1 Hz não justifica batching
//  - Mudou: leituras fora de sessão (currentSessionId == nil) são descartadas
//  - Mudou: contexto background dedicado (writeContext) p/ não pisar no main queue
//  - Mudou: timestamp persistido como Int64 ms (consistente com SensorReading)
//  - Removido: locationBuffer, gpsCache (sem consumer após Etapa A — SensorManager não lê mais)
//

import CoreLocation
import CoreData

@available(iOS 26.0, *)
class LocationManagerViewModel: NSObject, CLLocationManagerDelegate {

    private let locationManager = CLLocationManager()

    /// viewContext: passado pelo AppDelegate. Mantido pelo init existente, mas
    /// não usado em writes — todas as gravações vão pelo writeContext.
    private let viewContext: NSManagedObjectContext

    /// Contexto privado dedicado às escritas de LocationEntity.
    /// Mesmo racional do SensorManager: privateQueueConcurrencyType isola as
    /// inserts do main queue e da fila do SensorManager, evitando travas na UI
    /// e conflitos de pending objects entre as duas entidades.
    private let writeContext: NSManagedObjectContext

    private var appConstants = AppConstants()

    // MARK: - Session tagging
    // Wiring com AppDelegate (Etapa A). Lido em didUpdateLocations para decidir
    // se a leitura é persistida e com qual UUID. Quando nil, leituras são
    // descartadas (não há sessão ativa).
    weak var appDelegate: AppDelegate?

    // MARK: - Rate limit interno
    // CLLocationManager pode entregar updates em rajada; este filtro garante
    // pelo menos appConstants.gpsUpdateInterval (1s) entre amostras persistidas.
    private var lastUpdateTime: Date = Date.distantPast

    // MARK: - Init
    init(context: NSManagedObjectContext) {
        self.viewContext = context

        let ctx = PersistenceController.shared.container.newBackgroundContext()
        ctx.automaticallyMergesChangesFromParent = false
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        ctx.name = "LocationWriteContext"
        self.writeContext = ctx

        super.init()
        setupLocationManager()
    }

    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone     // recebe todas as updates; rate-limit nosso
        locationManager.showsBackgroundLocationIndicator = true    // boa prática para background
    }

    func startCollection() {
        // CRÍTICO: CLLocationManager precisa ser acionado numa thread com run
        // loop (main). handleBackgroundCollection roda na fila de background da
        // BGTask (scheduler.register(..., using: nil)); chamar startUpdatingLocation
        // de lá NÃO entrega updates (didUpdateLocations nunca dispara) → GPS some.
        // Por isso forçamos a main thread aqui.
        runOnMain {
            print("📍 [GPS] startCollection — authStatus=\(self.locationManager.authorizationStatus.rawValue), mainThread=\(Thread.isMainThread)")
            // Importante: pedir When In Use antes do Always (regra da Apple).
            self.locationManager.requestWhenInUseAuthorization()
            self.locationManager.requestAlwaysAuthorization()
            self.locationManager.startUpdatingLocation()
            print("📍 [GPS] startUpdatingLocation() invocado")
        }
    }

    func stopCollection() {
        // Mesmo motivo do startCollection: aciona o CLLocationManager na main.
        runOnMain {
            self.locationManager.stopUpdatingLocation()
        }
        // Não há buffer pendente — escrita é imediata por reading.
        // Mantido método porque AppDelegate.stopBackgroundCollection o chama.
    }

    /// Executa `work` na main thread. Se já estamos na main, roda síncrono para
    /// preservar a ordem em relação a quem chamou (ex.: stop seguido de export).
    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways:
            print("Authorized Always")
        case .authorizedWhenInUse:
            print("Authorized When In Use — needs Always for background")
        case .denied, .restricted:
            print("Permission denied")
        case .notDetermined:
            print("Waiting for user decision")
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let now = Date()

        // Rate limit (1 Hz). Pula a chamada inteira se chegou muito cedo.
        // Comentário sobre a alternativa: poderíamos rate-limitar por loc
        // individual em vez do callback inteiro, mas a CLLocationManager
        // normalmente entrega 1 loc por callback. Manter o filtro de callback
        // preserva o comportamento original.
        guard now.timeIntervalSince(lastUpdateTime) >= appConstants.gpsUpdateInterval else {
            return
        }
        lastUpdateTime = now

        // Captura atômica do sessionId.
        // Por quê capturar uma vez fora do loop: se sessionId virar nil
        // entre uma loc e outra do mesmo callback (raro mas possível),
        // queremos tratar o batch inteiro como pertencendo à mesma sessão.
        // Por quê descartar quando nil: GPS roda continuamente desde o
        // launch, mas só queremos persistir o que pertence a uma coleta.
        guard let sessionId = appDelegate?.currentSessionId else {
            // Sem sessão ativa — só log de diagnóstico, não persiste.
            // (gpsCache foi removido — não há mais consumer dele)
            return
        }

        for loc in locations {
            let horizontalAccuracy = loc.horizontalAccuracy
            // Validação: accuracy < 0 significa fix inválido (sem GPS).
            guard horizontalAccuracy >= 0 else {
                print("⚠️ Localização inválida — accuracy negativo")
                continue
            }

            // Snapshot dos valores (independentes do contexto background).
            let latitude = Float(loc.coordinate.latitude)
            let longitude = Float(loc.coordinate.longitude)
            let altitude = Float(loc.altitude)
            let hAcc = Float(horizontalAccuracy)
            let vAcc = Float(loc.verticalAccuracy)

            // Timestamp do fix GPS (não do callback) em Int64 ms — bate
            // com o schema de SensorReading p/ merge sincronizado no export.
            let timestampMs = Int64(loc.timestamp.timeIntervalSince1970 * 1000)

            // Etapa E: alimentar cache lido pelo SensorManager a 20 Hz para
            // preencher os 5 canais GPS no tensor de input do TFC. Independe
            // de sessionId — útil também se quisermos clusterizar sem persistir.
            appDelegate?.gpsSnapshotCache.update(.init(
                latitude: latitude, longitude: longitude, altitude: altitude,
                horizontalAccuracy: hAcc, verticalAccuracy: vAcc
            ))

            print("📍 GPS @ session \(sessionId.uuidString.prefix(8))…  "
                  + "ts=\(timestampMs) lat=\(latitude) lon=\(longitude) "
                  + "hAcc=\(hAcc) vAcc=\(vAcc)")

            persistLocation(
                sessionId: sessionId,
                timestampMs: timestampMs,
                latitude: latitude,
                longitude: longitude,
                altitude: altitude,
                horizontalAccuracy: hAcc,
                verticalAccuracy: vAcc
            )
        }
    }

    // MARK: - Persistência

    /// Grava uma LocationEntity imediatamente no writeContext.
    /// Por quê sem batching: GPS @ 1 Hz = 1 save/s. fsync trivial nesse ritmo;
    /// o ganho de batching não compensa a complexidade de flush em fim de sessão.
    /// Cada amostra fica durável no instante em que chega.
    private func persistLocation(
        sessionId: UUID,
        timestampMs: Int64,
        latitude: Float,
        longitude: Float,
        altitude: Float,
        horizontalAccuracy: Float,
        verticalAccuracy: Float
    ) {
        writeContext.perform { [weak self] in
            guard let self = self else { return }

            let entity = LocationEntity(context: self.writeContext)
            entity.sessionId = sessionId
            entity.timestamp = timestampMs
            entity.latitude = latitude
            entity.longitude = longitude
            entity.altitude = altitude
            entity.horizontalAccuracy = horizontalAccuracy
            entity.verticalAccuracy = verticalAccuracy

            do {
                try self.writeContext.save()
            } catch {
                print("❌ [LocationWrite] Save falhou: \(error.localizedDescription)")
            }
        }
    }
}

