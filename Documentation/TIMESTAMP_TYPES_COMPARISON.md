# Comparação de Tipos para Timestamp no Core Data

## 📊 Tabela de Comparação

| Tipo | Tamanho | Precisão | Faixa de Valores | Melhor Para |
|------|---------|----------|------------------|-------------|
| **Date** | 8 bytes | Frações de segundo | 1 Jan 2001 ± ~285 anos | Timestamps gerais |
| **Double** | 8 bytes | ~15 dígitos decimais | ±1.7 × 10³⁰⁸ | Epoch timestamps |
| **Float** | 4 bytes | ~7 dígitos decimais | ±3.4 × 10³⁸ | ❌ Insuficiente para timestamps |
| **Integer 64** | 8 bytes | Exato (sem decimais) | ±9.2 × 10¹⁸ | Millisegundos desde epoch |
| **Integer 32** | 4 bytes | Exato (sem decimais) | ±2.1 × 10⁹ | ⚠️ Estoura em 2038 |

## 🏆 Recomendações por Caso de Uso

### 1. **Integer 64 (Int64)** - ⭐ MAIS EFICIENTE para timestamps com precisão de millisegundos

```swift
// Armazenar
let timestampMs = Int64(date.timeIntervalSince1970 * 1000)
entity.setValue(timestampMs, forKey: "timestampMs")

// Recuperar
let ms = entity.value(forKey: "timestampMs") as! Int64
let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
```

**Vantagens:**
- ✅ **8 bytes** (mesmo que Double/Date)
- ✅ **Precisão de 1 millisegundo** (suficiente para sensores @ 20 Hz)
- ✅ **Comparações exatas** (sem erros de ponto flutuante)
- ✅ **Indexação rápida** (inteiros são mais rápidos que float)
- ✅ **Faixa até ano 292,277,026**

**Desvantagens:**
- ⚠️ Precisa converter de/para `TimeInterval`

### 2. **Double** - Bom para compatibilidade com `TimeInterval`

```swift
// Armazenar (já é TimeInterval)
entity.setValue(date.timeIntervalSince1970, forKey: "timestampEpoch")

// Recuperar
let epoch = entity.value(forKey: "timestampEpoch") as! Double
let date = Date(timeIntervalSince1970: epoch)
```

**Vantagens:**
- ✅ **8 bytes**
- ✅ **Compatibilidade direta** com `TimeInterval`
- ✅ **Precisão de ~1 microsegundo** (para timestamps atuais)

**Desvantagens:**
- ⚠️ Erros de arredondamento em comparações
- ⚠️ Indexação um pouco mais lenta que inteiros

### 3. **Date** - Tipo nativo do Core Data

```swift
// Armazenar
entity.setValue(date, forKey: "timestamp")

// Recuperar
let date = entity.value(forKey: "timestamp") as! Date
```

**Vantagens:**
- ✅ **8 bytes**
- ✅ **Tipo nativo** do Core Data
- ✅ **NSPredicate direto** com datas

**Desvantagens:**
- ⚠️ Armazena como segundos desde 1 Jan 2001 (não epoch Unix)
- ⚠️ Faixa limitada (~285 anos)

### ❌ **Float** - NÃO RECOMENDADO

```swift
// ❌ PROBLEMA: Perde precisão após ~7 dígitos
let timestamp = Float(1684156801.234567)  
// Armazena: 1684156800.000000 (perdeu os dígitos finais!)
```

**Problemas:**
- ❌ **4 bytes**, mas **precisão insuficiente**
- ❌ Para timestamp epoch (~10 dígitos), perde fração de segundo
- ❌ Erros graves de arredondamento

### ⚠️ **Integer 32** - NÃO RECOMENDADO

```swift
// ⚠️ PROBLEMA: Estoura em 19 Janeiro 2038 (Y2K38)
let timestamp = Int32(date.timeIntervalSince1970)  
// Máximo: 2,147,483,647 segundos = 19 Jan 2038
```

## 🎯 Recomendação Final

### Para o seu caso (sensores @ 20 Hz + GPS @ 1 Hz):

Use **Integer 64 com millisegundos**:

```swift
// Em AppConstants.swift
struct TimestampHelper {
    /// Converte Date para timestamp em millisegundos
    static func toMilliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }
    
    /// Converte timestamp em millisegundos para Date
    static func fromMilliseconds(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
    }
    
    /// Converte TimeInterval para millisegundos
    static func toMilliseconds(_ interval: TimeInterval) -> Int64 {
        Int64(interval * 1000)
    }
}
```

### Atualizar LocationData:

```swift
struct LocationData {
    let timestamp: Date
    let timestampMs: Int64        // ← Usar Int64 em vez de TimeInterval
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
}
```

### Atualizar Sample:

```swift
struct Sample: Equatable {
    let tMs: Int64               // ← Usar Int64 em vez de TimeInterval
    let ax: Float
    let ay: Float
    let az: Float
    let gx: Float
    let gy: Float
    let gz: Float
}
```

## 📏 Comparação de Memória Real

Para **1 milhão de timestamps**:

| Tipo | Tamanho Total | Precisão | Velocidade Indexação |
|------|---------------|----------|---------------------|
| Int64 | 8 MB | 1 ms | ⭐⭐⭐⭐⭐ |
| Double | 8 MB | ~1 μs | ⭐⭐⭐⭐ |
| Date | 8 MB | ~1 μs | ⭐⭐⭐⭐ |
| Float | 4 MB | ❌ Insuficiente | ⭐⭐⭐ |

**Conclusão**: Int64 oferece o melhor equilíbrio entre:
- Tamanho igual aos outros (8 bytes)
- Precisão adequada (1 ms)
- Melhor performance em comparações e indexação
- Sem erros de arredondamento

## 🔧 Implementação Recomendada

### Core Data Model:
- **Campo**: `timestampMs`
- **Tipo**: `Integer 64`
- **Opcional**: Não
- **Indexed**: Sim
- **Default Value**: 0

### Vantagens Específicas para Sensores:

1. **20 Hz = 50ms entre leituras**: Int64 com precisão de 1ms é perfeito
2. **Comparações exatas**: `if sensorTimeMs == gpsTimeMs` funciona sem erros
3. **Queries rápidas**: Inteiros são indexados mais eficientemente
4. **Aritmética simples**: `let deltaTMs = sensor2Ms - sensor1Ms`

## 📊 Exemplo de Uso

```swift
// Salvando dados de sensor @ 20 Hz
let now = Date()
let timestampMs = TimestampHelper.toMilliseconds(now)

// Core Data
entity.setValue(timestampMs, forKey: "timestampMs")

// Query por intervalo
let fetchRequest: NSFetchRequest<SensorEntity> = SensorEntity.fetchRequest()
let startMs = TimestampHelper.toMilliseconds(startDate)
let endMs = TimestampHelper.toMilliseconds(endDate)

fetchRequest.predicate = NSPredicate(
    format: "timestampMs >= %lld AND timestampMs <= %lld", 
    startMs, 
    endMs
)

// Sincronizar GPS @ 1 Hz com Sensor @ 20 Hz
let tolerance: Int64 = 500  // 500ms de tolerância
let closestGPS = gpsData.min { 
    abs($0.timestampMs - sensorTimeMs) < abs($1.timestampMs - sensorTimeMs)
}
```

## 💾 Economia de Espaço Alternativa

Se você **realmente** precisa economizar memória e não precisa de millisegundos individuais:

### Opção: Timestamp Base + Offset

```swift
// Salvar apenas 1 timestamp completo por batch + offsets relativos
struct BatchData {
    let baseTimestampMs: Int64      // 8 bytes (uma vez por batch)
    let offsetsMs: [UInt16]         // 2 bytes cada (até 65 segundos)
}

// Para 1000 leituras @ 20 Hz (50 segundos):
// Método normal: 1000 × 8 bytes = 8 KB
// Método offset: 8 bytes + (1000 × 2 bytes) = 2.008 KB
// Economia: 75% !
```

Mas isso adiciona complexidade. Para a maioria dos casos, **Int64 direto é a melhor escolha**.
