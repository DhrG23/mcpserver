//
//  CoreView.swift
//  Node
//
//  Core/UI/CoreView.swift
//
//  "This device" tab — live device stats in an adaptive glass tile grid.
//

import SwiftUI

@MainActor
struct CoreView: View {

    @StateObject private var monitor = DeviceMonitor()
    @ObservedObject private var sharing = DataSourceManager.shared

    var body: some View {
        ZStack {
            GlassBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    headerRow

                    metricSection(
                        "Live",
                        monitor.snapshot.liveMetrics
                    )

                    metricSection(
                        "Device",
                        monitor.snapshot.deviceMetrics
                    )

                    metricSection(
                        "Shared data",
                        monitor.snapshot.sourceMetrics(
                            enabled: sharing.enabled,
                            statuses: sharing.statuses
                        )
                    )

                    SyncCard(
                        lastSync: monitor.lastSyncLabel,
                        error: monitor.lastSyncError,
                        isSyncing: monitor.isSyncing,
                        onSync: {
                            Task {
                                await monitor.syncNow()
                            }
                        },
                        onCopy: {
                            monitor.copyPayloadToClipboard()
                        }
                    )
                }
                .padding(20)
                .padding(.bottom, 20)
                .frame(maxWidth: CoreLayout.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            monitor.start()
        }
        .onDisappear {
            monitor.stop()
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Core", systemImage: "waveform.path.ecg")
                    .font(.title.bold())

                Text(monitor.snapshot.device.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                let connectionColor: Color =
                    monitor.isConnectedToServer ? .green : .orange

                Circle()
                    .fill(connectionColor)
                    .frame(width: 8, height: 8)
                    .shadow(
                        color: connectionColor.opacity(0.8),
                        radius: 4
                    )

                Text(
                    monitor.isConnectedToServer
                        ? "Live"
                        : "Offline"
                )
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Metrics

    @ViewBuilder
    private func metricSection(
        _ title: String,
        _ items: [Metric]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title)

            LazyVGrid(
                columns: CoreLayout.columns,
                alignment: .leading,
                spacing: CoreLayout.spacing
            ) {
                ForEach(items) { metric in
                    MetricTile(metric: metric)
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Core – Light") {
    CoreView()
        .preferredColorScheme(.light)
}

#Preview("Core – Dark") {
    CoreView()
        .preferredColorScheme(.dark)
}
