//
//  ActivityCard.swift
//  MotionApp
//
//  Created by Larissa Okabayashi on 13/03/26.
//

import SwiftUI

@available(iOS 26.0, *)
struct ActivityCard: View {
    let activity: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: activityIcon(for: activity))
                .font(.title2)
                .foregroundStyle(Color.brandBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Atividade prevista")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(activity.capitalized)
                    .font(.title3.weight(.semibold))
            }
            Spacer()
        }
        .cardStyle()
    }

    private func activityIcon(for activity: String) -> String {
        switch activity.lowercased() {
        case "walking": return "figure.walk"
        case "running": return "figure.run"
        case "cycling": return "bicycle"
        case "stationary": return "pause.circle"
        default: return "bolt.circle"
        }
    }
}
