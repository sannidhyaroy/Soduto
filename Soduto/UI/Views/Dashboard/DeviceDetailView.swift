//
//  DeviceDetailView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 20/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

struct DeviceDetailView: View {
    let device: DashboardDevice
    @ObservedObject var model: DeviceDashboardModel
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DeviceHeaderView(
                    device: device,
                    connectivityReportService: model.connectivityReportService,
                    batteryService: model.batteryService
                )
                
                Divider()
                    .padding(.horizontal, 20)
                
                MediaPlayerSectionView(device: device, model: model)
                
                Divider()
                    .padding(.horizontal, 20)
                
                SystemVolumeSectionView(device: device, model: model)
            }
        }
        .id(device.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
