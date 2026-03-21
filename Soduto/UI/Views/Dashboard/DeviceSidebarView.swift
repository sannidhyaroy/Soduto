//
//  DeviceSidebarView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 20/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

struct DeviceSidebarView: View {
    @ObservedObject var model: DeviceDashboardModel
    
    var body: some View {
        List(model.devices, selection: $model.selectedDeviceId) { device in
            DeviceSidebarRow(device: device, batteryService: model.batteryService)
                .tag(device.id)
        }
        .listStyle(.sidebar)
        .navigationTitle("Dashboard")
    }
}

private struct DeviceSidebarRow: View {
    let device: DashboardDevice
    let batteryService: BatteryService?
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.device.type.sfSymbolName)
                .font(.system(size: 18))
                .foregroundStyle(device.isReachable ? Color.secondary : Color(nsColor: .tertiaryLabelColor))
                .frame(width: 26)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(device.device.name)
                    .font(.body)
                    .foregroundStyle(device.isReachable ? .primary : .secondary)
                
                if let batteryImage = batteryService?.statusBarImage(for: device.device) {
                    Image(nsImage: batteryImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 13)
                } else if !device.isReachable {
                    Text("Disconnected")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Spacer()
            
            Circle()
                .fill(device.isReachable ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 2)
    }
}
