//
//  DeviceDashboardView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 20/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

struct DeviceDashboardView: View {
    @ObservedObject var model: DeviceDashboardModel
    
    var body: some View {
        NavigationSplitView {
            DeviceSidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            if let id = model.selectedDeviceId,
               let device = model.devices.first(where: { $0.id == id }) {
                DeviceDetailView(device: device, model: model)
            } else {
                ContentUnavailableView(
                    "No Paired Devices",
                    systemImage: "iphone.slash",
                    description: Text("Pair a device to get started")
                )
            }
        }
    }
}
