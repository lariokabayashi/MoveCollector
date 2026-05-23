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
//
//  Refatorado (Etapa E — TFC migration) — 2026-05-22:
//  - Removido: CNN_PFF_2D_backbone + data2D + data2DAccumulator (feature maps por tick)
//  - Adicionado: TFCFeatureExtractor (TFC_Backbone.mlpackage) com embeddings
//    256-d (concat z_t + z_f) por JANELA (não por tick).
//  - Adicionado: GPS entra como canal feature (lat, lon, alt, hAcc, vAcc) —
//    pipeline 11-canal igual ao Python.
//  - Adicionado: windowTimestamps acumulator (Int64 ms) preserva timestamp
//    de início de cada janela — usado pelo EpisodeBuilder.
//  - Mudou: runDailyClustering devolve `[Episode]` direto, não só rótulos.
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

    // MARK: - ML Model (TFC_Backbone — substitui CNN_PFF_2D antigo)
    //
    // CRITICAL: o buffer agora acumula 11 canais (acc xyz + gyro xyz + GPS 5x).
    // Substitui o antigo `mlBufferTimed: [Sample]` (6 canais).
    private var tfcExtractor: TFCFeatureExtractor?

    /// Buffer de amostras crus por janela. Cada entrada é um snapshot de 11 floats
    /// no instante da amostra. Quando atinge `windowSize` (= 300 @ 20 Hz = 15s),
    /// um embedding é gerado e o buffer é zerado (step = window, sem overlap).
    private var windowBuffer: [Float] = []
    /// Timestamps em ms para cada amostra acumulada no `windowBuffer`.
    /// Quando a janela fecha, `windowTimestamps.append(buffer[0])`.
    private var windowSampleTimestamps: [Int64] = []

    @Published var mlStatusMessage: String = ""
    @Published var mlIsReady: Bool = false

    /// Acumulador de embeddings (256-d, flat row-major) — UM por janela fechada.
    /// Substitui completamente o antigo `data2DAccumulator` (feature maps por tick).
    /// Cap: 4000 janelas × 256d × 4 bytes ≈ 4 MB → cobre 4000 × 15s ≈ 16 h de coleta.
    private var embeddingsAccumulator: [Float] = []
    private var windowTimestamps: [Int64] = []
    private let embeddingsLock = NSLock()
    private let embeddingsCapWindows = 4000

    /// Fila serial dedicada ao pipeline TFC (window-buffering + inferência).
    /// Por quê: a inferência CoreML pode levar dezenas de ms; rodar na main
    /// causaria stutter a cada 15s (uma janela = 15s @ 20Hz). Por quê serial:
    /// `windowBuffer` é único — duas inferências em paralelo embaralhariam os
    /// snapshots. QoS `.userInitiated` (não `.background`) para o ANE não
    /// fazer scheduling adverso.
    private let tfcQueue = DispatchQueue(label: "com.movecollector.tfc.pipeline",
                                          qos: .userInitiated)

    // MARK: - Publicado para UI
    @Published var linkageMatrix: [[Float]] = []
    @Published var clusterLabels: [Int] = []
    @Published var episodes: [Episode] = []
    @Published var buffer: [[[Float]]] = []   // mantido para compatibilidade da UI

    /// Séries por grupo para o `CombinedSensorsChartView` — uma entrada por
    /// grupo (Accelerometer, Gyroscope), cada uma com a lista de samples
    /// (Date, valor médio dos canais do grupo) já downsampled para plot.
    /// Populado por `populateGroupSeries(forSession:)` após `runDailyClustering`.
    ///
    /// PORQUÊ struct e não `[(name:, samples:)]`: tuples com labels nomeados em
    /// @Published triggerizam stack overflow no MetadataCacheKey do runtime
    /// (EXC_BAD_ACCESS code=2 em libswiftCore.dylib). Struct nomeado evita.
//    @Published var groupSeries: [SensorGroupSeries] = []

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
            let extractor = try TFCFeatureExtractor()
            DispatchQueue.main.async {
                self.tfcExtractor = extractor
                self.mlIsReady = true
                self.mlStatusMessage = "TFC model loaded"
            }
        } catch {
            DispatchQueue.main.async {
                self.tfcExtractor = nil
                self.mlIsReady = false
                self.mlStatusMessage = "Failed to load TFC model: \(error.localizedDescription)"
            }
            print("[TFC] Model load error:", error)
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

        // Limpar buffers em memória — sync na tfcQueue para garantir que
        // não há inferência em curso quando zeramos `windowBuffer`.
        tfcQueue.sync {
            windowBuffer.removeAll(keepingCapacity: false)
            windowSampleTimestamps.removeAll(keepingCapacity: false)
        }

        // Embeddings + windowTimestamps NÃO são limpos aqui: ficam disponíveis
        // para `runDailyClustering` rodar pós-stop (uso normal: stop → cluster).
        // Limpeza explícita acontece em `resetEmbeddings()` (chamado pela UI
        // ao iniciar uma nova coleta, se desejado).

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

        // 2) UI updates + pipeline TFC — precisam de main queue por causa de @Published.
        // Snapshot do último GPS conhecido (cache no AppDelegate / LocationManager).
        // Por que aceitar zeros como fallback: o backbone foi treinado com 11
        // canais inteiros; passar NaN ou nil quebraria. Zeros após normalização
        // viram a média global do canal, que é o "comportamento neutro" mais
        // próximo de "sem informação".
        let snap = appDelegate?.lastGPSSnapshot
        let lat = snap?.latitude ?? 0
        let lon = snap?.longitude ?? 0
        let alt = snap?.altitude ?? 0
        let hAcc = snap?.horizontalAccuracy ?? 0
        let vAcc = snap?.verticalAccuracy ?? 0

        // UI updates → main queue (Published).
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.accelX = ax
            self.accelY = ay
            self.accelZ = az
            self.gyroX = gx
            self.gyroY = gy
            self.gyroZ = gz
            self.batteryLevel = battery
        }

        // Window buffering + TFC inference → fila serial dedicada.
        // Não atravessa a main queue → não causa jank a cada 15 s.
        tfcQueue.async { [weak self] in
            guard let self = self else { return }
            self.appendWindowSample(
                timestampMs: timestampMs,
                ax: ax, ay: ay, az: az,
                gx: gx, gy: gy, gz: gz,
                lat: lat, lon: lon, alt: alt, hAcc: hAcc, vAcc: vAcc
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

    // MARK: - Pipeline TFC (substitui o CNN antigo)
    //
    // PARIDADE COM PYTHON (FeatureExtractor):
    // - Janelas NÃO overlapping (step = window). O Python usa
    //   `step_size = window_size = 300` no FeatureExtractor.
    // - Por janela: feed `(x_t, x_f=|FFT|(x_t))` no backbone, lê `z_t`+`z_f`,
    //   concatena → embedding 256-d. Acumula um por janela.
    // - Timestamp da janela = ts da PRIMEIRA amostra da janela. Mantemos a
    //   mesma definição em `windowTimestamps` para que o EpisodeBuilder
    //   reproduza os boundaries do Python.

    /// Acumula um snapshot multi-canal (acc xyz + gyro xyz + GPS 5x).
    /// Quando o buffer fecha (= 300 amostras = 15 s @ 20 Hz), dispara
    /// `runTFCInferenceOnCurrentWindow` e zera buffer (próxima janela limpa).
    private func appendWindowSample(
        timestampMs: Int64,
        ax: Float, ay: Float, az: Float,
        gx: Float, gy: Float, gz: Float,
        lat: Float, lon: Float, alt: Float, hAcc: Float, vAcc: Float
    ) {
        // Snapshot na ordem canônica de SensorSchema.featureColumns:
        // [acc_x, acc_y, acc_z, gyro_x, gyro_y, gyro_z,
        //  latitude, longitude, altitude, horizontal_accuracy, vertical_accuracy]
        windowBuffer.append(ax)
        windowBuffer.append(ay)
        windowBuffer.append(az)
        windowBuffer.append(gx)
        windowBuffer.append(gy)
        windowBuffer.append(gz)
        windowBuffer.append(lat)
        windowBuffer.append(lon)
        windowBuffer.append(alt)
        windowBuffer.append(hAcc)
        windowBuffer.append(vAcc)
        windowSampleTimestamps.append(timestampMs)

        let nSamples = windowSampleTimestamps.count
        if nSamples >= appConstants.windowSize {
            // Captura a janela atual e zera. Step = window = sem overlap.
            // Por que copiar antes de zerar: a inferência pode ser despachada
            // pra outra fila no futuro; deixar imutável evita race conditions.
            let bufferCopy = windowBuffer
            let firstTs = windowSampleTimestamps[0]
            windowBuffer.removeAll(keepingCapacity: true)
            windowSampleTimestamps.removeAll(keepingCapacity: true)

            runTFCInferenceOnWindow(buffer: bufferCopy, windowStartMs: firstTs)
        }
    }

    /// Roda o TFC_Backbone sobre uma janela fechada (formato (T, C) flat) e
    /// armazena o embedding 256-d resultante + timestamp inicial da janela.
    ///
    /// IMPORTANTE: o buffer chega no layout (T, C) row-major (snapshots por
    /// tick). O `WindowedSensorDataset` internamente transpõe pra (W, C, T),
    /// que é o que o `TFC_Backbone` espera (shape `[1, 11, 300]`).
    private func runTFCInferenceOnWindow(buffer: [Float], windowStartMs: Int64) {
        guard mlIsReady, let extractor = tfcExtractor else {
            DispatchQueue.main.async { self.mlStatusMessage = "TFC model not ready" }
            return
        }
        let T = appConstants.windowSize

        // Constrói um WindowedSensorDataset de UMA janela só para reaproveitar
        // a API do extractor. Para uma janela, W = 1.
        let synthSensors = SensorTensor(
            timestamps: Array(repeating: windowStartMs, count: T),
            features: buffer,
            featureNames: SensorSchema.featureColumns
        )
        let dataset = WindowedSensorDataset(sensors: synthSensors,
                                            windowSize: T, stepSize: T)

        do {
            let emb = try extractor.embed(windowed: dataset)

            embeddingsLock.lock()
            embeddingsAccumulator.append(contentsOf: emb)
            windowTimestamps.append(windowStartMs)
            if windowTimestamps.count > embeddingsCapWindows {
                let overflow = windowTimestamps.count - embeddingsCapWindows
                windowTimestamps.removeFirst(overflow)
                embeddingsAccumulator.removeFirst(overflow * appConstants.embeddingDim)
            }
            let totalEmbedded = windowTimestamps.count
            embeddingsLock.unlock()

            DispatchQueue.main.async {
                self.mlStatusMessage = "Window \(totalEmbedded) embedded"
            }
        } catch {
            DispatchQueue.main.async {
                self.mlStatusMessage = "TFC inference error: \(error.localizedDescription)"
            }
        }
    }

    /// Zera os embeddings acumulados (chamar antes de uma nova coleta se
    /// não quiser misturar histórico).
    func resetEmbeddings() {
        embeddingsLock.lock()
        embeddingsAccumulator.removeAll(keepingCapacity: false)
        windowTimestamps.removeAll(keepingCapacity: false)
        embeddingsLock.unlock()
        DispatchQueue.main.async {
            self.episodes = []
            self.clusterLabels = []
            self.linkageMatrix = []
        }
    }

    // MARK: - Clustering (alimentado pelo embeddingsAccumulator do TFC)
    //
    // PARIDADE COM PYTHON (`compute_episodes` + Run_Daily_Clustering):
    // - Input: embeddings 256-d por janela (não amostras crus, não feature maps).
    // - Linkage: adjacente Ward via `Utils.linkageAdjacentWard(stopAtK: t)`.
    // - fcluster: `Utils.fclusterFromPartialZ` — labels 1..t por janela.
    // - Episode boundaries em ms: `EpisodeBuilder.episodesToMs` usa
    //   `windowStartTimestamps` (NÃO os timestamps de amostra), igual ao
    //   `dataset.window_timestamp(end_idx, 0)` do Python.

    func runDailyClustering(t: Int = 8) {
        // Despacha o cluster pesado para um background queue — Ward é O(N²)
        // mesmo com heap, e a UI não pode travar enquanto isso roda.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Cópia local sob lock para não bloquear a coleta.
            self.embeddingsLock.lock()
            let embSnapshot = self.embeddingsAccumulator
            let tsSnapshot = self.windowTimestamps
            self.embeddingsLock.unlock()

            let W = tsSnapshot.count
            let D = self.appConstants.embeddingDim

            guard W >= 2 else {
                DispatchQueue.main.async {
                    self.linkageMatrix = []
                    self.clusterLabels = []
                    self.episodes = []
                }
                print("[CLUSTERING] Janelas insuficientes (\(W))")
                return
            }

            print("[CLUSTERING] Ward em \(W) janelas, D=\(D)")

            let (episodes, labels) = EpisodeBuilder.computeEpisodes(
                embeddings: embSnapshot,
                W: W,
                D: D,
                windowStartTimestamps: tsSnapshot,
                numberOfEpisodes: t,
                utils: self.utils
            )

            // Para compat com a UI (linkageMatrix exposto), expor só o número
            // de linhas — re-gerar Z aqui seria desperdício porque já foi
            // computado dentro de computeEpisodes.
            let linkageRowCount = W - t

            DispatchQueue.main.async {
                self.linkageMatrix = [[Float]](repeating: [], count: max(0, linkageRowCount))
                self.clusterLabels = labels
                self.episodes = episodes
            }

            print("[CLUSTERING] Pronto. Clusters alvo: \(t), Labels: \(labels.count), Episódios: \(episodes.count)")

            // Recomputa groupSeries da última sessão para alimentar o
            // CombinedSensorsChartView. Roda na mesma fila background.
//            if let sid = self.lastSessionId {
//                self.populateGroupSeries(forSession: sid)
//            }
        }
    }

    // MARK: - Group series para o CombinedSensorsChartView
    //
    // PARIDADE COM PYTHON (`show_sensors_plotly`):
    // - Cada grupo é uma média dos canais (acc_x+acc_y+acc_z)/3, etc.
    // - O eixo X é tempo absoluto convertido para Date (timezone-aware no display).
    // - Tudo na resolução amostral da SessionReading (20 Hz @ coleta), mas
    //   downsampled para um cap (`targetPlotPoints`) para manter a UI responsiva.

    private let targetPlotPoints = 2000

    /// Lê SensorReading da sessão indicada, computa as séries por grupo (acc,
    /// gyro) e publica em `groupSeries`. Roda em background context.
//    func populateGroupSeries(forSession sessionId: UUID) {
//        let ctx = PersistenceController.shared.container.newBackgroundContext()
//        ctx.perform {
//            let req: NSFetchRequest<SensorReading> = SensorReading.fetchRequest()
//            req.predicate = NSPredicate(format: "sessionId == %@", sessionId as CVarArg)
//            req.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
//            req.returnsObjectsAsFaults = false
//            req.fetchBatchSize = 1000
//
////            guard let readings = try? ctx.fetch(req), !readings.isEmpty else {
////                DispatchQueue.main.async { self.groupSeries = [] }
////                return
////            }
//
//            let N = readings.count
//            let target = self.targetPlotPoints
//            // Downsample por janela fixa de média. Para coletas curtas (N <= target),
//            // window = 1 → vira identidade.
//            let window = max(1, N / target)
//
//            var accSamples: [SensorGroupSample] = []
//            var gyroSamples: [SensorGroupSample] = []
//            accSamples.reserveCapacity(N / window + 1)
//            gyroSamples.reserveCapacity(N / window + 1)
//
//            var i = 0
//            while i < N {
//                let end = min(N, i + window)
//                var accSum: Double = 0
//                var gyroSum: Double = 0
//                var tsSum: Double = 0
//                let k = end - i
//                for j in i..<end {
//                    let r = readings[j]
//                    accSum += Double(r.ax + r.ay + r.az) / 3.0
//                    gyroSum += Double(r.gx + r.gy + r.gz) / 3.0
//                    tsSum += Double(r.timestamp)
//                    // Libera fault — não precisamos manter o objeto carregado.
//                    ctx.refresh(r, mergeChanges: false)
//                }
//                let kd = Double(k)
//                let tsAvg = tsSum / kd
//                let date = Date(timeIntervalSince1970: tsAvg / 1000.0)
//                accSamples.append(SensorGroupSample(timestamp: date,
//                                                    value: accSum / kd,
//                                                    group: "Accelerometer"))
//                gyroSamples.append(SensorGroupSample(timestamp: date,
//                                                     value: gyroSum / kd,
//                                                     group: "Gyroscope"))
//                i = end
//            }
//
//            let series: [SensorGroupSeries] = [
//                SensorGroupSeries(name: "Accelerometer", samples: accSamples),
//                SensorGroupSeries(name: "Gyroscope",     samples: gyroSamples),
//            ]
//
//            DispatchQueue.main.async {
//                self.groupSeries = series
//            }
//            print("[GROUPSERIES] Pronto: \(accSamples.count) pontos por grupo (window=\(window), N=\(N))")
//        }
//    }

    // MARK: - GPS points by episode (alimenta EpisodesMapView)
    //
    // PARIDADE COM PYTHON (`generate_map`):
    // - Para cada episódio, recortar pontos GPS cujo timestamp está em
    //   [ep.startMs, ep.endMs].
    // - Colorir pelo label do episódio (mesma paleta = mesmo índice).
    //
    // Implementação: lê LocationEntity da sessão via fetchContext background
    // (evita travar a UI). Retorna pontos prontos para serem passados ao
    // EpisodesMapView.

    func gatherEpisodePoints(forSession sessionId: UUID) async -> [EpisodePoint] {
        let episodesSnapshot: [Episode] = await MainActor.run { self.episodes }
        guard !episodesSnapshot.isEmpty else { return [] }

        return await withCheckedContinuation { continuation in
            let ctx = PersistenceController.shared.container.newBackgroundContext()
            ctx.perform {
                let req: NSFetchRequest<LocationEntity> = LocationEntity.fetchRequest()
                req.predicate = NSPredicate(format: "sessionId == %@", sessionId as CVarArg)
                req.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
                req.returnsObjectsAsFaults = false
                guard let locs = try? ctx.fetch(req) else {
                    continuation.resume(returning: [])
                    return
                }

                // Atribui label de episódio por bisecção sobre o array ORDENADO de
                // (startMs, endMs, label). Como os episódios são monotônicos no tempo,
                // basta um ponteiro avançando — O(W + Loc).
                var sortedEps = episodesSnapshot
                sortedEps.sort { $0.startMs < $1.startMs }

                var pts: [EpisodePoint] = []
                pts.reserveCapacity(locs.count)
                var epIdx = 0

                for loc in locs {
                    let ts = loc.timestamp
                    // Avança até encontrar um episódio cujo end >= ts.
                    while epIdx < sortedEps.count && sortedEps[epIdx].endMs < ts {
                        epIdx += 1
                    }
                    guard epIdx < sortedEps.count else { break }
                    let ep = sortedEps[epIdx]
                    guard ts >= ep.startMs else {
                        // Buraco entre episódios — pular este ponto.
                        continue
                    }
                    pts.append(EpisodePoint(
                        coordinate: CLLocationCoordinate2D(
                            latitude: CLLocationDegrees(loc.latitude),
                            longitude: CLLocationDegrees(loc.longitude)
                        ),
                        label: ep.label,
                        timestampMs: ts
                    ))
                }
                continuation.resume(returning: pts)
            }
        }
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
