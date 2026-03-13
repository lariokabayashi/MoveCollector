//
//  AxisValueView.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 13/03/26.
//
import SwiftUI

@available(iOS 26.0, *)
struct AxisValue: View {
    let axis: String
    let value: Double

    var body: some View {
        VStack(spacing: 2) {
            Text(axis)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value, specifier: "%.2f")")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}
