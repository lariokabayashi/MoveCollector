# 🔄 Sincronização de Dados: Sensores (20 Hz) + GPS (1 Hz)

## 📊 Visualização Temporal

### Linha do Tempo (primeiros 2 segundos)

```
Tempo (ms) | Sensor | GPS    | Ação
-----------|--------|--------|------------------------------------------
0          | ✓      | ✓ #1   | Coleta sensor + atualiza GPS
50         | ✓      | -      | Coleta sensor, repete GPS #1
100        | ✓      | -      | Coleta sensor, repete GPS #1
150        | ✓      | -      | Coleta sensor, repete GPS #1
200        | ✓      | -      | Coleta sensor, repete GPS #1
250        | ✓      | -      | Coleta sensor, repete GPS #1
300        | ✓      | -      | Coleta sensor, repete GPS #1
350        | ✓      | -      | Coleta sensor, repete GPS #1
400        | ✓      | -      | Coleta sensor, repete GPS #1
450        | ✓      | -      | Coleta sensor, repete GPS #1
500        | ✓      | -      | Coleta sensor, repete GPS #1
550        | ✓      | -      | Coleta sensor, repete GPS #1
600        | ✓      | -      | Coleta sensor, repete GPS #1
650        | ✓      | -      | Coleta sensor, repete GPS #1
700        | ✓      | -      | Coleta sensor, repete GPS #1
750        | ✓      | -      | Coleta sensor, repete GPS #1
800        | ✓      | -      | Coleta sensor, repete GPS #1
850        | ✓      | -      | Coleta sensor, repete GPS #1
900        | ✓      | -      | Coleta sensor, repete GPS #1
950        | ✓      | -      | Coleta sensor, repete GPS #1
1000       | ✓      | ✓ #2   | Coleta sensor + atualiza GPS
1050       | ✓      | -      | Coleta sensor, repete GPS #2
1100       | ✓      | -      | Coleta sensor, repete GPS #2
...
```

**Total**: 20 leituras de sensor por segundo, 1 atualização GPS por segundo

---

## 📝 Exemplo de CSV Gerado

### Estrutura Real dos Dados

```csv
timestamp,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z,latitude,longitude,altitude,horizontal_accuracy,vertical_accuracy
1715529600000,0.12,0.34,-9.81,0.01,0.02,0.00,-23.5505,-46.6333,760.5,5.0,10.0
1715529600050,0.15,0.32,-9.82,0.01,0.03,0.01,-23.5505,-46.6333,760.5,5.0,10.0
1715529600100,0.14,0.35,-9.80,0.02,0.02,0.01,-23.5505,-46.6333,760.5,5.0,10.0
1715529600150,0.13,0.33,-9.81,0.01,0.02,0.00,-23.5505,-46.6333,760.5,5.0,10.0
1715529600200,0.16,0.31,-9.83,0.02,0.01,-0.01,-23.5505,-46.6333,760.5,5.0,10.0
1715529600250,0.12,0.34,-9.81,0.01,0.02,0.00,-23.5505,-46.6333,760.5,5.0,10.0
1715529600300,0.15,0.32,-9.82,0.01,0.03,0.01,-23.5505,-46.6333,760.5,5.0,10.0
1715529600350,0.14,0.35,-9.80,0.02,0.02,0.01,-23.5505,-46.6333,760.5,5.0,10.0
1715529600400,0.13,0.33,-9.81,0.01,0.02,0.00,-23.5505,-46.6333,760.5,5.0,10.0
1715529600450,0.16,0.31,-9.83,0.02,0.01,-0.01,-23.5505,-46.6333,760.5,5.0,10.0
1715529600500,0.12,0.34,-9.81,0.01,0.02,0.00,-23.5505,-46.6333,760.5,5.0,10.0
1715529600550,0.15,0.32,-9.82,0.01,0.03,0.01,-23.5505,-46.6333,760.5,5.0,10.0
1715529600600,0.14,0.35,-9.80,0.02,0.02,0.01,-23.5505,-46.6333,760.5,5.0,10.0
1715529600650,0.13,0.33,-9.81,0.01,0.02,0.00,-23.5505,-46.6333,760.5,5.0,10.0
1715529600700,0.16,0.31,-9.83,0.02,0.01,-0.01,-23.5505,-46.6333,760.5,5.0,10.0
1715529600750,0.12,0.34,-9.81,0.01,0.02,0.00,-23.5505,-46.6333,760.5,5.0,10.0
1715529600800,0.15,0.32,-9.82,0.01,0.03,0.01,-23.5505,-46.6333,760.5,5.0,10.0
1715529600850,0.14,0.35,-9.80,0.02,0.02,0.01,-23.5505,-46.6333,760.5,5.0,10.0
1715529600900,0.13,0.33,-9.81,0.01,0.02,0.00,-23.5505,-46.6333,760.5,5.0,10.0
1715529600950,0.16,0.31,-9.83,0.02,0.01,-0.01,-23.5505,-46.6333,760.5,5.0,10.0
1715529601000,0.14,0.32,-9.82,0.01,0.02,0.01,-23.5506,-46.6334,761.2,4.8,9.5
1715529601050,0.13,0.35,-9.81,0.02,0.03,0.00,-23.5506,-46.6334,761.2,4.8,9.5
```

### 📍 Note os Padrões:

1. **Sensores mudam a cada linha** (50ms)
2. **GPS repete por 1 segundo** (20 linhas)
3. **GPS muda no timestamp 1000ms** (nova posição)

---

## 🎯 Caso Real: Pessoa Caminhando

### Cenário: Caminhada de 10 segundos

```csv
timestamp,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z,latitude,longitude,altitude,horizontal_accuracy,vertical_accuracy

# Segundo 0-1: Início da caminhada (GPS #1)
1715529600000,0.12,0.34,-9.81,0.01,0.02,0.00,-23.550500,-46.633300,760.5,5.0,10.0
1715529600050,0.15,0.32,-9.82,0.01,0.03,0.01,-23.550500,-46.633300,760.5,5.0,10.0
... (18 linhas com GPS repetido)
1715529600950,0.16,0.31,-9.83,0.02,0.01,-0.01,-23.550500,-46.633300,760.5,5.0,10.0

# Segundo 1-2: Meio do passo (GPS #2 - mudou ~1.5m)
1715529601000,0.14,0.32,-9.82,0.01,0.02,0.01,-23.550515,-46.633315,760.7,5.2,9.8
1715529601050,0.13,0.35,-9.81,0.02,0.03,0.00,-23.550515,-46.633315,760.7,5.2,9.8
... (18 linhas com GPS repetido)
1715529601950,0.18,0.30,-9.84,0.03,0.01,-0.02,-23.550515,-46.633315,760.7,5.2,9.8

# Segundo 2-3: Final do passo (GPS #3 - mudou mais ~1.5m)
1715529602000,0.11,0.36,-9.80,0.00,0.02,0.01,-23.550530,-46.633330,761.0,4.9,10.1
1715529602050,0.14,0.33,-9.82,0.01,0.03,0.00,-23.550530,-46.633330,761.0,4.9,10.1
... (continua)
```

### 📈 Análise dos Dados:

#### Sensores (20 Hz):
- **Capturam micro-movimentos** do passo
- **Picos de aceleração** quando o pé toca o chão
- **Rotação** durante a fase de balanço

#### GPS (1 Hz):
- **Trajetória geral** da caminhada
- **Mudança gradual** de posição (~1-2m/s)
- **Altitude** pode variar com terreno

---

## 🔍 Cenário Especial: GPS Perdido

### Quando GPS não está disponível (túnel, prédio, etc.)

```csv
timestamp,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z,latitude,longitude,altitude,horizontal_accuracy,vertical_accuracy

# Último GPS conhecido (antes de perder sinal)
1715529600000,0.12,0.34,-9.81,0.01,0.02,0.00,-23.550500,-46.633300,760.5,5.0,10.0

# GPS perdido - campos vazios
1715529601000,0.14,0.32,-9.82,0.01,0.02,0.01,,,,,
1715529601050,0.13,0.35,-9.81,0.02,0.03,0.00,,,,,
1715529601100,0.15,0.33,-9.83,0.01,0.02,-0.01,,,,,

# GPS recuperado
1715529602000,0.11,0.36,-9.80,0.00,0.02,0.01,-23.550520,-46.633320,761.2,8.5,15.3
```

**Note**: 
- Campos GPS vazios indicam sinal perdido
- Sensores continuam funcionando normalmente
- Quando GPS volta, pode ter accuracia reduzida (8.5m vs 5.0m)

---

## 📊 Estatísticas de Sincronização

### Por 1 Minuto de Coleta:

```
Duração: 60 segundos

Sensores:
- Frequência: 20 Hz
- Total de leituras: 1.200
- Intervalo médio: 50ms
- Desvio padrão: ~0.5ms

GPS:
- Frequência: 1 Hz
- Total de leituras: 60
- Intervalo médio: 1000ms
- Cada GPS repetido: 20 vezes

Sincronização:
- Dados combinados: 1.200 registros
- GPS não-nulos: 1.200 (100%)
- GPS únicos: 60
- Taxa de repetição: 20:1
```

---

## 🎨 Visualização Gráfica

### Diagrama de Barras (1 segundo)

```
Tempo   Sensor  GPS
(ms)    [█]     [█]
-------------------------------
0       █       █ ← GPS #1
50      █       │
100     █       │
150     █       │
200     █       │
250     █       │
300     █       │
350     █       │
400     █       │
450     █       │
500     █       │
550     █       │
600     █       │
650     █       │
700     █       │
750     █       │
800     █       │
850     █       │
900     █       │
950     █       │
1000    █       █ ← GPS #2
```

### Proporção Visual

```
Sensores: ████████████████████ (20 amostras/segundo)
GPS:      █                    (1 amostra/segundo)

Proporção: 20:1
```

---

## 💡 Vantagens Desta Abordagem

### 1. **Sincronização Precisa**
- Timestamp em milissegundos garante precisão
- Não há interpolação artificial de GPS
- Dados reais são preservados

### 2. **Eficiência de Armazenamento**
- GPS repetido é redundante mas explícito
- Fácil de processar depois (forward fill)
- Não requer índices ou joins complexos

### 3. **Processamento Posterior Simples**

```python
import pandas as pd

df = pd.read_csv('data.csv')

# Remover duplicatas de GPS para análise de trajetória
gps_unique = df[['timestamp', 'latitude', 'longitude']].drop_duplicates(subset=['latitude', 'longitude'])

# Ou preencher vazios com forward fill
df[['latitude', 'longitude', 'altitude']] = df[['latitude', 'longitude', 'altitude']].fillna(method='ffill')
```

### 4. **Compatibilidade Universal**
- CSV é lido por qualquer ferramenta
- Formato simples, sem dependências
- Fácil debug visual

---

## 🚀 Otimizações Futuras (Opcional)

### Se quiser reduzir tamanho do arquivo:

#### Opção 1: Dois arquivos separados
```
sensors.csv:     timestamp, acc_x, acc_y, acc_z, gyro_x, gyro_y, gyro_z
gps.csv:         timestamp, latitude, longitude, altitude, h_acc, v_acc
```

#### Opção 2: Formato binário
```swift
struct BinaryRecord {
    let timestamp: Int64      // 8 bytes
    let sensors: [Float]      // 24 bytes (6 * 4)
    let gps: [Double]?        // 40 bytes (5 * 8) ou 0
}
// Total: 32-72 bytes vs ~100 bytes CSV
```

#### Opção 3: Compressão
```swift
// Comprimir CSV com gzip
let compressed = try data.compressed(using: .zlib)
// Redução: ~70-80% do tamanho
```

---

## ✅ Checklist de Validação

Use este checklist para validar seus dados:

- [ ] Timestamp está em milissegundos (13 dígitos)
- [ ] Intervalo entre sensores é ~50ms (±5ms)
- [ ] GPS repete por ~1000ms (20 amostras)
- [ ] GPS muda gradualmente (não teleporta)
- [ ] Campos GPS vazios apenas quando sinal perdido
- [ ] Header CSV está correto
- [ ] Todas as linhas têm 12 campos
- [ ] Valores de aceleração estão em m/s² (~0-20)
- [ ] Valores de giroscópio estão em rad/s (~-5 a 5)
- [ ] Coordenadas GPS são válidas (-90 a 90, -180 a 180)

---

## 🎓 Exemplo de Análise

### Detectar Passos usando Aceleração + GPS

```python
import pandas as pd
import numpy as np
from scipy.signal import find_peaks

# Carregar dados
df = pd.read_csv('combined_data.csv')

# Magnitude da aceleração
df['acc_magnitude'] = np.sqrt(df['acc_x']**2 + df['acc_y']**2 + df['acc_z']**2)

# Detectar picos (passos)
peaks, _ = find_peaks(df['acc_magnitude'], height=12, distance=10)

print(f"Passos detectados: {len(peaks)}")

# Calcular velocidade média usando GPS
gps_df = df[['timestamp', 'latitude', 'longitude']].dropna().drop_duplicates()

# Distância entre pontos GPS consecutivos
from geopy.distance import geodesic

distances = []
for i in range(len(gps_df) - 1):
    p1 = (gps_df.iloc[i]['latitude'], gps_df.iloc[i]['longitude'])
    p2 = (gps_df.iloc[i+1]['latitude'], gps_df.iloc[i+1]['longitude'])
    distances.append(geodesic(p1, p2).meters)

avg_speed = np.mean(distances)  # metros por segundo
print(f"Velocidade média: {avg_speed:.2f} m/s ({avg_speed * 3.6:.2f} km/h)")

# Correlacionar passos com distância
step_rate = len(peaks) / (len(df) / 20)  # passos por segundo
stride_length = avg_speed / step_rate if step_rate > 0 else 0
print(f"Comprimento médio do passo: {stride_length:.2f} metros")
```

---

**🎯 Conclusão**: Este formato de sincronização é simples, eficiente e facilita análises posteriores!
