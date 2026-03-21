//
//  DeviceHeaderView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 20/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

struct DeviceHeaderView: View {
    let device: DashboardDevice
    let connectivityReportService: ConnectivityReportService?
    let batteryService: BatteryService?
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: device.device.type.sfSymbolName)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(device.isReachable ? Color.accentColor : Color.secondary)
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(device.isReachable ? 0.1 : 0.05))
                )
            
            VStack(alignment: .leading, spacing: 4) {
                Text(device.device.name)
                    .font(.title2.weight(.semibold))
                
                HStack(spacing: 8) {
                    // Connectivity badge (cellular if available, otherwise WiFi/disconnected)
                    if let connectivityImage = connectivityReportService?.statusBarImage(for: device.device) {
                        Image(nsImage: connectivityImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 13)
                    } else {
                        Label(
                            device.isReachable ? "Connected" : "Disconnected",
                            systemImage: device.isReachable ? "wifi" : "wifi.slash"
                        )
                        .font(.caption)
                        .foregroundStyle(device.isReachable ? Color.green : Color.red)
                    }
                    
                    // Battery badge
                    if let batteryImage = batteryService?.statusBarImage(for: device.device) {
                        Image(nsImage: batteryImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 13)
                    }
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}
