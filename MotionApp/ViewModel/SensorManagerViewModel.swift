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
//  Refatorado (Etapa E — TFC migration monolítica) — 2026-05-22:
//  - Removido: CNN_PFF_2D_backbone + data2D + data2DAccumulator
//  - Adicionado: TFCFeatureExtractor monolítico (11ch → 256d) + GPS como canal
//  - Adicionado: windowTimestamps + episode boundaries em ms
//
//  Refatorado (Etapa F — TFC particionado) — 2026-05-27:
//  - Substituído: TFCFeatureExtractor monolítico por 3 backbones particionados
//    (Acc 3ch, Gyro 3ch, GPS 3ch — lat/lon/alt apenas).
//  - Embedding por janela: 768d (concat das 3 partições × 256d cada).
//  - API pública do extractor inalterada: ViewModel não precisa mudar nada
//    além de ler `appConstants.embeddingDim` que agora retorna 768.
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

    /// Sessão que a tela de coleta AO VIVO deve exibir (mapa/gráfico): a coleta
    /// em andamento se houver uma, senão a última encerrada. Antes a UI usava só
    /// `lastSessionId`, que durante uma coleta ativa ainda apontava para a sessão
    /// ANTERIOR — então mapa/gráfico mostravam dados da coleta passada.
    var displaySessionId: UUID? { currentSessionId ?? lastSessionId }

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

    /// Acumulador de **janelas cruas** — cada entrada tem `windowSize * nChannels`
    /// floats no layout (T, C) row-major, exatamente como `windowBuffer` quando
    /// fecha. A inferência TFC é deferida pra `runDailyClustering` porque
    /// precisa de μ/σ globais da sessão (paridade com `normalize_features` do
    /// Python aplicado ANTES do windowing).
    ///
    /// Cap: 4000 janelas × 3300 floats × 4 bytes ≈ 50 MB → cobre 4000 × 15s ≈ 16 h.
    /// (Antes era cap em embeddings de 256d = ~4 MB; agora guardamos os 11 canais
    /// crus que valem ~13× mais. Memória continua aceitável para iPhone.)
    private var rawWindowsAccumulator: [[Float]] = []
    private var windowTimestamps: [Int64] = []
    private let embeddingsLock = NSLock()
    private let embeddingsCapWindows = 4000

    /// Bookkeeping de warm-up: conta TODAS as janelas completas processadas nesta
    /// coleta (incluindo as descartadas). Só mutado dentro de `tfcQueue` (serial),
    /// então não precisa de lock próprio. Reset em `startCollection()` /
    /// `resetEmbeddings()`.
    ///
    /// CRITICAL — NÃO REMOVER (ver AppConstants.warmupWindowCount): enquanto este
    /// contador for <= `appConstants.warmupWindowCount`, a janela é IGNORADA para
    /// acumulação. Isso descarta os artefatos de startup (toque no botão Start,
    /// warm-up da CoreMotion, estabilização do GPS, usuário guardando o telefone)
    /// que, sem o descarte, viram um cluster singleton espúrio e divergem do
    /// notebook Python.
    private var completedWindowsSeen: Int = 0

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

    /// Número de janelas CRUAS acumuladas (cada uma = 300 amostras = 15s).
    /// A UI usa isto para mostrar "X janelas coletadas (≈Y min)" e calcular
    /// o range válido de K para o Stepper de "episódios alvo".
    @Published var windowCount: Int = 0
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

        // Cada coleta ao vivo começa do zero: descarta janelas/episódios que
        // sobraram da coleta anterior (ou de uma recuperação). Sem isto, a 2ª
        // coleta herdava `rawWindowsAccumulator`/`episodes` da 1ª e os episódios
        // misturavam janelas de sessões diferentes.
        resetEmbeddings()

        currentSessionId = sessionId
        appDelegate?.currentSessionId = sessionId
        print("🎯 Nova sessão de coleta: \(sessionId.uuidString)")

        // WARM-UP: zera o contador a cada início de coleta. Cada coleta tem seu
        // próprio transiente de startup (toque no Start + reposicionamento do
        // telefone), então o descarte das primeiras `warmupWindowCount` janelas
        // tem que valer por coleta — não só na primeira da vida do app.
        // Feito na tfcQueue (serial) para não competir com appendWindowSample.
        tfcQueue.async { [weak self] in
            self?.completedWindowsSeen = 0
        }

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
        // Por que `.utility` e não `.background`:
        // .background é o menor nível de prioridade do iOS — o scheduler
        // pode coalescer / atrasar / throttle o timer livremente sob qualquer
        // carga concorrente. Resultado prático observado: a 20 Hz nominal,
        // o timer entrega ~10 Hz reais, e cada "janela de 300 amostras"
        // acaba cobrindo ~30s de tempo real em vez de 15s.
        // .utility é "operação longa, importante, mas não interativa" —
        // exatamente o caso de sampling contínuo de sensores. O timer
        // não vai ser preempt-ado por trabalho de UI nem coalescido com
        // outras tasks de background.
        //
        // `leeway: 5 ms` dá ao scheduler folga pra alinhar com outros
        // timers e poupar bateria sem comprometer a frequência alvo.
        collectionTimer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility)
        )
        collectionTimer?.schedule(
            deadline: .now(),
            repeating: appConstants.sensorUpdateInterval,
            leeway: .milliseconds(5)
        )
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

    // MARK: - Pipeline TFC particionada
    //
    // PARIDADE COM PYTHON (FeatureExtractor._partitioned_call):
    // - Janelas NÃO overlapping (step = window = 300 samples = 15s @ 20Hz).
    // - Para cada janela cru, 3 backbones independentes processam fatias
    //   distintas de canais:
    //     • Acc backbone:  canais [0,1,2] (acc_x/y/z)
    //     • Gyro backbone: canais [3,4,5] (gyro_x/y/z)
    //     • GPS backbone:  canais [6,7,8] (lat/lon/alt — hAcc/vAcc NÃO entram)
    // - Cada backbone consome `(x_t, x_f=|FFT|(x_t))` shape [1, 3, 300]
    //   e devolve `(z_t, z_f)` de 128d cada. Concatenamos as 3 partições →
    //   embedding final 768d (3 × 256).
    // - Timestamp da janela = ts da PRIMEIRA amostra da janela.

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
            let bufferCopy = windowBuffer
            let firstTs = windowSampleTimestamps[0]
            windowBuffer.removeAll(keepingCapacity: true)
            windowSampleTimestamps.removeAll(keepingCapacity: true)

            // WARM-UP — CRITICAL, NÃO REMOVER (ver AppConstants.warmupWindowCount).
            //
            // Conta a janela para bookkeeping ANTES de decidir acumular. As
            // primeiras `warmupWindowCount` janelas completas são DESCARTADAS:
            // elas concentram artefatos de startup (toque no botão Start, warm-up
            // da CoreMotion, estabilização do GPS, usuário guardando o telefone)
            // que, se acumulados, viram um cluster singleton espúrio no Ward e
            // afastam o resultado do notebook Python. A janela descartada é
            // contada aqui, mas NÃO entra em `rawWindowsAccumulator`.
            //
            // Exemplo (warmupWindowCount = 1):
            //   • Janela #1 → completedWindowsSeen vira 1, 1 <= 1 → ignorada.
            //   • Janela #2 → completedWindowsSeen vira 2, 2 > 1  → acumulada.
            completedWindowsSeen += 1
            let warmup = appConstants.warmupWindowCount
            if completedWindowsSeen <= warmup {
                let seen = completedWindowsSeen
                DispatchQueue.main.async {
                    self.mlStatusMessage =
                        "Warm-up: janela \(seen)/\(warmup) descartada (artefatos de startup)"
                }
                return
            }

            // NÃO roda TFC aqui. Acumula a janela CRUA — a normalização global
            // (μ/σ por canal sobre toda a sessão) só pode ser calculada quando
            // todas as janelas estiverem em mãos. Isso bate exatamente com o
            // Python: `normalize_features(sensors.features, "standard")` é
            // aplicado ANTES do windowing.
            embeddingsLock.lock()
            rawWindowsAccumulator.append(bufferCopy)
            windowTimestamps.append(firstTs)
            // Cap rolling — descarta janelas mais antigas se exceder.
            if windowTimestamps.count > embeddingsCapWindows {
                let overflow = windowTimestamps.count - embeddingsCapWindows
                windowTimestamps.removeFirst(overflow)
                rawWindowsAccumulator.removeFirst(overflow)
            }
            let total = windowTimestamps.count
            embeddingsLock.unlock()

            DispatchQueue.main.async {
                self.windowCount = total
                self.mlStatusMessage = "Janela \(total) acumulada (crua, sem TFC)"
            }
        }
    }

    /// Detecta TODAS as janelas em que TODA a janela tem `hAcc <= 0` (= sem
    /// fix de GPS) e backfilla os 5 canais GPS dessas janelas. Modifica
    /// `windows` in-place.
    ///
    /// FIX B (2026-05-27): a versão anterior só preenchia janelas no PREFIXO
    /// da sessão (todas antes do primeiro fix). Quedas de GPS no MEIO da
    /// coleta (túnel, prédio no meio do trajeto, transporte público
    /// subterrâneo) continuavam zeradas — o que reintroduzia a distribuição
    /// bimodal degenerada e gerava embedding constante no bloco do meio,
    /// causando split/merge espúrio na fronteira.
    ///
    /// Estratégia agora: **forward-fill** com último GPS válido conhecido.
    /// Para janelas no PREFIXO (sem fix anterior), usa média dos primeiros
    /// fixes vindouros (backward-fill como aproximação inicial). Pra quedas
    /// no meio, usa o último fix conhecido — assume continuidade espacial,
    /// o que é razoável: nas escalas de tempo onde GPS some (segundos a
    /// minutos), o usuário não teleporta.
    private func backfillPreFixGPSWindows(_ windows: inout [[Float]], W: Int) {
        let T = appConstants.windowSize
        let C = appConstants.nChannels
        let hAccCol = 9   // horizontal_accuracy (offset dentro de cada amostra)

        // Helper: a janela `w` tem pelo menos um sample com fix?
        @inline(__always)
        func windowHasFix(_ w: [Float]) -> Bool {
            for t in 0..<T where w[t * C + hAccCol] > 0 { return true }
            return false
        }

        // Helper: média dos 5 canais GPS sobre os ticks com fix nessa janela.
        // Retorna nil se a janela não tem nenhum tick com fix.
        @inline(__always)
        func meanGPSOfWindow(_ w: [Float]) -> (Float, Float, Float, Float, Float)? {
            var sLat = 0.0, sLon = 0.0, sAlt = 0.0, sHAcc = 0.0, sVAcc = 0.0
            var n = 0
            for t in 0..<T where w[t * C + hAccCol] > 0 {
                sLat += Double(w[t * C + 6])
                sLon += Double(w[t * C + 7])
                sAlt += Double(w[t * C + 8])
                sHAcc += Double(w[t * C + 9])
                sVAcc += Double(w[t * C + 10])
                n += 1
            }
            guard n > 0 else { return nil }
            let inv = 1.0 / Double(n)
            return (Float(sLat * inv), Float(sLon * inv), Float(sAlt * inv),
                    Float(sHAcc * inv), Float(sVAcc * inv))
        }

        // 1) Estatísticas de diagnóstico + localizar o primeiro fix.
        var totalMissing = 0
        var firstWindowWithFix: Int? = nil
        for wIdx in 0..<W {
            if windowHasFix(windows[wIdx]) {
                if firstWindowWithFix == nil { firstWindowWithFix = wIdx }
            } else {
                totalMissing += 1
            }
        }

        guard let firstIdx = firstWindowWithFix else {
            print("[GPS DIAG] ⚠️ W=\(W), NENHUMA janela tem GPS válido — "
                  + "modelo vai operar só com acc/gyro normalizados.")
            return
        }

        // 2) Computar GPS "seed" pro PREFIXO (média das primeiras 10 janelas
        //    com fix — janelas iniciais com fix tendem a ter coordenadas bem
        //    estabilizadas no ponto de partida do usuário).
        var sumLat = 0.0, sumLon = 0.0, sumAlt = 0.0
        var sumHAcc = 0.0, sumVAcc = 0.0
        var seedN = 0
        for wIdx in firstIdx..<min(firstIdx + 10, W) {
            if let m = meanGPSOfWindow(windows[wIdx]) {
                sumLat += Double(m.0); sumLon += Double(m.1); sumAlt += Double(m.2)
                sumHAcc += Double(m.3); sumVAcc += Double(m.4)
                seedN += 1
            }
        }
        var lastValid: (Float, Float, Float, Float, Float)
        if seedN > 0 {
            let inv = 1.0 / Double(seedN)
            lastValid = (Float(sumLat * inv), Float(sumLon * inv),
                         Float(sumAlt * inv),
                         Float(sumHAcc * inv), Float(sumVAcc * inv))
        } else {
            // Não deveria acontecer (firstIdx existe → meanGPSOfWindow nele
            // retorna não-nil), mas guard defensivo.
            return
        }

        let preFixCount = firstIdx       // janelas no prefixo
        let midGapCount = totalMissing - preFixCount
        print("[GPS DIAG] W=\(W), janelas sem GPS = \(totalMissing) "
              + "(prefixo: \(preFixCount), mid-session: \(midGapCount)), "
              + "1º fix: janela \(firstIdx). Seed (média de \(seedN) janelas): "
              + "lat=\(lastValid.0) lon=\(lastValid.1) alt=\(lastValid.2)")

        // 3) Forward-fill com último GPS válido conhecido.
        //    - Pré-fix: usa seed (backward-fill efetivo) até alcançar firstIdx.
        //    - Mid-gap: usa o último fix observado antes do gap.
        var backfilledPrefix = 0
        var backfilledMid = 0
        for wIdx in 0..<W {
            if windowHasFix(windows[wIdx]) {
                // Janela com fix → atualiza "última leitura válida" e segue.
                if let m = meanGPSOfWindow(windows[wIdx]) {
                    lastValid = m
                }
            } else {
                // Janela sem fix → preenche com `lastValid`.
                for t in 0..<T {
                    windows[wIdx][t * C + 6] = lastValid.0
                    windows[wIdx][t * C + 7] = lastValid.1
                    windows[wIdx][t * C + 8] = lastValid.2
                    windows[wIdx][t * C + 9] = lastValid.3
                    windows[wIdx][t * C + 10] = lastValid.4
                }
                if wIdx < firstIdx { backfilledPrefix += 1 }
                else { backfilledMid += 1 }
            }
        }

        print("[GPS BACKFILL] Preenchidas \(backfilledPrefix) janelas no prefixo "
              + "+ \(backfilledMid) janelas no meio da sessão "
              + "(total = \(backfilledPrefix + backfilledMid))")
    }

    /// Aplica `normalize_features("standard")` Python: para cada canal `c`,
    /// computa μ_c, σ_c sobre TODAS as amostras de TODAS as janelas, e
    /// transforma cada valor em `(x - μ_c) / σ_c`. Devolve janelas normalizadas
    /// no MESMO layout (T, C) row-major.
    ///
    /// Por quê: o TFC_Backbone foi treinado em features standardizadas globalmente
    /// (μ=0, σ=1 por canal sobre a sessão inteira). Sem isso, os canais GPS
    /// (latitude ~-23, altitude ~700) dominam o input em magnitude e empurram as
    /// BatchNorms internas para fora da distribuição que viram no treino — o
    /// embedding fica essencialmente uma projeção do GPS, ignorando acc/gyro.
    private func normalizeWindowsSessionWide(_ windows: [[Float]]) -> [[Float]] {
        let T = appConstants.windowSize
        let C = appConstants.nChannels
        guard !windows.isEmpty else { return [] }

        // Pass 1: somas por canal e somas-de-quadrados → μ e σ populacional
        // (ddof=0, igual ao numpy.std default usado por `normalize_features`).
        var sum = [Double](repeating: 0, count: C)
        var sumSq = [Double](repeating: 0, count: C)
        var N: Int = 0
        for w in windows {
            for t in 0..<T {
                for c in 0..<C {
                    let v = Double(w[t * C + c])
                    sum[c] += v
                    sumSq[c] += v * v
                }
            }
            N += T
        }
        let invN = 1.0 / Double(N)
        var mu = [Float](repeating: 0, count: C)
        var sd = [Float](repeating: 1, count: C)
        for c in 0..<C {
            let m = sum[c] * invN
            var v = sumSq[c] * invN - m * m
            if v < 0 { v = 0 }
            let s = sqrt(v)
            mu[c] = Float(m)
            sd[c] = s == 0 ? 1 : Float(s)
        }
        print("[NORMALIZE] N=\(N) samples, C=\(C) canais")
        for c in 0..<C {
            print("  ch \(SensorSchema.featureColumns[c]): μ=\(mu[c]) σ=\(sd[c])")
        }

        // Pass 2: aplica (x - μ) / σ por canal.
        var out = [[Float]]()
        out.reserveCapacity(windows.count)
        for w in windows {
            var nw = w   // copy
            for t in 0..<T {
                for c in 0..<C {
                    let idx = t * C + c
                    nw[idx] = (nw[idx] - mu[c]) / sd[c]
                }
            }
            out.append(nw)
        }
        return out
    }

    /// Roda inferência TFC PARTICIONADA numa única janela JÁ NORMALIZADA
    /// (layout T,C row-major, 11 canais). Devolve embedding 768d flat
    /// (concat das 3 partições — Acc, Gyro, GPS — cada uma com 256d).
    private func embedSingleNormalizedWindow(_ buffer: [Float], windowStartMs: Int64) -> [Float]? {
        guard let extractor = tfcExtractor else { return nil }
        let T = appConstants.windowSize

        let synthSensors = SensorTensor(
            timestamps: Array(repeating: windowStartMs, count: T),
            features: buffer,
            featureNames: SensorSchema.featureColumns
        )
        let dataset = WindowedSensorDataset(sensors: synthSensors,
                                            windowSize: T, stepSize: T)
        do {
            return try extractor.embed(windowed: dataset)
        } catch {
            print("[TFC] embed error: \(error)")
            return nil
        }
    }

    /// Zera as janelas cruas acumuladas (chamar antes de uma nova coleta se
    /// não quiser misturar histórico).
    func resetEmbeddings() {
        embeddingsLock.lock()
        rawWindowsAccumulator.removeAll(keepingCapacity: false)
        windowTimestamps.removeAll(keepingCapacity: false)
        embeddingsLock.unlock()
        // WARM-UP: reinicia o bookkeeping para que a próxima janela volte a ser
        // tratada como janela de startup (descartada). Serial na tfcQueue.
        tfcQueue.async { [weak self] in
            self?.completedWindowsSeen = 0
        }
        DispatchQueue.main.async {
            self.episodes = []
            self.clusterLabels = []
            self.linkageMatrix = []
            self.windowCount = 0
        }
    }

    // MARK: - Clustering (a partir das janelas cruas + normalização global)
    //
    // PARIDADE COM PYTHON (`FeatureExtractor.__init__` + `__call__` + `Run_Daily_Clustering`):
    //  1. `normalize_features(sensors.features, "standard")` — μ/σ por canal
    //     sobre a sessão inteira (todas as amostras de todas as janelas).
    //  2. Para cada janela normalizada, roda OS 3 backbones particionados
    //     (Acc, Gyro, GPS) e concatena os embeddings → 768d.
    //  3. `linkage_adjacent_ward(stopAtK)` + `fcluster_custom` sobre os embeddings.
    //  4. `get_start_end_label` + `episode_to_ms` produzem `[Episode]`.

    func runDailyClustering(t: Int = 8) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 1) Snapshot atômico das janelas cruas + timestamps.
            self.embeddingsLock.lock()
            let rawWindows = self.rawWindowsAccumulator
            let tsSnapshot = self.windowTimestamps
            self.embeddingsLock.unlock()

            // Pipeline compartilhado com a recuperação a partir do disco.
            self.clusterRawWindows(rawWindows, timestamps: tsSnapshot, t: t)
        }
    }

    /// Núcleo PURO do clustering, compartilhado entre a coleta ao vivo
    /// (`clusterRawWindows`) e a recuperação/upload (`clusterStoreDetached`).
    /// Recebe as janelas CRUAS já snapshotadas (11 canais × windowSize, layout
    /// T×C row-major) e seus timestamps de início. Roda: backfill GPS pré-fix →
    /// normalização global → inferência TFC por janela → linkage Ward + episódios
    /// e DEVOLVE o resultado (não publica em @Published nem toca estado
    /// compartilhado — só atualiza o texto de progresso `mlStatusMessage`).
    ///
    /// DEVE rodar numa fila de background (os callers já despacham para
    /// `.global(qos: .userInitiated)`); contém I/O de inferência pesado.
    private func computeEpisodesFromWindows(_ rawWindows: [[Float]],
                                            timestamps tsSnapshot: [Int64],
                                            t: Int)
        -> (episodes: [Episode], labels: [Int], linkageRows: Int)? {
            let W = tsSnapshot.count

            guard W >= 2 else {
                DispatchQueue.main.async {
                    self.mlStatusMessage = "Janelas insuficientes (\(W)) — colete por mais tempo"
                }
                print("[CLUSTERING] Janelas insuficientes (\(W))")
                return nil
            }

            // 1.5) DIAGNÓSTICO + BACKFILL de janelas pré-fix de GPS.
            //
            // Por que: quando a coleta começa dentro de um prédio/academia,
            // o GPS pode demorar muito (ou nunca) pegar fix. Nesses ticks
            // o `lastGPSSnapshot` é nil → usamos zeros, e a 1ª etapa de
            // normalização vê uma distribuição bimodal degenerada (muitos
            // zeros + alguns valores reais), produzindo embeddings constantes
            // pro bloco pré-fix → linkage agrupa tudo num cluster gigante.
            //
            // Mitigação: detectar janelas em que TODA a janela tem hAcc <= 0
            // (= sem fix), e preenche TODOS os 5 canais GPS dessas janelas
            // com a média dos valores das primeiras janelas COM fix. Não é
            // paridade exata com Python (que carrega CSV onde GPS pode estar
            // vazio e provavelmente filtra), mas evita o sintoma do "mega-bloco".
            var windowsToProcess = rawWindows   // cópia mutável
            self.backfillPreFixGPSWindows(&windowsToProcess, W: W)

            // Sanity check da frequência REAL de sampling. Cada janela
            // deveria ter `windowSize/sensorFrequencyHz = 15s` em tempo
            // real. Se o tempo entre tsSnapshot[0] e tsSnapshot[W-1] dividido
            // por (W-1) der muito diferente de 15s, o timer não está
            // entregando na taxa nominal — sintoma típico de QoS errada.
            if W >= 2 {
                let spanMs = tsSnapshot.last! - tsSnapshot.first!
                let avgWindowSec = Double(spanMs) / Double(max(1, W - 1)) / 1000.0
                let nominal = Double(self.appConstants.windowSize)
                          / self.appConstants.sensorFrequencyHz
                let ratio = avgWindowSec / nominal
                print(String(format: "[TIMER] Janela média: %.1fs real vs %.1fs nominal "
                             + "(ratio = %.2fx). Esperado: ratio ≈ 1.00",
                             avgWindowSec, nominal, ratio))
            }

            // 2) Normalização global por canal (paridade exata com Python).
            print("[CLUSTERING] Normalizando \(W) janelas (μ/σ por canal sobre a sessão)")
            let normalizedWindows = self.normalizeWindowsSessionWide(windowsToProcess)

            // 3) Inferência TFC janela a janela. Para coleta de 2h ≈ 480 janelas;
            // cada inferência ~10-50ms no ANE → ~5-25s total. Aceitável como
            // operação on-demand.
            let D = self.appConstants.embeddingDim
            var embeddings = [Float]()
            embeddings.reserveCapacity(W * D)
            var skipped = 0
            for (i, w) in normalizedWindows.enumerated() {
                if let emb = self.embedSingleNormalizedWindow(w, windowStartMs: tsSnapshot[i]) {
                    embeddings.append(contentsOf: emb)
                } else {
                    // Não pula silenciosamente — falha de inferência em UMA janela
                    // quebra o alinhamento com `windowTimestamps`. Aborta clustering.
                    skipped += 1
                }
                if (i + 1) % 50 == 0 {
                    DispatchQueue.main.async {
                        self.mlStatusMessage = "TFC: \(i + 1)/\(W) janelas"
                    }
                }
            }
            guard skipped == 0, embeddings.count == W * D else {
                DispatchQueue.main.async {
                    self.mlStatusMessage = "Inferência TFC falhou em \(skipped) janela(s)"
                }
                print("[CLUSTERING] Abortado — \(skipped) inferências falharam")
                return nil
            }

            // Sanity: range dos embeddings depois da normalização correta. Se
            // ainda saírem em escala absurda, há outro problema (e.g., μ/σ
            // mal-computado, ou input vindo torto pro modelo).
            let eMin = embeddings.min() ?? 0
            let eMax = embeddings.max() ?? 0
            print("[CLUSTERING] Embeddings prontos: W=\(W), D=\(D), range=[\(eMin), \(eMax)]")

            // 4) Linkage adjacente Ward + fcluster + episodes em ms.
            let (episodes, labels) = EpisodeBuilder.computeEpisodes(
                embeddings: embeddings,
                W: W,
                D: D,
                windowStartTimestamps: tsSnapshot,
                numberOfEpisodes: t,
                utils: self.utils
            )

            let linkageRowCount = W - t

            DispatchQueue.main.async {
                self.mlStatusMessage = "Pronto: \(episodes.count) episódios"
            }

            print("[CLUSTERING] Pronto. K=\(t), W=\(W), episódios=\(episodes.count)")
            return (episodes, labels, linkageRowCount)
    }

    /// Coleta AO VIVO: roda o núcleo puro e PUBLICA nos @Published do estado vivo
    /// (mapa/segmentação da home). Mantido com este nome por compat com
    /// `runDailyClustering`.
    private func clusterRawWindows(_ rawWindows: [[Float]], timestamps tsSnapshot: [Int64], t: Int) {
        guard let result = computeEpisodesFromWindows(rawWindows, timestamps: tsSnapshot, t: t) else {
            DispatchQueue.main.async {
                self.linkageMatrix = []
                self.clusterLabels = []
                self.episodes = []
            }
            return
        }
        DispatchQueue.main.async {
            self.linkageMatrix = [[Float]](repeating: [], count: max(0, result.linkageRows))
            self.clusterLabels = result.labels
            self.episodes = result.episodes
        }
    }

    // MARK: - Recuperação a partir do disco (reconstrução de janelas)
    //
    // Permite recomputar episódios de uma coleta JÁ PERSISTIDA — mesmo após o
    // BGTask ter sido terminado pelo sistema e o estado em memória
    // (`rawWindowsAccumulator`) ter sido perdido. Reconstrói as janelas cruas a
    // partir de SensorReading (+ GPS de LocationEntity) e alimenta o MESMO
    // pipeline da coleta ao vivo, garantindo paridade.

    /// Reconstrói as janelas cruas (11 canais × `windowSize`) e seus timestamps
    /// de início a partir do que está persistido para `sessionId`, reproduzindo
    /// fielmente o windowing ao vivo de `appendWindowSample`:
    ///   - merge GPS por two-pointer (último fix com ts <= amostra; zeros antes
    ///     do 1º fix, idêntico a `lastGPSSnapshot ?? 0`);
    ///   - ordem dos canais: ax, ay, az, gx, gy, gz, lat, lon, alt, hAcc, vAcc;
    ///   - janelas de `windowSize` amostras consecutivas (descarta a janela
    ///     parcial final, como o buffer ao vivo);
    ///   - descarta as primeiras `warmupWindowCount` janelas (warm-up por coleta).
    /// Roda dentro do `ctx.performAndWait` do chamador.
    private func rebuildWindowsFromStore(sessionId: UUID,
                                         ctx: NSManagedObjectContext)
        -> (windows: [[Float]], timestamps: [Int64]) {

        let windowSize = appConstants.windowSize
        let warmup = appConstants.warmupWindowCount

        // GPS da sessão, materializado uma vez (acesso O(1) no merge).
        let locFetch: NSFetchRequest<LocationEntity> = LocationEntity.fetchRequest()
        locFetch.predicate = NSPredicate(format: "sessionId == %@", sessionId as CVarArg)
        locFetch.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        locFetch.returnsObjectsAsFaults = false
        let locations = (try? ctx.fetch(locFetch)) ?? []

        // Amostras de sensor da sessão, streaming via fetchBatchSize.
        let sensorFetch: NSFetchRequest<SensorReading> = SensorReading.fetchRequest()
        sensorFetch.predicate = NSPredicate(format: "sessionId == %@", sessionId as CVarArg)
        sensorFetch.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        sensorFetch.fetchBatchSize = 500
        guard let sensors = try? ctx.fetch(sensorFetch), !sensors.isEmpty else {
            return ([], [])
        }

        var windows: [[Float]] = []
        var timestamps: [Int64] = []
        var current: [Float] = []
        current.reserveCapacity(windowSize * appConstants.nChannels)
        var currentFirstTs: Int64 = 0
        var completedWindows = 0
        var locIdx = -1   // -1 = ainda sem GPS para esta amostra (pré-fix)

        for sensor in sensors {
            let ts = sensor.timestamp
            // Avança locIdx enquanto a PRÓXIMA location tem ts <= amostra.
            while locIdx + 1 < locations.count
                  && locations[locIdx + 1].timestamp <= ts {
                locIdx += 1
            }
            if current.isEmpty { currentFirstTs = ts }

            current.append(sensor.ax)
            current.append(sensor.ay)
            current.append(sensor.az)
            current.append(sensor.gx)
            current.append(sensor.gy)
            current.append(sensor.gz)
            if locIdx >= 0 {
                let loc = locations[locIdx]
                current.append(loc.latitude)
                current.append(loc.longitude)
                current.append(loc.altitude)
                current.append(loc.horizontalAccuracy)
                current.append(loc.verticalAccuracy)
            } else {
                // Pré-fix: zeros nos 5 canais GPS (paridade com lastGPSSnapshot ?? 0).
                current.append(0); current.append(0); current.append(0)
                current.append(0); current.append(0)
            }

            if current.count == windowSize * appConstants.nChannels {
                completedWindows += 1
                // Warm-up: descarta as primeiras `warmup` janelas completas.
                if completedWindows > warmup {
                    windows.append(current)
                    timestamps.append(currentFirstTs)
                }
                current.removeAll(keepingCapacity: true)
            }
            ctx.refresh(sensor, mergeChanges: false)
        }

        for loc in locations { ctx.refresh(loc, mergeChanges: false) }
        return (windows, timestamps)
    }

    /// Recuperação/Upload (DETACHED): reconstrói as janelas da sessão a partir do
    /// disco e computa os episódios SEM tocar nenhum estado compartilhado da
    /// coleta ao vivo (`episodes`, `rawWindowsAccumulator`, `windowTimestamps`,
    /// `lastSessionId`, `windowCount`, `clusterLabels`, `linkageMatrix`). Os
    /// resultados são entregues via `completion` para a tela de recuperação
    /// guardá-los localmente. É isto que separa de verdade "coleta atual" de
    /// "coleta de upload": uma não corrompe mais a outra.
    ///
    /// `completion` roda na main queue (sucesso ou falha).
    func clusterStoreDetached(sessionId: UUID, t: Int = 8,
                              completion: @escaping (_ episodes: [Episode], _ labels: [Int]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([], []) }
                return
            }

            DispatchQueue.main.async {
                self.mlStatusMessage = "Recuperando janelas do disco…"
            }

            let ctx = PersistenceController.shared.container.newBackgroundContext()
            var rebuilt: (windows: [[Float]], timestamps: [Int64]) = ([], [])
            ctx.performAndWait {
                rebuilt = self.rebuildWindowsFromStore(sessionId: sessionId, ctx: ctx)
            }

            let W = rebuilt.timestamps.count
            print("[RECOVERY] Sessão \(sessionId.uuidString.prefix(8))… → \(W) janelas reconstruídas (detached)")

            guard W >= 2,
                  let result = self.computeEpisodesFromWindows(rebuilt.windows,
                                                               timestamps: rebuilt.timestamps,
                                                               t: t) else {
                DispatchQueue.main.async {
                    self.mlStatusMessage = "Janelas insuficientes (\(W)) nesta coleta"
                    completion([], [])
                }
                return
            }

            DispatchQueue.main.async { completion(result.episodes, result.labels) }
        }
    }

    // MARK: - Group series para o CombinedSensorsChartView
    //
    // PARIDADE COM PYTHON (`show_sensors_plotly` chamado com normalization="standard"):
    // - Grupos de visualização do run_local.py: acc=[acc_x,acc_y,acc_z],
    //   gyro=[gyro_x,gyro_y,gyro_z], GPS=[latitude,longitude].
    // - O script PADRONIZA cada canal antes de mediar: `feats =
    //   normalize_features(features, "standard")` faz z = (x-μ)/σ por canal sobre
    //   a sessão inteira, e então `avg = feats[:, idx].mean(axis=1)` media os
    //   canais do grupo. Reproduzimos EXATAMENTE isso (ver z-score nos passes
    //   abaixo), de modo que acc/gyro/GPS do app coincidem com a referência em
    //   ESCALA e FORMA — fechando o "ainda parece diferente"/"escalas bem
    //   diferentes" da revisão. (Plotar a média CRUA — antiga abordagem — batia
    //   só na tendência; o GPS em graus ~ -35 era o caso mais gritante.)
    // - Gravação: usamos `userAcceleration×10` (gravidade já removida pela
    //   CoreMotion); o CSV lido pelo Python usa o MESMO valor, então a entrada é
    //   idêntica nas duas pontas — a única diferença anterior era a normalização.
    // - O eixo X é tempo absoluto convertido para Date (timezone-aware no display).
    // - Tudo na resolução amostral da SessionReading (20 Hz @ coleta), mas
    //   downsampled para um cap (`targetPlotPoints`) para manter a UI responsiva.

    private let targetPlotPoints = 2000

    /// Lê SensorReading da sessão indicada e computa as séries por grupo
    /// (acelerômetro + giroscópio), prontas para o `CombinedSensorsChartView`.
    ///
    /// PORQUÊ ASYNC: a versão anterior tinha um bug — `ctx.perform { ... }` é
    /// assíncrono, então `return groupSeries` na função externa rodava ANTES
    /// do bloco terminar e sempre devolvia `[]`. Usamos `withCheckedContinuation`
    /// para esperar de verdade — mesmo padrão de `gatherEpisodePoints`.
    ///
    /// Uso em SwiftUI:
    /// ```swift
    /// Button { Task {
    ///     let series = await sensorManager.populateGroupSeries(forSession: sid)
    ///     // usa series direto na sheet
    /// } }
    /// ```
    func populateGroupSeries(forSession sessionId: UUID) async -> [SensorGroupSeries] {
        return await withCheckedContinuation { continuation in
            let ctx = PersistenceController.shared.container.newBackgroundContext()
            ctx.perform {
                // ===== Passe 1: estatísticas por canal para o z-score "standard" =====
                // PARIDADE COM run_local.py: a visualização é gerada com
                // normalization="standard", então normalize_features() padroniza CADA
                // canal — z = (x - média)/desvio, sobre a sessão inteira — ANTES de
                // mediar os canais do grupo (avg = feats[:, idx].mean(axis=1)).
                // Reproduzimos isso aqui para que as curvas do app coincidam com as
                // do pipeline de referência em ESCALA e FORMA, não só na tendência.
                // (Antes plotávamos a média CRUA: batia na tendência mas divergia em
                // escala/forma — origem do "ainda parece diferente" da revisão.)
                let statsReq: NSFetchRequest<SensorReading> = SensorReading.fetchRequest()
                statsReq.predicate = NSPredicate(format: "sessionId == %@", sessionId as CVarArg)
                statsReq.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
                statsReq.returnsObjectsAsFaults = false
                statsReq.fetchBatchSize = 1000

                guard let statsReadings = try? ctx.fetch(statsReq), !statsReadings.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }
                let N = statsReadings.count

                // Ordem dos canais: 0=ax 1=ay 2=az 3=gx 4=gy 5=gz.
                var sum = [Double](repeating: 0, count: 6)
                var sumSq = [Double](repeating: 0, count: 6)
                for r in statsReadings {
                    let arr = [Double(r.ax), Double(r.ay), Double(r.az),
                               Double(r.gx), Double(r.gy), Double(r.gz)]
                    for c in 0..<6 { sum[c] += arr[c]; sumSq[c] += arr[c] * arr[c] }
                    ctx.refresh(r, mergeChanges: false)
                }
                let nd = Double(N)
                var mean = [Double](repeating: 0, count: 6)
                var std  = [Double](repeating: 1, count: 6)
                for c in 0..<6 {
                    mean[c] = sum[c] / nd
                    // Variância populacional (ddof=0), igual ao np.std padrão.
                    let varc = max(0.0, sumSq[c] / nd - mean[c] * mean[c])
                    let s = varc.squareRoot()
                    std[c] = (s == 0) ? 1.0 : s   // canal constante → evita div/0 (== np: sd[sd==0]=1)
                }
                func zAcc(_ ax: Double, _ ay: Double, _ az: Double) -> Double {
                    ((ax - mean[0]) / std[0] + (ay - mean[1]) / std[1] + (az - mean[2]) / std[2]) / 3.0
                }
                func zGyro(_ gx: Double, _ gy: Double, _ gz: Double) -> Double {
                    ((gx - mean[3]) / std[3] + (gy - mean[4]) / std[4] + (gz - mean[5]) / std[5]) / 3.0
                }

                // ===== Passe 2: séries z-scored + downsample =====
                let req: NSFetchRequest<SensorReading> = SensorReading.fetchRequest()
                req.predicate = NSPredicate(format: "sessionId == %@", sessionId as CVarArg)
                req.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
                req.returnsObjectsAsFaults = false
                req.fetchBatchSize = 1000

                guard let readings = try? ctx.fetch(req), !readings.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }

                let target = self.targetPlotPoints
                // Downsample por janela fixa de média. Para coletas curtas
                // (N <= target), window = 1 → vira identidade. A média de janela
                // é linear, então comuta com o z-score (afim por canal) e com a
                // média entre canais — a ordem aqui não altera o resultado.
//                let window = max(1, N / target)
                let window = 1

                var accSamples: [SensorGroupSample] = []
                var gyroSamples: [SensorGroupSample] = []
                accSamples.reserveCapacity(N / window + 1)
                gyroSamples.reserveCapacity(N / window + 1)

                var i = 0
                while i < N {
                    let end = min(N, i + window)
                    var accSum: Double = 0
                    var gyroSum: Double = 0
                    var tsSum: Double = 0
                    let k = end - i
                    for j in i..<end {
                        let r = readings[j]
                        // Média dos 3 eixos JÁ Z-SCORED — paridade com run_local.py:
                        // feats = normalize_features(..., "standard"); avg = feats[:, idx].mean(1).
                        accSum  += zAcc(Double(r.ax), Double(r.ay), Double(r.az))
                        gyroSum += zGyro(Double(r.gx), Double(r.gy), Double(r.gz))
                        tsSum += Double(r.timestamp)
                        // Libera fault — não precisamos manter o objeto carregado.
                        ctx.refresh(r, mergeChanges: false)
                    }
                    let kd = Double(k)
                    let tsAvg = tsSum / kd
                    let date = Date(timeIntervalSince1970: tsAvg / 1000.0)
                    accSamples.append(SensorGroupSample(timestamp: date,
                                                        value: accSum / kd,
                                                        group: "Accelerometer"))
                    gyroSamples.append(SensorGroupSample(timestamp: date,
                                                         value: gyroSum / kd,
                                                         group: "Gyroscope"))
                    i = end
                }

                // GPS: série "GPS" lida de LocationEntity (1 Hz).
                //
                // PARIDADE COM run_local.py (`show_sensors_plotly`): o grupo de GPS
                // usado no script é `[latitude, longitude]` sob normalization="standard",
                // então cada eixo é padronizado (z-score) e em seguida mediado:
                // `feats[:, idx_list].mean(axis=1)`. Por isso plotamos a média dos
                // DOIS canais JÁ Z-SCORED — não mais a média em graus (~ -35), que
                // diferia em escala/forma da referência.
                let gpsSamples = self.makeGPSSamples(forSession: sessionId,
                                                     ctx: ctx,
                                                     target: target)

                var series: [SensorGroupSeries] = [
                    SensorGroupSeries(name: "Accelerometer", samples: accSamples),
                    SensorGroupSeries(name: "Gyroscope",     samples: gyroSamples),
                ]
                if !gpsSamples.isEmpty {
                    series.append(SensorGroupSeries(name: "GPS", samples: gpsSamples))
                }
                print("[GROUPSERIES] Pronto: \(accSamples.count) pontos acc/gyro, "
                      + "\(gpsSamples.count) pontos GPS (window=\(window), N=\(N))")
                continuation.resume(returning: series)
            }
        }
    }

    /// Constrói a série "GPS" da sessão a partir de LocationEntity (1 Hz).
    ///
    /// PARIDADE COM run_local.py: o grupo de GPS do `show_sensors_plotly` é
    /// `[latitude, longitude]` sob normalization="standard". `normalize_features`
    /// padroniza cada eixo (z-score sobre a sessão) e `feats[:, idx].mean(axis=1)`
    /// devolve a MÉDIA dos dois canais já normalizados. Por isso o valor plotado é
    /// ((lat-μ_lat)/σ_lat + (lon-μ_lon)/σ_lon)/2 por amostra — não mais (lat+lon)/2
    /// em graus. Downsample por média de janela espelha o mesmo cap de pontos
    /// (`targetPlotPoints`) usado para acc/gyro. Roda no MESMO `ctx`/`perform`
    /// do chamador (não cria continuation própria) — só uma 2ª fetch.
    ///
    /// Retorna `[]` se a sessão não tem GPS (ex.: coleta indoor sem fix), caso em
    /// que o CombinedSensorsChartView simplesmente não desenha o painel de GPS.
    private func makeGPSSamples(forSession sessionId: UUID,
                                ctx: NSManagedObjectContext,
                                target: Int) -> [SensorGroupSample] {
        let req: NSFetchRequest<LocationEntity> = LocationEntity.fetchRequest()
        req.predicate = NSPredicate(format: "sessionId == %@", sessionId as CVarArg)
        req.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        req.returnsObjectsAsFaults = false
        req.fetchBatchSize = 1000

        guard let locs = try? ctx.fetch(req), !locs.isEmpty else { return [] }

        let N = locs.count

        // Estatísticas por eixo (latitude, longitude) para o z-score "standard",
        // espelhando normalize_features(..., "standard") do run_local.py: cada eixo
        // é padronizado ANTES da média. É isso que faz a curva de GPS do app
        // coincidir com a do pipeline de referência em escala E forma (antes
        // plotávamos a média em graus ~ -35, origem da "escala bem diferente").
        // locs é 1 Hz (poucos milhares de pontos) → cabe em memória num passe.
        var sLat = 0.0, sLon = 0.0, sqLat = 0.0, sqLon = 0.0
        for l in locs {
            let la = Double(l.latitude), lo = Double(l.longitude)
            sLat += la; sLon += lo; sqLat += la * la; sqLon += lo * lo
        }
        let nd = Double(N)
        let mLat = sLat / nd, mLon = sLon / nd
        let rawLat = max(0.0, sqLat / nd - mLat * mLat).squareRoot()
        let rawLon = max(0.0, sqLon / nd - mLon * mLon).squareRoot()
        let dLat = rawLat == 0 ? 1.0 : rawLat   // eixo constante → evita div/0
        let dLon = rawLon == 0 ? 1.0 : rawLon

        let window = max(1, N / target)
        var samples: [SensorGroupSample] = []
        samples.reserveCapacity(N / window + 1)

        var i = 0
        while i < N {
            let end = min(N, i + window)
            var gpsSum: Double = 0
            var tsSum: Double = 0
            let k = end - i
            for j in i..<end {
                let l = locs[j]
                // Média ((lat-μ)/σ + (lon-μ)/σ)/2 — z-score por eixo + média, paridade
                // com viz_groups=[latitude, longitude] sob normalization="standard".
                let zla = (Double(l.latitude) - mLat) / dLat
                let zlo = (Double(l.longitude) - mLon) / dLon
                gpsSum += (zla + zlo) / 2.0
                tsSum += Double(l.timestamp)
                ctx.refresh(l, mergeChanges: false)
            }
            let kd = Double(k)
            let date = Date(timeIntervalSince1970: (tsSum / kd) / 1000.0)
            samples.append(SensorGroupSample(timestamp: date,
                                             value: gpsSum / kd,
                                             group: "GPS"))
            i = end
        }
        return samples
    }

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

    func gatherEpisodePoints(forSession sessionId: UUID, episodes: [Episode]) async -> [EpisodePoint] {
        let episodesSnapshot: [Episode] = episodes
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
                let lastIdx = sortedEps.count - 1

                for loc in locs {
                    let ts = loc.timestamp
                    // Avança até encontrar um episódio cujo end >= ts.
                    while epIdx < sortedEps.count && sortedEps[epIdx].endMs < ts {
                        epIdx += 1
                    }
                    // FIX (1.1 — sincronizar com os dados): o `endMs` do ÚLTIMO
                    // episódio é o ts do PRIMEIRO sample da última janela, não o
                    // fim dela. Logo os ~15 s finais de GPS têm ts > endMs e o
                    // loop acima estourava `epIdx` além do fim — esses pontos
                    // eram silenciosamente descartados (`break`), deixando o
                    // último grupo sub-renderizado no mapa. Como os pontos estão
                    // ordenados por tempo, qualquer ponto além da última fronteira
                    // pertence ao último episódio: fixamos epIdx no último em vez
                    // de abandonar o loop.
                    if epIdx > lastIdx { epIdx = lastIdx }
                    guard epIdx >= 0 else { break }
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

    // MARK: - Import de CSV (upload de coletas externas)
    //
    // Permite carregar um CSV no MESMO formato que `exportSession` gera (de outro
    // device, backup, ou de uma coleta exportada antes do app ser reinstalado) e
    // re-hidratá-lo como uma sessão persistida. A partir daí, todo o fluxo de
    // recovery (computar episódios, mapa, gráfico, re-exportar) funciona igual a
    // uma coleta nativa, porque os dados acabam nas MESMAS entidades Core Data.

    /// Erros de validação/processamento de um upload de CSV. `LocalizedError`
    /// para a UI exibir mensagens claras em pt-BR.
    enum SessionImportError: LocalizedError {
        case unreadable
        case empty
        case badHeader
        case noValidRows

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "Não foi possível ler o arquivo. Verifique se é um CSV de texto válido."
            case .empty:
                return "O arquivo está vazio."
            case .badHeader:
                return "O cabeçalho do CSV não bate com o formato esperado "
                     + "(timestamp, acc_x, …, vertical_accuracy)."
            case .noValidRows:
                return "Nenhuma linha de dados válida foi encontrada no arquivo."
            }
        }
    }

    /// Importa um CSV (formato de `exportSession`) como uma NOVA sessão persistida.
    /// Roda fora da main thread; valida cabeçalho/linhas, insere em lotes no Core
    /// Data e retorna o `SessionSummary` resultante para a UI navegar/atualizar.
    func importSession(from sourceURL: URL) async throws -> SessionSummary {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: SessionImportError.unreadable)
                    return
                }
                do {
                    let summary = try self.performImport(from: sourceURL)
                    continuation.resume(returning: summary)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Trabalho síncrono do import (parse + inserts em lote). Chamado de uma fila
    /// background por `importSession`.
    private func performImport(from sourceURL: URL) throws -> SessionSummary {
        // Arquivos vindos do file picker chegam fora do sandbox → precisam de
        // acesso security-scoped enquanto lemos.
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let raw: String
        do {
            raw = try String(contentsOf: sourceURL, encoding: .utf8)
        } catch {
            // Fallback p/ encodings legados (ex.: latin1) antes de desistir.
            guard let data = try? Data(contentsOf: sourceURL),
                  let decoded = String(data: data, encoding: .isoLatin1) else {
                throw SessionImportError.unreadable
            }
            raw = decoded
        }

        // Quebra por qualquer newline (\n ou \r\n) e descarta linhas em branco.
        let lines = raw.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else { throw SessionImportError.empty }

        // Detecta cabeçalho: se a 1ª coluna não é um inteiro, é header.
        var startIndex = 0
        let firstCols = lines[0].split(separator: ",", omittingEmptySubsequences: false)
        if let firstField = firstCols.first,
           Int64(firstField.trimmingCharacters(in: .whitespaces)) == nil {
            // É um cabeçalho — valida minimamente (timestamp + ≥ 7 colunas).
            guard firstCols.count >= 7,
                  firstField.lowercased().contains("timestamp") else {
                throw SessionImportError.badHeader
            }
            startIndex = 1
        }

        let sessionId = UUID()
        let ctx = PersistenceController.shared.container.newBackgroundContext()

        var totalRows = 0
        var gpsRows = 0
        var minTs = Int64.max
        var maxTs = Int64.min

        // Dedup de GPS: o CSV forward-filla o último fix em cada amostra (20 Hz);
        // só criamos uma LocationEntity quando lat/lon/alt mudam, recuperando a
        // cadência original (~1 Hz) em vez de duplicar centenas de milhares de linhas.
        var lastLat: Float = .nan
        var lastLon: Float = .nan
        var lastAlt: Float = .nan

        let saveEvery = 2000
        var pending = 0

        ctx.performAndWait {
            for i in startIndex..<lines.count {
                let cols = lines[i].split(separator: ",", omittingEmptySubsequences: false)
                guard cols.count >= 7,
                      let ts = Int64(cols[0].trimmingCharacters(in: .whitespaces)),
                      let ax = Float(cols[1].trimmingCharacters(in: .whitespaces)),
                      let ay = Float(cols[2].trimmingCharacters(in: .whitespaces)),
                      let az = Float(cols[3].trimmingCharacters(in: .whitespaces)),
                      let gx = Float(cols[4].trimmingCharacters(in: .whitespaces)),
                      let gy = Float(cols[5].trimmingCharacters(in: .whitespaces)),
                      let gz = Float(cols[6].trimmingCharacters(in: .whitespaces))
                else { continue }   // linha malformada → ignora

                let reading = SensorReading(context: ctx)
                reading.id = UUID()
                reading.sessionId = sessionId
                reading.timestamp = ts
                reading.ax = ax; reading.ay = ay; reading.az = az
                reading.gx = gx; reading.gy = gy; reading.gz = gz
                reading.battery = 0

                if ts < minTs { minTs = ts }
                if ts > maxTs { maxTs = ts }
                totalRows += 1
                pending += 1

                // GPS opcional (campos 7..11). Só com lat+lon presentes/parseáveis.
                if cols.count >= 9,
                   let lat = Float(cols[7].trimmingCharacters(in: .whitespaces)),
                   let lon = Float(cols[8].trimmingCharacters(in: .whitespaces)) {
                    let alt = cols.count > 9 ? (Float(cols[9].trimmingCharacters(in: .whitespaces)) ?? 0) : 0
                    let hAcc = cols.count > 10 ? (Float(cols[10].trimmingCharacters(in: .whitespaces)) ?? 0) : 0
                    let vAcc = cols.count > 11 ? (Float(cols[11].trimmingCharacters(in: .whitespaces)) ?? 0) : 0

                    if lat != lastLat || lon != lastLon || alt != lastAlt {
                        let loc = LocationEntity(context: ctx)
                        loc.sessionId = sessionId
                        loc.timestamp = ts
                        loc.latitude = lat
                        loc.longitude = lon
                        loc.altitude = alt
                        loc.horizontalAccuracy = hAcc
                        loc.verticalAccuracy = vAcc
                        lastLat = lat; lastLon = lon; lastAlt = alt
                        gpsRows += 1
                        pending += 1
                    }
                }

                if pending >= saveEvery {
                    do {
                        try ctx.save()
                        ctx.reset()   // libera row cache → memória O(batch)
                        pending = 0
                    } catch {
                        print("❌ [CSV Import] Save de lote falhou: \(error.localizedDescription)")
                    }
                }
            }

            if ctx.hasChanges {
                do { try ctx.save() }
                catch { print("❌ [CSV Import] Save final falhou: \(error.localizedDescription)") }
            }
        }

        guard totalRows > 0 else { throw SessionImportError.noValidRows }

        print("✅ [CSV Import] sessão \(sessionId.uuidString): \(totalRows) amostras, \(gpsRows) fixes GPS")

        return SessionSummary(
            id: sessionId,
            startMs: minTs,
            endMs: maxTs,
            rowCount: totalRows,
            isExported: false
        )
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

    /// Resumo de uma sessão persistida, para a UI de recuperação.
    struct SessionSummary: Identifiable, Hashable {
        let id: UUID
        let startMs: Int64
        let endMs: Int64
        let rowCount: Int
        let isExported: Bool

        var startDate: Date { Date(timeIntervalSince1970: Double(startMs) / 1000) }
        var endDate: Date { Date(timeIntervalSince1970: Double(endMs) / 1000) }
        var durationSec: Double { Double(endMs - startMs) / 1000 }
    }

    /// Lista TODAS as sessões persistidas em SensorReading (não só as órfãs),
    /// com intervalo de tempo, nº de amostras e flag de exportada — para a tela
    /// de recuperação. Exclui a sessão ATIVA (sendo populada agora). Ordenado do
    /// mais recente para o mais antigo.
    func allPersistedSessions() -> [SessionSummary] {
        let ctx = PersistenceController.shared.container.newBackgroundContext()
        var summaries: [SessionSummary] = []

        ctx.performAndWait {
            // SELECT DISTINCT sessionId — barato (traduz para DISTINCT no SQLite).
            let distinctReq = NSFetchRequest<NSDictionary>(entityName: "SensorReading")
            distinctReq.resultType = .dictionaryResultType
            distinctReq.returnsDistinctResults = true
            distinctReq.propertiesToFetch = ["sessionId"]
            distinctReq.predicate = NSPredicate(format: "sessionId != nil")

            let rows = (try? ctx.fetch(distinctReq)) ?? []
            let exported = exportedStore.allExported()
            let active = currentSessionId

            for row in rows {
                guard let id = row["sessionId"] as? UUID, id != active else { continue }

                // min/max timestamp + count por sessão. Usamos um fetch de
                // agregação leve via dictionary + expressões.
                let aggReq = NSFetchRequest<NSDictionary>(entityName: "SensorReading")
                aggReq.resultType = .dictionaryResultType
                aggReq.predicate = NSPredicate(format: "sessionId == %@", id as CVarArg)

                let tsKey = NSExpression(forKeyPath: "timestamp")
                let minExpr = NSExpressionDescription()
                minExpr.name = "minTs"; minExpr.expression = NSExpression(forFunction: "min:", arguments: [tsKey]); minExpr.expressionResultType = .integer64AttributeType
                let maxExpr = NSExpressionDescription()
                maxExpr.name = "maxTs"; maxExpr.expression = NSExpression(forFunction: "max:", arguments: [tsKey]); maxExpr.expressionResultType = .integer64AttributeType
                let countExpr = NSExpressionDescription()
                countExpr.name = "cnt"; countExpr.expression = NSExpression(forFunction: "count:", arguments: [tsKey]); countExpr.expressionResultType = .integer64AttributeType
                aggReq.propertiesToFetch = [minExpr, maxExpr, countExpr]

                guard let agg = (try? ctx.fetch(aggReq))?.first,
                      let minTs = (agg["minTs"] as? NSNumber)?.int64Value,
                      let maxTs = (agg["maxTs"] as? NSNumber)?.int64Value,
                      let cnt = (agg["cnt"] as? NSNumber)?.intValue else { continue }

                summaries.append(SessionSummary(
                    id: id,
                    startMs: minTs,
                    endMs: maxTs,
                    rowCount: cnt,
                    isExported: exported.contains(id)
                ))
            }
        }

        return summaries.sorted { $0.startMs > $1.startMs }
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


