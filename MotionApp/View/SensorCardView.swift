//
//  SensorCardView.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 13/03/26.
//

import SwiftUI

@available(iOS 26.0, *)
struct SensorCard: View {
    let title: String
    let unit: String
    let x: Double
    let y: Double
    let z: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                AxisValue(axis: "X", value: x)
                AxisValue(axis: "Y", value: y)
                AxisValue(axis: "Z", value: z)
            }
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(.background))
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
    }
}
