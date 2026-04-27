//
//  EpisodeBarChartView.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 24/03/26.
//

import Foundation
import SwiftUI

struct EpisodeSegment: Identifiable {
    let id = UUID()
    let label: Int
    let startIndex: Int
    let endIndex: Int
    var length: Int { endIndex - startIndex + 1 }
}

struct EpisodeBarChart: View {
    let labels: [Int]
    var segments: [EpisodeSegment] { makeSegments(from: labels) }
    
    private func color(for label: Int) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo, .red, .brown, .mint]
        return colors[(max(0, label - 1)) % colors.count]
    }
    
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments) { seg in
                    let fraction = CGFloat(seg.length) / CGFloat(labels.count)
                    Rectangle()
                        .fill(color(for: seg.label))
                        .frame(width: max(1, geo.size.width * fraction))
                        .overlay(
                            Text("\(seg.label)")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(2),
                            alignment: .center
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
    }
    
    func makeSegments(from labels: [Int]) -> [EpisodeSegment] {
        guard !labels.isEmpty else { return [] }
        var segments: [EpisodeSegment] = []
        var start = 0
        var current = labels[0]
        for i in 1..<labels.count {
            if labels[i] != current {
                segments.append(EpisodeSegment(label: current, startIndex: start, endIndex: i - 1))
                start = i
                current = labels[i]
            }
        }
        segments.append(EpisodeSegment(label: current, startIndex: start, endIndex: labels.count - 1))
        return segments
    }
}
