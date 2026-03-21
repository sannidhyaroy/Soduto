//
//  SystemVolumeSectionView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 20/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

struct SystemVolumeSectionView: View {
    let device: DashboardDevice
    @ObservedObject var model: DeviceDashboardModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Device Volume")
            
            if let sinks = model.systemVolumeService?.remoteSinks[device.id], !sinks.isEmpty {
                ForEach(sinks.sorted(by: { $0.key < $1.key }), id: \.key) { sinkName, sink in
                    SinkRowView(sink: sink, device: device, model: model)
                    
                    if sinkName != sinks.keys.sorted().last {
                        Divider()
                            .padding(.horizontal, 20)
                    }
                }
            } else {
                Text("No audio outputs available")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            }
        }
    }
}

// MARK: - Shared Section Header

/// Reusable section header used across all detail sections.
struct SectionHeader: View {
    let title: String
    
    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)
    }
}
