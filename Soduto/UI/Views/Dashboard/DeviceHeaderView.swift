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
                        let label = device.isReachable ? "Connected" : (device.lastSeenDate.map { "Last seen \(shortTime($0))" } ?? "Disconnected")
                        Label(label, systemImage: device.isReachable ? "wifi" : "wifi.slash")
                            .font(.caption)
                            .foregroundStyle(device.isReachable ? Color.green : Color.secondary)
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
    
    // MARK: - Helpers
    
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    
    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .medium
        return f
    }()
    
    private func shortTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "today at \(Self.timeFormatter.string(from: date))"
        } else if calendar.isDateInYesterday(date) {
            return "yesterday at \(Self.timeFormatter.string(from: date))"
        } else {
            return Self.dateTimeFormatter.string(from: date)
        }
    }
}
