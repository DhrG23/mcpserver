//
//  CoreTiles.swift
//  Node
//
//  Created by Veerjyot Singh on 04/10/26.
//


import SwiftUI

struct Metric: Identifiable {
    let id: String
    let icon: String
    let label: String
    let value: String
    let subtext: String
    let accent: Color
    var progress: Double? = nil      // 0...1 draws a ring around the icon
}

// ─────────────────────────────────────────────
// MARK: - MetricTile
// ─────────────────────────────────────────────

struct MetricTile: View {

    let metric: Metric

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Circle()
                    .fill(metric.accent.opacity(0.15))
                    .frame(width: 40, height: 40)

                if let progress = metric.progress {
                    Circle()
                        .trim(from: 0, to: min(1, max(0, progress)))
                        .stroke(
                            metric.accent.opacity(0.75),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: 40, height: 40)
                        .rotationEffect(.degrees(-90))
                }

                Image(systemName: metric.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(metric.accent)
            }

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(metric.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Text(metric.value)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(metric.subtext)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: CoreLayout.tileHeight)
        .glassTile()
    }
}

// ─────────────────────────────────────────────
// MARK: - SectionHeader
// ─────────────────────────────────────────────

struct SectionHeader: View {

    let title: String

    var body: some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.8)
            .padding(.leading, 4)
    }
}

// ─────────────────────────────────────────────
// MARK: - SyncCard
// ─────────────────────────────────────────────

struct SyncCard: View {

    let lastSync: String
    let error: String?
    let isSyncing: Bool
    let onSync: () -> Void
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Last sync")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Text(lastSync)
                    .font(.headline)
                if let error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .font(.subheadline.bold())
                    .padding(9)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Copy payload as JSON")

            Button(action: onSync) {
                Group {
                    if isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .font(.subheadline.bold())
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isSyncing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .glassTile()
    }
}
