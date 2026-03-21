//
//  MediaPlayerSectionView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 20/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

struct MediaPlayerSectionView: View {
    let device: DashboardDevice
    @ObservedObject var model: DeviceDashboardModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Media Players")
            
            if device.players.isEmpty {
                Text("No active media players")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(device.players, id: \.identity) { player in
                    PlayerRowView(player: player, model: model)
                    
                    if player.identity != device.players.last?.identity {
                        Divider()
                            .padding(.leading, 76)
                            .padding(.trailing, 20)
                    }
                }
            }
        }
    }
}
