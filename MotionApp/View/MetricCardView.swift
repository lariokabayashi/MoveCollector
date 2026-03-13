//
//  MetricCardView.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 13/03/26.
//
import SwiftUI

@available(iOS 26.0, *)
struct MetricCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(.background))
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
    }
}
