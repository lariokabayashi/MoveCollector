//
//  SensorManager.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 07/10/25.
//
//  Refatorado (Etapa A) — 2026-05-14:
//  - Removido: combinedDataBuffer em memória, persistência de FeatureMatrix
//  - Adicionado: escrita incremental de SensorReading em contexto background dedicado,
//    com batching por saveThreshold e tag de sessionId por coleta
//  - Mantido: pipeline CNN em tempo real (mlBufferTimed → run_CNN_PFF_2D_backbone)
//    com acumulador em memória (rolling) para alimentar runDailyClustering
//

import SwiftUI
import CoreMotion
import UniformTypeIdentifiers
import CoreData
import CoreLocation
import CoreML

@available(iOS 26.0, *)
final class SensorManagerViewModel: NSObject, ObservableObject {

    // MARK: - Core Motion / lifecycle
    private let motionManager = CMMotionManager()
    weak var appDelegate: AppDelegate?
    private let appConstants = AppConstants()
    private var collectionTimer: DispatchSourceTimer?
    private let utils = Utils()

    // MARK: - Core Data
    /// viewContext: para reads ligados à UI (clustering, futuras telas).
    /// Não usado para writes em tempo real — escritas de 20 Hz vão no writeContext.
    private let viewContext: NSManagedObjectContext

    /// Contexto privado dedicado às escritas de SensorReading.
    /// Por quê: o timer da coleta dispara em background queue a 20 Hz;
    /// um privateQueueConcurrencyType serializa as inserts numa fila própria,
    /// isolando-as do main queue (UI) e de qualquer outra escrita (LocationManager).
    /// Como aplicar: todas as escritas usam writeContext.perform { ... } para
    /// hopar para a fila correta antes de tocar objetos managed.
    ///
    /// Por quê não é lazy: PersistenceController.container está marcado @MainActor.
    /// Inicializar aqui no init (chamado pela closure lazy do AppDelegate, em main
    /// queue) garante que .newBackgroundContext() seja invocado em MainActor.
    /// A partir daí o contexto é livre para uso via .perform em qualquer thread.
    private let writeContext: NSManagedObjectContext

    // MARK: - Session tagging
    /// Toda SensorReading gravada durante esta coleta carrega este UUID.
    /// Setado em startCollection(), publicado também no AppDelegate para o
    /// LocationManager ler (Etapa B). Volta a nil em stopCollection().
    private var currentSessionId: UUID?

    /// Última sessão encerrada — capturada em stopCollection() ANTES do clear de
    /// currentSessionId, para que o export possa rodar depois do stop e ainda
    /// saber qual sessão exportar. Sem isto, o ContentView teria que capturar
    /// e passar o UUID manualmente.
    private(set) var lastSessionId: UUID?

    // MARK: - Tracking de export (Etapa D)
    /// Side-state em UserDefaults com os UUIDs que já tiveram CSV exportado.
    /// Usado para diferenciar "sessão órfã" (existe no Core Data mas nunca foi
    /// exportada) de "sessão antiga" (existe E foi exportada — esperando purge).
    private let exportedStore = ExportedSessionsStore()

    // MARK: - Batching de writes
    /// Buffer pequeno só para reduzir chamadas a context.save() — não armazena
    /// dados não persistidos: cada item daqui já é um NSManagedObject criado no
    /// writeContext, esperando o próximo flush.
    private var pendingInserts: Int = 0

    // MARK: - ML Model (inalterado)
    private var cnn_pff_2D_backbone: CNN_PFF_2D_backbone?
    private var mlBufferTimed: [Sample] = []     // sliding window com timestamps

    @Published var mlStatusMessage: String = ""
    @Published var mlIsReady: Bool = false

    /// Último resultado da CNN. Mantido por compatibilidade com UI / debug.
    private var data2D: [[Float]] = []
    private let data2DLock = NSLock()

    /// Acumulador rolante de outputs da CNN para alimentar runDailyClustering
    /// sem precisar persistir FeatureMatrix.
    /// Cap deliberadamente conservador: a CNN dispara a cada amostra após a
    /// janela inicial (20 Hz), então um cap de 10000 cobre ~8min de histórico.
    /// Para mais que isso, runDailyClustering veria janela truncada — limitação
    /// aceita conforme escopo da Etapa A (FeatureMatrix não persiste mais).
    private var data2DAccumulator: [[Float]] = []
    private let data2DAccumulatorLock = NSLock()
    private let data2DAccumulatorCap = 10_000

    // MARK: - Publicado para UI
    @Published var linkageMatrix: [[Float]] = []
    @Published var clusterLabels: [Int] = []
    @Published var buffer: [[[Float]]] = []   // mantido para compatibilidade da UI

    @Published var isRecording = false
    @Published var accelX: Float = 0
    @Published var accelY: Float = 0
    @Published var accelZ: Float = 0
    @Published var gyroX: Float = 0
    @Published var gyroY: Float = 0
    @Published var gyroZ: Float = 0
    @Published var batteryLevel: Float = UIDevice.current.batteryLevel

    // MARK: - Init
    init(context: NSManagedObjectContext) {
        self.viewContext = context

        // Inicializa writeContext aqui (estamos no main queue via AppDelegate lazy).
        let ctx = PersistenceController.shared.container.newBackgroundContext()
        ctx.automaticallyMergesChangesFromParent = false
        ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        ctx.name = "SensorWriteContext"
        self.writeContext = ctx

        UIDevice.current.isBatteryMonitoringEnabled = true
        super.init()

        do {
            let model = try CNN_PFF_2D_backbone()
            self.cnn_pff_2D_backbone = model
            self.mlIsReady = true
            self.mlStatusMessage = "ML model loaded"
        } catch {
            self.mlIsReady = false
            self.mlStatusMessage = "Failed to load ML model: \(error.localizedDescription)"
            print("[ML] Model load error:", error)
        }
    }

    // MARK: - Lifecycle público

    func startCollection() {
        // Por quê: cada coleta é uma sessão isolada. O UUID é gerado aqui (fonte
        // única) e replicado no AppDelegate para o LocationManager consumir.
        let sessionId = UUID()
        currentSessionId = sessionId
        appDelegate?.currentSessionId = sessionId
        print("🎯 Nova sessão de coleta: \(sessionId.uuidString)")

        // Configurar frequências
        motionManager.deviceMotionUpdateInterval = appConstants.sensorUpdateInterval
        motionManager.accelerometerUpdateInterval = appConstants.sensorUpdateInterval
        motionManager.gyroUpdateInterval = appConstants.sensorUpdateInterval

        print("🎯 Iniciando coleta de sensores @ \(String(format: "%.1f", appConstants.sensorFrequencyHz)) Hz")

        // IMPORTANTE: removido context.reset() que existia aqui.
        // Por quê: o viewContext é compartilhado com a UI e com o LocationManager;
        // resetá-lo destrói objetos pendentes de outras entidades em escrita
        // concorrente. Como agora as escritas vão para writeContext isolado,
        // não há nada a resetar — o próprio newBackgroundContext já começa limpo.

        motionManager.startAccelerometerUpdates()
        motionManager.startGyroUpdates()
        motionManager.startDeviceMotionUpdates()

        startBackgroundTimer()
        
        DispatchQueue.main.async {
            self.isRecording = true
        }
    }

    private func startBackgroundTimer() {
        collectionTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
        collectionTimer?.schedule(deadline: .now(), repeating: appConstants.sensorUpdateInterval)
        collectionTimer?.setEventHandler { [weak self] in
            self?.collectData()
        }
        collectionTimer?.resume()
    }

    func stopCollection() {
        collectionTimer?.cancel()
        collectionTimer = nil

        motionManager.stopAccelerometerUpdates()
        motionManager.stopGyroUpdates()
        motionManager.stopDeviceMotionUpdates()

        // Limpar buffers em memória
        mlBufferTimed.removeAll(keepingCapacity: false)

        data2DLock.lock()
        data2D.removeAll(keepingCapacity: false)
        data2DLock.unlock()

        // Captura sessionId encerrada ANTES de qualquer clear, p/ o export e
        // p/ logs do flush. Não pode acontecer depois — currentSessionId já
        // vai virar nil.
        let sessionToClose = currentSessionId
        lastSessionId = sessionToClose

        // Flush final SÍNCRONO do writeContext.
        // Por quê performAndWait (e não perform):
        // - O ContentView chama exportCombinedDataToCSV logo depois de stop;
        //   precisamos garantir que o último batch parcial (< saveThreshold)
        //   já está no disco antes do fetch do export rodar.
        // - performAndWait bloqueia até a fila privada do contexto rodar o bloco.
        //   Custo: alguns ms de I/O na thread chamadora (main, no caso do botão).
        // - Sem deadlock: stopCollection NÃO é chamado de dentro da fila do
        //   writeContext em nenhum caminho.
        writeContext.performAndWait {
            do {
                if writeContext.hasChanges {
                    try writeContext.save()
                    print("✅ [SensorWrite] Flush final — sessão \(sessionToClose?.uuidString ?? "nil")")
                }
                pendingInserts = 0
            } catch {
                print("❌ [SensorWrite] Erro no flush final: \(error.localizedDescription)")
            }
        }

        // Sessão encerrada — limpa marcadores (mantém lastSessionId p/ export).
        currentSessionId = nil
        appDelegate?.currentSessionId = nil
        
        DispatchQueue.main.async {
            self.isRecording = false
        }
    }

    func requestStopBackgroundCollection() {
        appDelegate?.stopBackgroundCollection()
    }

    func submitBackgroundCollection() {
        appDelegate?.submitBackgroundCollection()
    }

    // MARK: - Coleta tick

    private func collectData() {
        // Por quê o timestamp epoch-ms é capturado fora do dispatch para main:
        // queremos t da amostra real, não t de quando o main queue conseguiu
        // executar o bloco (pode atrasar sob carga).
        let now = Date()
        let tEpoch = now.timeIntervalSince1970
        let timestampMs = Int64(tEpoch * 1000)

        guard let accel = motionManager.deviceMotion?.userAcceleration,
              let gyro  = motionManager.gyroData else {
            return
        }

        // Snapshots locais — independentes do main queue.
        let ax = Float(accel.x * 10)
        let ay = Float(accel.y * 10)
        let az = Float(accel.z * 10)
        let gx = Float(gyro.rotationRate.x)
        let gy = Float(gyro.rotationRate.y)
        let gz = Float(gyro.rotationRate.z)
        let battery = UIDevice.current.batteryLevel

        // 1) Persistência: enfileirar SensorReading no writeContext.
        //    Capturamos o sessionId atomicamente fora do perform para evitar
        //    ler nil se stopCollection() acabou de zerá-lo.
        if let sessionId = currentSessionId {
            persistSensorReading(
                sessionId: sessionId,
                timestampMs: timestampMs,
                ax: ax, ay: ay, az: az,
                gx: gx, gy: gy, gz: gz,
                battery: battery
            )
        }

        // 2) UI updates + pipeline CNN — precisam de main queue por causa de @Published.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.accelX = ax
            self.accelY = ay
            self.accelZ = az
            self.gyroX = gx
            self.gyroY = gy
            self.gyroZ = gz
            self.batteryLevel = battery

            self.appendToMLBuffer(
                timestamp: tEpoch,
                ax: ax, ay: ay, az: az,
                gx: gx, gy: gy, gz: gz
            )
        }
    }

    // MARK: - Persistência de SensorReading

    /// Enfileira uma SensorReading no writeContext e dispara save quando
    /// o lote atinge appConstants.saveThreshold.
    /// Por quê batch: a 20 Hz, salvar amostra-por-amostra geraria 20 fsyncs/s.
    /// Com batch ~100 (~5s), o I/O cai 100×.
    private func persistSensorReading(
        sessionId: UUID,
        timestampMs: Int64,
        ax: Float, ay: Float, az: Float,
        gx: Float, gy: Float, gz: Float,
        battery: Float
    ) {
        writeContext.perform { [weak self] in
            guard let self = self else { return }

            let reading = SensorReading(context: self.writeContext)
            reading.id = UUID()
            reading.sessionId = sessionId
            reading.timestamp = timestampMs
            reading.ax = ax
            reading.ay = ay
            reading.az = az
            reading.gx = gx
            reading.gy = gy
            reading.gz = gz
            reading.battery = battery

            self.pendingInserts += 1

            if self.pendingInserts >= self.appConstants.saveThreshold {
                do {
                    try self.writeContext.save()
                    self.pendingInserts = 0

                    // Por quê NÃO chamamos context.reset() aqui:
                    // - Não há ciclo de referência: os SensorReadings ficam no
                    //   row cache do writeContext mas não causam memory leak
                    //   porque o save() já flushou para o store.
                    // - reset() durante coleta ativa pode descartar objetos
                    //   pendentes de outra entidade ou faulting em curso.
                    // Se o row cache crescer demais em coletas muito longas,
                    // a Etapa D pode adicionar refreshAllObjects(mergeChanges: true)
                    // como meio-termo (libera as faults, mantém pending).
                } catch {
                    print("❌ [SensorWrite] Save batch falhou: \(error.localizedDescription)")
                    // Mantém pendingInserts não-zerado — próximo tick tenta de novo.
                }
            }
        }
    }

    // MARK: - Pipeline CNN (inalterado, exceto pelo acumulador)

    private func run_CNN_PFF_2D_backbone() {
        guard mlIsReady, let model = cnn_pff_2D_backbone else {
            DispatchQueue.main.async { self.mlStatusMessage = "ML model not ready" }
            return
        }
        guard let input = prepareMLMultiArray() else {
            DispatchQueue.main.async { self.mlStatusMessage = "Failed to prepare ML input" }
            return
        }
        do {
            let output = try model.prediction(x_1: input)
            let features = output.var_200ShapedArray
            let newData = utils.shapedArrayTo2D(features)

            // Atualiza o "último resultado" (compat) ...
            data2DLock.lock()
            data2D = newData
            data2DLock.unlock()

            // ... e acumula com cap rolling para clustering posterior.
            // Por quê acumulador separado: data2D é o snapshot atual; o
            // accumulator é a história. Antes isso vivia em FeatureMatrix
            // no Core Data — agora vive em memória, conforme escopo.
            data2DAccumulatorLock.lock()
            data2DAccumulator.append(contentsOf: newData)
            if data2DAccumulator.count > data2DAccumulatorCap {
                let overflow = data2DAccumulator.count - data2DAccumulatorCap
                data2DAccumulator.removeFirst(overflow)
            }
            data2DAccumulatorLock.unlock()

            mlStatusMessage = "Prediction OK"
        } catch {
            DispatchQueue.main.async {
                self.mlStatusMessage = "CNN_PFF_2D_backbone Prediction Error: \(error.localizedDescription)"
            }
            print("CNN_PFF_2D_backbone Prediction Error:", error)
        }
    }

    private func prepareMLMultiArray() -> MLMultiArray? {
        let windowSize = appConstants.windowSize
        guard mlBufferTimed.count >= windowSize else { return nil }
        let dt = appConstants.sensorUpdateInterval
        guard dt > 0 else { return nil }
        let rateHz = appConstants.sensorFrequencyHz

        guard let startT = mlBufferTimed.first?.t else { return nil }
        let resampled = utils.resampleToFixedRate(
            samples: mlBufferTimed,
            startTime: startT,
            count: windowSize,
            rateHz: rateHz
        )

        let shape: [NSNumber] = [1, 6, NSNumber(value: windowSize)]
        guard let array = try? MLMultiArray(shape: shape, dataType: .float32) else { return nil }

        for (tIndex, s) in resampled.enumerated() {
            array[[0, 0, tIndex] as [NSNumber]] = NSNumber(value: Float32(s.ax))
            array[[0, 1, tIndex] as [NSNumber]] = NSNumber(value: Float32(s.ay))
            array[[0, 2, tIndex] as [NSNumber]] = NSNumber(value: Float32(s.az))
            array[[0, 3, tIndex] as [NSNumber]] = NSNumber(value: Float32(s.gx))
            array[[0, 4, tIndex] as [NSNumber]] = NSNumber(value: Float32(s.gy))
            array[[0, 5, tIndex] as [NSNumber]] = NSNumber(value: Float32(s.gz))
        }
        return array
    }

    func appendToMLBuffer(timestamp: TimeInterval, ax: Float, ay: Float, az: Float,
                          gx: Float, gy: Float, gz: Float) {
        mlBufferTimed.append(Sample(t: timestamp, ax: ax, ay: ay, az: az, gx: gx, gy: gy, gz: gz))

        if mlBufferTimed.count > appConstants.windowSize { mlBufferTimed.removeFirst() }

        if mlBufferTimed.count == appConstants.windowSize {
            run_CNN_PFF_2D_backbone()
        }
    }

    // MARK: - Clustering (agora alimentado pelo acumulador em memória)

    func runDailyClustering(t: Int = 8) {
        // Por quê mudou: antes lia FeatureMatrix do Core Data e fazia
        // downsample incremental para ~1000 amostras. Agora lê do
        // data2DAccumulator (capped a 10k), aplica o mesmo downsample
        // adaptativo e roda o clustering Ward. Limitação: o cap rolling
        // de 10k é um trade-off de memória x cobertura histórica.

        let targetSamples = 1000

        // Cópia local sob lock para não bloquear a coleta.
        data2DAccumulatorLock.lock()
        let snapshot = data2DAccumulator
        data2DAccumulatorLock.unlock()

        guard snapshot.count >= 2 else {
            DispatchQueue.main.async {
                self.linkageMatrix = []
                self.clusterLabels = []
            }
            print("[CLUSTERING] Sem amostras suficientes (\(snapshot.count))")
            return
        }

        let window = max(1, snapshot.count / targetSamples)
        let reduced = utils.downsampleMean(snapshot, window: window)

        print("[CLUSTERING] Ward em \(reduced.count) amostras (window=\(window))")

        let Z = self.utils.linkageAdjacentWard(reduced, stopAtK: t)
        let labels = self.utils.fclusterFromPartialZ(Z: Z, n: reduced.count)

        DispatchQueue.main.async {
            self.linkageMatrix = Z
            self.clusterLabels = labels
        }

        print("[CLUSTERING] Pronto. Clusters: \(t), Labels: \(labels.count)")
    }

    // MARK: - Export CSV (Etapa C — streaming + merge two-pointer)

    /// Wrapper que escolhe a sessão a exportar: prioriza a recém-encerrada,
    /// cai na sessão ativa (caso de export mid-collection), retorna nil se
    /// não há nenhuma. Mantido com este nome por compat com ContentView.
    /// Para exportar uma sessão específica (ex: recovery), usar exportSession(_:).
    func exportCombinedDataToCSV() -> URL? {
        guard let sessionId = lastSessionId ?? currentSessionId else {
            print("⚠️ [CSV Export] Sem sessão para exportar (lastSessionId & currentSessionId nil)")
            return nil
        }
        return exportSession(sessionId)
    }

    /// Exporta a sessão indicada para CSV. Stream via FileHandle — não
    /// constrói o CSV completo em memória. Marca a sessão como exportada
    /// em UserDefaults ao final de um run bem-sucedido.
    ///
    /// Schema: timestamp,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z,
    ///         latitude,longitude,altitude,horizontal_accuracy,vertical_accuracy
    /// timestamp = ms epoch da SensorReading. Quando não há GPS último-conhecido
    /// para uma amostra (ex.: primeiras amostras antes do primeiro fix), as
    /// 5 colunas de GPS ficam vazias.
    func exportSession(_ sessionId: UUID) -> URL? {

        // 1) Flush idempotente do writeContext.
        // Cinto-suspensório: stopCollection já faz performAndWait quando o
        // export segue um stop normal, mas se for export de sessão órfã
        // (recovery, sem stop prévio), garantir que pendings estejam em disco.
        writeContext.performAndWait {
            do {
                if writeContext.hasChanges {
                    try writeContext.save()
                }
            } catch {
                print("❌ [CSV Export] Flush idempotente falhou: \(error.localizedDescription)")
            }
        }

        // 3) Criar URL de saída no diretório Documents.
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        fmt.timeZone = TimeZone.current
        let dateString = fmt.string(from: Date())
        let shortId = sessionId.uuidString.prefix(8)
        let fileName = "session_\(shortId)_\(dateString).csv"

        guard let documentDirectory = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else {
            print("❌ [CSV Export] Documents directory inacessível")
            return nil
        }
        let fileURL = documentDirectory.appendingPathComponent(fileName)

        // Cria arquivo vazio (FileHandle(forWritingTo:) só abre, não cria)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            print("❌ [CSV Export] Não foi possível abrir FileHandle em \(fileURL.path)")
            return nil
        }
        defer { try? handle.close() }

        // 4) Contexto de leitura dedicado.
        // Por quê não viewContext nem writeContext:
        // - viewContext: ligado à UI; fetches longos travariam a main queue.
        // - writeContext: tem objetos pending faulting (até reset/refresh) — risco
        //   de tocar em algo mid-fault. Manter separado é mais previsível.
        // Um newBackgroundContext começa "fresco" — vê tudo que o coordinator
        // tem em disco após o save acima.
        let fetchContext = PersistenceController.shared.container.newBackgroundContext()

        // 5) Header
        let header = "timestamp,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z,"
                   + "latitude,longitude,altitude,horizontal_accuracy,vertical_accuracy\n"
        if let headerData = header.data(using: .utf8) {
            handle.write(headerData)
        }

        // 6) Fetch + merge two-pointer, todo dentro do fetchContext.perform.
        var totalRows = 0
        var rowsWithGPS = 0

        fetchContext.performAndWait {
            // 6a) LocationEntity da sessão, materializado uma vez. Cap esperado
            // (8h @ 1 Hz) = ~28k linhas × ~50 bytes ≈ 1.4 MB. OK manter em RAM
            // pelo benefício de acesso O(1) durante o merge.
            let locFetch: NSFetchRequest<LocationEntity> = LocationEntity.fetchRequest()
            locFetch.predicate = NSPredicate(format: "sessionId == %@", sessionId as CVarArg)
            locFetch.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            locFetch.returnsObjectsAsFaults = false   // pre-faulting (lemos todas as colunas)

            var locations: [LocationEntity] = []
            do {
                locations = try fetchContext.fetch(locFetch)
            } catch {
                print("❌ [CSV Export] Fetch de LocationEntity falhou: \(error.localizedDescription)")
            }

            // 6b) SensorReading da sessão, streaming via fetchBatchSize.
            // Core Data devolve um array "batch faulting": acessar índice N
            // faulta-se em janelas de batchSize. Combinado com refresh por
            // linha processada (mais abaixo), a memória residente fica O(batch).
            let sensorFetch: NSFetchRequest<SensorReading> = SensorReading.fetchRequest()
            sensorFetch.predicate = NSPredicate(format: "sessionId == %@", sessionId as CVarArg)
            sensorFetch.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            sensorFetch.fetchBatchSize = 500

            let sensors: [SensorReading]
            do {
                sensors = try fetchContext.fetch(sensorFetch)
            } catch {
                print("❌ [CSV Export] Fetch de SensorReading falhou: \(error.localizedDescription)")
                return
            }

            // 6c) Merge two-pointer.
            // locIdx começa em -1 = "ainda não temos GPS válido para esta amostra"
            // (amostras de sensor anteriores ao primeiro fix do GPS).
            // A invariante após o while loop é:
            //   locations[locIdx].timestamp <= sensor.timestamp < locations[locIdx+1].timestamp
            // (ou locIdx == last, ou locIdx == -1 quando sensor antes de qualquer GPS)
            var locIdx: Int = -1

            // 6d) I/O batching: acumula ~1000 linhas como String e escreve em
            // uma chamada só ao FileHandle. Sem isso seriam 576k syscalls.
            // 1000 linhas × ~100 bytes = ~100KB residente por flush.
            var lineBuffer = ""
            lineBuffer.reserveCapacity(128 * 1024)
            let flushEvery = 1000
            var bufferedLines = 0

            for sensor in sensors {
                let sensorTs = sensor.timestamp

                // Avança locIdx enquanto a PRÓXIMA location tem timestamp <= sensorTs.
                while locIdx + 1 < locations.count
                      && locations[locIdx + 1].timestamp <= sensorTs {
                    locIdx += 1
                }

                // Sensor fields (Float). String(_:) padrão dá precisão suficiente
                // para análise pós-coleta. Se precisar de fixed-format, trocar
                // por String(format: "%.6f", _).
                let ax = sensor.ax, ay = sensor.ay, az = sensor.az
                let gx = sensor.gx, gy = sensor.gy, gz = sensor.gz

                if locIdx >= 0 {
                    let loc = locations[locIdx]
                    lineBuffer.append(
                        "\(sensorTs),\(ax),\(ay),\(az),\(gx),\(gy),\(gz),"
                        + "\(loc.latitude),\(loc.longitude),\(loc.altitude),"
                        + "\(loc.horizontalAccuracy),\(loc.verticalAccuracy)\n"
                    )
                    rowsWithGPS += 1
                } else {
                    // Sem GPS último-conhecido para esta amostra — 5 campos vazios.
                    lineBuffer.append(
                        "\(sensorTs),\(ax),\(ay),\(az),\(gx),\(gy),\(gz),,,,,\n"
                    )
                }

                totalRows += 1
                bufferedLines += 1

                // Libera memória do row cache: vira fault novamente.
                // Por quê safe: não acessamos mais este sensor após esta iteração.
                fetchContext.refresh(sensor, mergeChanges: false)

                if bufferedLines >= flushEvery {
                    if let data = lineBuffer.data(using: .utf8) {
                        handle.write(data)
                    }
                    lineBuffer.removeAll(keepingCapacity: true)
                    bufferedLines = 0
                }
            }

            // Flush das linhas restantes (< flushEvery).
            if !lineBuffer.isEmpty, let data = lineBuffer.data(using: .utf8) {
                handle.write(data)
            }

            // Refresh do array de locations para liberar memória.
            for loc in locations {
                fetchContext.refresh(loc, mergeChanges: false)
            }
        }

        // 7) Marcar sessão como exportada em UserDefaults.
        // Acontece DEPOIS do CSV estar escrito no disco, não antes. Se o write
        // falhar mid-way, a sessão continua marcada como órfã e o próximo
        // launch (ou um botão "tentar novamente") pode re-exportar.
        // Idempotente: chamar de novo é no-op.
        if totalRows > 0 {
            exportedStore.markExported(sessionId)
        } else {
            print("⚠️ [CSV Export] Sessão \(sessionId) tem 0 linhas — não marcando como exportada")
        }

        print("✅ [CSV Export] \(fileName)")
        print("   sessão: \(sessionId.uuidString)")
        print("   linhas: \(totalRows) total, \(rowsWithGPS) com GPS, "
              + "\(totalRows - rowsWithGPS) sem GPS (pré-fix)")
        print("   path: \(fileURL.path)")
        return fileURL
    }

    // MARK: - Recovery (Etapa D)

    /// Retorna sessionIds presentes em SensorReading que NÃO estão marcadas
    /// como exportadas em UserDefaults. Essas são as "órfãs" — coletas que
    /// foram persistidas (parcial ou totalmente) mas nunca viraram CSV.
    ///
    /// Cenários típicos:
    /// - App morto pelo iOS durante coleta longa
    /// - Crash entre stopCollection() e exportCombinedDataToCSV()
    /// - Usuário fechou o app antes de exportar
    ///
    /// A query usa SensorReading como fonte canônica de sessões. LocationEntity
    /// pode ter linhas órfãs também, mas só existem se houve SensorReading
    /// correspondente (LocationManager só persiste durante sessão ativa).
    func findOrphanedSessions() -> [UUID] {
        let fetchContext = PersistenceController.shared.container.newBackgroundContext()

        var distinctSessionIds: Set<UUID> = []

        fetchContext.performAndWait {
            // NSFetchRequest com .dictionaryResultType + DISTINCT é a forma mais
            // barata de fazer SELECT DISTINCT no Core Data — Core Data traduz
            // para um SQL real com DISTINCT no SQLite store, em vez de carregar
            // todas as 576k linhas e dedupar em Swift.
            let req = NSFetchRequest<NSDictionary>(entityName: "SensorReading")
            req.resultType = .dictionaryResultType
            req.returnsDistinctResults = true
            req.propertiesToFetch = ["sessionId"]
            req.predicate = NSPredicate(format: "sessionId != nil")

            do {
                let rows = try fetchContext.fetch(req)
                for row in rows {
                    if let id = row["sessionId"] as? UUID {
                        distinctSessionIds.insert(id)
                    }
                }
            } catch {
                print("❌ [Recovery] Fetch DISTINCT sessionId falhou: \(error.localizedDescription)")
            }
        }

        let exported = exportedStore.allExported()
        let orphans = distinctSessionIds.subtracting(exported)

        // Excluir sessão ATIVA da lista — ela está sendo populada agora,
        // não é "órfã" no sentido de recovery.
        var filteredOrphans = orphans
        if let active = currentSessionId {
            filteredOrphans.remove(active)
        }

        return Array(filteredOrphans).sorted { $0.uuidString < $1.uuidString }
    }

    /// Conveniência para chamada no launch: roda findOrphanedSessions e
    /// loga o resultado. Retorna a lista para a UI processar se quiser.
    @discardableResult
    func reportOrphanedSessionsOnLaunch() -> [UUID] {
        let orphans = findOrphanedSessions()
        if orphans.isEmpty {
            print("ℹ️ [Recovery] Nenhuma sessão órfã detectada no launch")
        } else {
            print("⚠️ [Recovery] \(orphans.count) sessão(ões) órfã(s) detectada(s):")
            for id in orphans {
                print("   - \(id.uuidString)")
            }
            print("   Para exportar, chame sensorManager.exportSession(id).")
            print("   Para descartar, chame sensorManager.deleteSession(id).")
        }
        return orphans
    }

    // MARK: - Cleanup (Etapa D)

    /// Deleta todas as linhas de SensorReading + LocationEntity da sessão indicada.
    /// Usa NSBatchDeleteRequest — operação direta no store, sem materializar objetos.
    /// Para 576k linhas, é ~milissegundos vs segundos do delete tradicional.
    ///
    /// IMPORTANTE: NSBatchDeleteRequest bypassa o managed object context, então
    /// precisamos mergear as deletions de volta nos contextos vivos para evitar
    /// referências stale. Sem o merge, viewContext/writeContext continuariam
    /// achando que os objetos existem.
    func deleteSession(_ sessionId: UUID) {
        let deleteContext = PersistenceController.shared.container.newBackgroundContext()

        deleteContext.performAndWait {
            var totalDeleted = 0

            for entityName in ["SensorReading", "LocationEntity"] {
                let fetchReq = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                fetchReq.predicate = NSPredicate(format: "sessionId == %@", sessionId as CVarArg)

                let deleteReq = NSBatchDeleteRequest(fetchRequest: fetchReq)
                deleteReq.resultType = .resultTypeObjectIDs

                do {
                    let result = try deleteContext.execute(deleteReq) as? NSBatchDeleteResult
                    let ids = (result?.result as? [NSManagedObjectID]) ?? []
                    totalDeleted += ids.count

                    // Merge das deletions no viewContext + writeContext.
                    // Por quê: NSBatchDeleteRequest opera direto no SQLite,
                    // pulando os contextos. Os objetos podem estar em row cache
                    // de outros contextos, e sem este merge eles ficariam
                    // como objetos "zombies" — fault que falha ao acessar.
                    let changes: [AnyHashable: Any] = [NSDeletedObjectsKey: ids]
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: changes,
                        into: [viewContext, writeContext]
                    )
                } catch {
                    print("❌ [Cleanup] Delete \(entityName) sessão \(sessionId) falhou: \(error.localizedDescription)")
                }
            }

            print("🗑️ [Cleanup] Sessão \(sessionId.uuidString.prefix(8))… — \(totalDeleted) linhas deletadas")
        }

        // Tira da lista de exportadas — sem dado correspondente, a marca
        // perderia o sentido.
        exportedStore.unmark(sessionId)
    }

    /// Deleta todas as sessões marcadas como exportadas em UserDefaults.
    /// Conveniência para um botão "limpar exportadas" na UI.
    /// Sessões órfãs (não exportadas) NÃO são afetadas — preserva dados não-salvos.
    func deleteAllExportedSessions() {
        let exported = exportedStore.allExported()
        print("🗑️ [Cleanup] Iniciando purge de \(exported.count) sessão(ões) exportada(s)")
        for id in exported {
            deleteSession(id)
        }
    }
}
