# 🏗️ Arquitetura do Sistema de Coleta Combinada

## 📊 Diagrama de Componentes

```
┌─────────────────────────────────────────────────────────────────┐
│                      CombinedDataCollectionView                  │
│                         (SwiftUI Interface)                      │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           │ @StateObject
                           ↓
┌─────────────────────────────────────────────────────────────────┐
│                     CombinedDataCollector                        │
│                    (Main Orchestrator)                           │
│                                                                  │
│  • startCollection() / stopCollection()                          │
│  • saveBufferToCSV()                                            │
│  • exportFinalCSV()                                             │
│  • getStats()                                                   │
└──────────┬─────────────────┬──────────────────┬────────────────┘
           │                 │                  │
           │                 │                  │
    ┌──────▼──────┐   ┌─────▼──────┐    ┌─────▼──────┐
    │ CMMotion    │   │ CLLocation │    │  Timer     │
    │ Manager     │   │ Manager    │    │ (Auto-save)│
    │ (Sensors)   │   │ (GPS)      │    └─────┬──────┘
    └──────┬──────┘   └─────┬──────┘          │
           │                 │                  │
           │ 20 Hz           │ 1 Hz             │ 60s
           │                 │                  │
    ┌──────▼──────────────────▼─────────────────▼──────┐
    │         SensorTimer (DispatchSourceTimer)        │
    │            collectSensorData() @ 50ms            │
    └──────────────────────┬────────────────────────────┘
                           │
                           │ Coleta + Sincroniza
                           ↓
    ┌──────────────────────────────────────────────────┐
    │              GPSDataCache                        │
    │         (Thread-safe GPS storage)                │
    │                                                  │
    │  • update(location:)                             │
    │  • getLatest() → GPSSnapshot?                    │
    │  • clear()                                       │
    └──────────────────────┬────────────────────────────┘
                           │
                           │ GPS mais recente
                           ↓
    ┌──────────────────────────────────────────────────┐
    │            CombinedDataBuffer                    │
    │       (Thread-safe data accumulation)            │
    │                                                  │
    │  • append(CombinedSensorData)                    │
    │  • getAll() → [CombinedSensorData]               │
    │  • drainAll() → [CombinedSensorData]             │
    │  • clear()                                       │
    │                                                  │
    │  Max Size: 10,000 registros (~8 min @ 20 Hz)    │
    └──────────────────────┬────────────────────────────┘
                           │
                           │ Quando cheio ou timer
                           ↓
    ┌──────────────────────────────────────────────────┐
    │         CombinedDataCSVExporter                  │
    │            (File management)                     │
    │                                                  │
    │  • exportToCSV() → URL?                          │
    │  • exportToString() → String                     │
    │  • appendToCSV()                                 │
    └──────────────────────┬────────────────────────────┘
                           │
                           │ Salva no disco
                           ↓
    ┌──────────────────────────────────────────────────┐
    │              FileManager                         │
    │         (Documents Directory)                    │
    │                                                  │
    │  combined_sensor_data_YYYY-MM-DD_HH-MM-SS.csv    │
    └──────────────────────────────────────────────────┘
```

---

## 🔄 Fluxo de Dados

### 1. Inicialização

```swift
let collector = CombinedDataCollector()
collector.startCollection()
```

```
┌──────────────────────┐
│ User presses START   │
└──────────┬───────────┘
           │
           ↓
┌──────────────────────┐
│ Configure CMMotion   │
│ - 20 Hz (50ms)       │
└──────────┬───────────┘
           │
           ↓
┌──────────────────────┐
│ Configure CLLocation │
│ - 1 Hz (1000ms)      │
└──────────┬───────────┘
           │
           ↓
┌──────────────────────┐
│ Start Sensor Timer   │
│ (DispatchSource)     │
└──────────┬───────────┘
           │
           ↓
┌──────────────────────┐
│ Start Auto-save      │
│ Timer (60s)          │
└──────────────────────┘
```

### 2. Coleta de Dados (Loop Principal)

```
Cada 50ms (20 Hz):
┌─────────────────────────────────────┐
│ Timer fires                         │
└────────────┬────────────────────────┘
             │
             ↓
┌─────────────────────────────────────┐
│ Ler CMMotionManager                 │
│ - userAcceleration (x, y, z)        │
│ - rotationRate (x, y, z)            │
└────────────┬────────────────────────┘
             │
             ↓
┌─────────────────────────────────────┐
│ Obter timestamp atual               │
│ Int(Date().timeIntervalSince1970    │
│      * 1000) // milissegundos       │
└────────────┬────────────────────────┘
             │
             ↓
┌─────────────────────────────────────┐
│ Buscar último GPS no cache          │
│ gpsCache.getLatest()                │
└────────────┬────────────────────────┘
             │
             ↓
┌─────────────────────────────────────┐
│ Criar CombinedSensorData            │
│ - timestamp: Int                    │
│ - sensors: Float x6                 │
│ - gps: Double? x5                   │
└────────────┬────────────────────────┘
             │
             ↓
┌─────────────────────────────────────┐
│ Adicionar ao buffer                 │
│ buffer.append(data)                 │
└────────────┬────────────────────────┘
             │
             ↓
┌─────────────────────────────────────┐
│ Atualizar contador UI               │
│ totalRecordsCollected += 1          │
└─────────────────────────────────────┘
```

### 3. Atualização de GPS (Assíncrona)

```
Cada ~1 segundo (1 Hz):
┌─────────────────────────────────────┐
│ CLLocationManager callback          │
└────────────┬────────────────────────┘
             │
             ↓
┌─────────────────────────────────────┐
│ Filtrar frequência                  │
│ (garantir 1 Hz exato)               │
└────────────┬────────────────────────┘
             │
             ↓
┌─────────────────────────────────────┐
│ Atualizar GPSDataCache              │
│ cache.update(location)              │
└────────────┬────────────────────────┘
             │
             ↓
┌─────────────────────────────────────┐
│ GPS repetido nos próximos ~20       │
│ samples de sensores (até próximo    │
│ update de GPS)                      │
└─────────────────────────────────────┘
```

### 4. Auto-Save (Periódico)

```
Cada 60 segundos:
┌─────────────────────────────────────┐
│ Timer fires                         │
└────────────┬────────────────────────┘
             │
             ↓
┌─────────────────────────────────────┐
│ Drenar buffer                       │
│ data = buffer.drainAll()            │
└────────────┬────────────────────────┘
             │
             ↓
┌─────────────────────────────────────┐
│ Verificar se tem dados              │
│ guard !data.isEmpty                 │
└────────────┬────────────────────────┘
             │
             ↓
┌─────────────────────────────────────┐
│ Converter para CSV                  │
│ CombinedDataCSVExporter             │
└────────────┬────────────────────────┘
             │
             ↓
┌─────────────────────────────────────┐
│ Se arquivo existe, append           │
│ Senão, criar novo com header        │
└────────────┬────────────────────────┘
             │
             ↓
┌─────────────────────────────────────┐
│ Salvar no Documents/                │
│ combined_sensor_data_...csv         │
└─────────────────────────────────────┘
```

### 5. Finalização

```
┌─────────────────────────────────────┐
│ User presses STOP                   │
└────────────┬────────────────────────┘
             │
             ↓
┌─────────────────────────────────────┐
│ Cancelar timers                     │
│ - sensorTimer?.cancel()             │
│ - autoSaveTimer?.invalidate()       │
└────────────┬────────────────────────┘
             │
             ↓
┌─────────────────────────────────────┐
│ Parar sensores                      │
│ - motionManager.stop...()           │
└────────────┬────────────────────────┘
             │
             ↓
┌─────────────────────────────────────┐
│ Parar GPS                           │
│ - locationManager.stop...()         │
└────────────┬────────────────────────┘
             │
             ↓
┌─────────────────────────────────────┐
│ Salvar dados restantes              │
│ saveBufferToCSV()                   │
└────────────┬────────────────────────┘
             │
             ↓
┌─────────────────────────────────────┐
│ Retornar URL do arquivo             │
│ return csvFileURL                   │
└─────────────────────────────────────┘
```

---

## 🧵 Thread Safety

### Problemas Potenciais

1. **GPS e Sensores em threads diferentes**
2. **Buffer acessado concorrentemente**
3. **UI updates de background thread**

### Soluções Implementadas

```swift
// 1. GPS Cache com Lock
class GPSDataCache {
    private let lock = NSLock()
    
    func update() {
        lock.lock()
        defer { lock.unlock() }
        // Safe access
    }
}

// 2. Buffer com Lock
class CombinedDataBuffer {
    private let lock = NSLock()
    
    func append() {
        lock.lock()
        defer { lock.unlock() }
        // Safe access
    }
}

// 3. UI Updates no Main Thread
DispatchQueue.main.async {
    self.totalRecordsCollected += 1
}
```

---

## 💾 Estruturas de Dados

### Hierarquia de Tipos

```
CombinedSensorData (struct)
├── timestamp: Int                  // 8 bytes
├── accX, accY, accZ: Float        // 12 bytes
├── gyroX, gyroY, gyroZ: Float     // 12 bytes
├── latitude: Double?              // 8 bytes (0 if nil)
├── longitude: Double?             // 8 bytes (0 if nil)
├── altitude: Double?              // 8 bytes (0 if nil)
├── horizontalAccuracy: Double?    // 8 bytes (0 if nil)
└── verticalAccuracy: Double?      // 8 bytes (0 if nil)
                                   ────────────
                        Total:     ~72 bytes por registro
```

### Comparação com String Timestamp

```
❌ String (ISO8601):
timestamp: "2026-05-12T14:30:00.123Z"  // ~25+ bytes

✅ Int (milliseconds):
timestamp: 1715529600123               // 8 bytes

Economia: 17 bytes × 72.000 registros/hora = ~1.2 MB/hora
```

---

## 📈 Performance e Otimizações

### Otimizações Implementadas

| Otimização | Benefício |
|------------|-----------|
| **Int timestamp** | 70% menos espaço vs String |
| **Buffer limitado** | Previne crescimento infinito de memória |
| **Auto-save periódico** | Libera memória a cada 60s |
| **DispatchSource timer** | Mais eficiente que Timer para alta frequência |
| **NSLock vs Dispatch** | Menor overhead para locks simples |
| **Forward fill GPS** | Evita interpolação cara |

### Benchmarks Esperados

```
Operação                    | Tempo      | Memória
----------------------------|------------|------------
Adicionar 1 registro        | <0.001ms   | 72 bytes
Adicionar 10k registros     | ~100ms     | ~720 KB
Exportar 10k para CSV       | ~500ms     | ~1 MB
Salvar CSV no disco         | ~200ms     | -
Ler CMMotionManager         | ~0.1ms     | -
Atualizar GPSCache          | ~0.05ms    | 72 bytes
```

---

## 🎯 Decisões de Design

### Por que Int ao invés de Double para timestamp?

```swift
// Double (TimeInterval)
let timestamp: Double = 1715529600.123  // 8 bytes
// Pros: Precisão de microssegundos
// Cons: Ponto flutuante tem erros de arredondamento

// Int (milissegundos)
let timestamp: Int = 1715529600123      // 8 bytes
// Pros: Exato, sem erros de arredondamento, mais rápido
// Cons: Limitado a milissegundos (suficiente para 20 Hz)

✅ Int escolhido: 50ms >> 1ms, então milissegundos são suficientes
```

### Por que NSLock ao invés de DispatchQueue?

```swift
// DispatchQueue
queue.sync { data.append(x) }
// Overhead: ~10-50μs por acesso

// NSLock
lock.lock()
data.append(x)
lock.unlock()
// Overhead: ~1-5μs por acesso

✅ NSLock escolhido: 5-10x mais rápido para locks simples
```

### Por que repetir GPS ao invés de interpolar?

```swift
// Interpolação (❌ Não usado)
let interpolated = lerp(gps1, gps2, t)
// Pros: GPS "smooth"
// Cons: Dados artificiais, computacionalmente caro

// Repetição (✅ Usado)
let gps = lastGPS
// Pros: Dados reais, zero overhead, fácil processar depois
// Cons: Redundância no arquivo (aceitável)

✅ Repetição escolhida: Dados reais > dados artificiais
```

---

## 🔍 Debugging e Monitoring

### Logs Implementados

```
🚀 [Combined Collector] Iniciando coleta de dados
✅ [Combined Collector] Sensores @ 20.0 Hz
✅ [Combined Collector] GPS @ 1.0 Hz
📍 [GPS] Lat: -23.5505, Lon: -46.6333, Alt: 760.5m
💾 [Combined Collector] Salvando 1200 registros...
✅ [Combined Collector] Dados adicionados ao arquivo existente
📊 [CSV Export] Total de 1200 registros exportados
🛑 [Combined Collector] Parando coleta de dados
✅ [Combined Collector] Coleta finalizada. Total: 3600 registros
```

### Pontos de Instrumentação

```swift
// Adicionar para debug avançado:

// 1. Timing de operações
let start = Date()
// ... operação ...
let elapsed = Date().timeIntervalSince(start)
print("⏱️ Operação levou \(elapsed * 1000)ms")

// 2. Memory usage
let memory = ProcessInfo.processInfo.physicalMemory
print("💾 Memória: \(memory / 1024 / 1024) MB")

// 3. Buffer health
print("📊 Buffer: \(buffer.count)/\(maxSize) (\(buffer.count * 100 / maxSize)%)")

// 4. GPS quality
print("📍 GPS Accuracy: H=\(hAcc)m V=\(vAcc)m")
```

---

## 🎓 Padrões de Design Utilizados

### 1. **Observer Pattern**
```swift
@Published var isCollecting = false
// View observa mudanças automaticamente
```

### 2. **Singleton-like Cache**
```swift
class GPSDataCache {
    // Cache compartilhado, mas não singleton
    // Permite múltiplas instâncias para testes
}
```

### 3. **Strategy Pattern**
```swift
protocol DataExporter {
    func export(_ data: [CombinedSensorData]) -> URL?
}

class CSVExporter: DataExporter { ... }
class JSONExporter: DataExporter { ... }
```

### 4. **Builder Pattern**
```swift
CombinedSensorData(
    timestamp: timestamp,
    accX: ax, accY: ay, accZ: az,
    // ...
)
```

### 5. **Delegate Pattern**
```swift
extension CombinedDataCollector: CLLocationManagerDelegate {
    func locationManager(...) { ... }
}
```

---

## 📚 Referências

- [CoreMotion Documentation](https://developer.apple.com/documentation/coremotion)
- [CoreLocation Documentation](https://developer.apple.com/documentation/corelocation)
- [Swift Concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)
- [NSLock Documentation](https://developer.apple.com/documentation/foundation/nslock)
- [CSV RFC 4180](https://tools.ietf.org/html/rfc4180)

---

**🎉 Sistema completo e pronto para uso!**
