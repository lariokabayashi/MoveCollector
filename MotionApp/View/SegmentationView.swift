//
//  SegmentationView.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 31/03/26.
//

import SwiftUI

struct SegmentationCard: View {
    let sensorManager: SensorManagerViewModel
    @Binding var targetEpisodes: Int
    @Binding var availableTargets: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Segmentação")
                    .font(.headline)
                Spacer()
                Button("Processar") {
                    sensorManager.runDailyClustering(t: Double(targetEpisodes))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            HStack {
                Text("Episódios")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $targetEpisodes) {
                    ForEach(availableTargets, id: \.self) { t in
                        Text("\(t)").tag(t)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
            
            if !sensorManager.clusterLabels.isEmpty {
                EpisodeBarChart(labels: sensorManager.clusterLabels)
                    .frame(height: 140)
            } else {
                Text("Sem dados de clustering ainda.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            if !sensorManager.linkageMatrix.isEmpty {
                Text("Linkage rows: \(.init(sensorManager.linkageMatrix.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(.background))
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
    }
}

