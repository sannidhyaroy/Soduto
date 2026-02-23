//
//  DevicesListView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 22/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

// MARK: - Identifiable Device Wrapper

/// Wrapper to make Device conform to Identifiable for SwiftUI sheet presentation
struct IdentifiableDevice: Identifiable {
    let device: Device
    var id: Device.Id { device.id }
}

// MARK: - Devices List View Model

@MainActor
class DevicesListViewModel: ObservableObject {
    @Published var devices: [Device] = []
    @Published var showingDeviceInfo: IdentifiableDevice?
    
    weak var deviceDataSource: DeviceDataSource?
    weak var deviceManager: DeviceManager?
    
    init(deviceDataSource: DeviceDataSource?, deviceManager: DeviceManager?) {
        self.deviceDataSource = deviceDataSource
        self.deviceManager = deviceManager
        refreshDevices()
    }
    
    func refreshDevices() {
        guard let dataSource = deviceDataSource else { return }
        
        var allDevices: [Device] = []
        allDevices.append(contentsOf: dataSource.pairedRechableDevices)
        allDevices.append(contentsOf: dataSource.pairedDevices.filter { !$0.isReachable })
        allDevices.append(contentsOf: dataSource.unpairedDevices)
        allDevices.append(contentsOf: dataSource.unavailableDevices)
        
        self.devices = allDevices
    }
    
    func requestPairing(for device: Device) {
        device.requestPairing()
        PairingWindowController.showOutgoingRequest(for: device)
    }
    
    func unpair(_ device: Device) {
        device.unpair()
    }
    
    func manualRefresh() {
        // Trigger UDP broadcast to discover devices
        NotificationCenter.default.post(
            name: ConnectionProvider.broadcastAnnouncementNotification,
            object: nil
        )
        refreshDevices()
    }
    
    func forceReconnect() {
        // Close all TCP connections and rediscover devices
        guard let deviceManager = deviceManager else { return }
        deviceManager.closeAllConnections()
        
        // Wait for async connection closes to complete before broadcasting
        // This prevents race conditions where new connections try to establish
        // while old ones are still being torn down
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            // Ping local network to fill ARP table
            NetworkUtils.pingLocalNetwork()
            
            // Trigger UDP broadcast to rediscover devices
            NotificationCenter.default.post(
                name: ConnectionProvider.broadcastAnnouncementNotification,
                object: nil
            )
            
            // Refresh device list
            self?.refreshDevices()
        }
    }
    
    func deviceActions(for device: Device) -> [ServiceAction] {
        guard let deviceManager = deviceManager else { return [] }
        return deviceManager.serviceActions(for: device)
    }
}

// MARK: - Devices List View

struct DevicesListView: View {
    @ObservedObject var viewModel: DevicesListViewModel
    @State private var hoveredDeviceId: Device.Id?
    @State private var showingForceReconnectAlert = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with refresh button
            HStack {
                Text("Devices")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: {
                    viewModel.manualRefresh()
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.yellow)
                .help("Discover devices (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
                
                Button(action: {
                    showingForceReconnectAlert = true
                }) {
                    Label("Force Reconnect", systemImage: "bolt.slash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("⚠ Zap reconnect: closes active TCP connections, waits for teardown, then rediscovers devices.")
            }
            .padding(.horizontal, 16)
            .padding(.vertical,6)
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // Device list
            if viewModel.devices.isEmpty {
                emptyStateView
            } else {
                deviceListView
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .alert(isPresented: $showingForceReconnectAlert) {
            Alert(
                title: Text("Zap Connections and Reconnect?"),
                message: Text(
                    "⚠ WARNING: EXPERIMENTAL FEATURE AHEAD\n\nThis will immediately closes all active TCP connections, waits about 10 seconds for teardown, then triggers rediscovery and reconnect.\nUse this to immediately hard refresh available devices.\n\nTIP: If devices do not reconnect automatically, use the Refresh (⌘R) button."
                ),
                primaryButton: .destructive(Text("Proceed")) {
                    viewModel.forceReconnect()
                },
                secondaryButton: .cancel()
            )
        }
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No Devices Found")
                .font(.headline)
            
            Text("Make sure KDE Connect is running on your other devices")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Refresh") {
                viewModel.manualRefresh()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    // MARK: - Device List
    
    private var deviceListView: some View {
        List {
            ForEach(viewModel.devices, id: \.id) { device in
                DeviceRowView(
                    device: device,
                    isHovered: hoveredDeviceId == device.id,
                    onPairTap: { viewModel.requestPairing(for: device) },
                    onUnpairTap: { viewModel.unpair(device) },
                    onInfoTap: {
                        // Use Task to defer state update and avoid publishing during view update
                        Task { @MainActor in
                            viewModel.showingDeviceInfo = IdentifiableDevice(device: device)
                        }
                    }
                )
                .onHover { hovering in
                    hoveredDeviceId = hovering ? device.id : nil
                }
            }
        }
        .listStyle(.inset)
        .sheet(item: $viewModel.showingDeviceInfo) { identifiableDevice in
            DeviceInfoView(device: identifiableDevice.device)
        }
    }
}

// MARK: - Device Row View

struct DeviceRowView: View {
    let device: Device
    let isHovered: Bool
    let onPairTap: () -> Void
    let onUnpairTap: () -> Void
    let onInfoTap: () -> Void
    
    @State private var isBubbleHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Device icon bubble
            ZStack {
                // Background circle
                Circle()
                    .fill(isBubbleHovered
                          ? Color.accentColor.opacity(0.15)
                          : Color(nsColor: .controlBackgroundColor))
                    .frame(width: 44, height: 44)
                
                // Device icon
                Image(systemName: device.type.sfSymbolName)
                    .font(.system(size: 20))
                    .foregroundColor(device.isReachable ? .primary : .secondary)
                    .opacity(device.isReachable && !isBubbleHovered ? 1.0 : 0.5)
                
                // Info icon overlay on hover
                if isBubbleHovered {
                    Circle()
                        .fill(Color.black.opacity(0.6))
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                }
            }
            .onHover { hovering in
                isBubbleHovered = hovering
            }
            .onTapGesture {
                // Single click on bubble (when info icon visible) opens device info
                if isBubbleHovered {
                    onInfoTap()
                }
            }
            .help(isBubbleHovered ? "Show device info" : "")
            
            // Device info
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .opacity(device.isReachable ? 1.0 : 0.5)
                
                HStack(spacing: 4) {
                    if device.type != .Unknown {
                        Text(deviceTypeString(device.type))
                    }
                    
                    if device.type != .Unknown {
                        Text("•")
                            .foregroundColor(.secondary)
                    }
                    
                    Text(device.isReachable ? "reachable" : "unreachable")
                        .foregroundColor(device.isReachable ? .green : .secondary)
                }
                .font(.system(size: 11))
                .opacity(device.isReachable ? 0.8 : 0.4)
            }
            
            Spacer()
            
            // Pair/Unpair button
            pairButton
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Double-click anywhere on the row opens device info
            onInfoTap()
        }
    }
    
    @ViewBuilder
    private var pairButton: some View {
        if device.pairingStatus == .Paired {
            Button("Unpair") {
                onUnpairTap()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else if device.pairingStatus != .Requested && device.pairingStatus != .RequestedByPeer {
            Button("Pair") {
                onPairTap()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else {
            // Pairing in progress
            Button("Pairing...") {
                // Disabled during pairing
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(true)
        }
    }
    
    private func deviceTypeString(_ type: DeviceType) -> String {
        switch type {
        case .Desktop: return "Desktop"
        case .Laptop: return "Laptop"
        case .Phone: return "Phone"
        case .Tablet: return "Tablet"
        case .TV: return "TV"
        case .Unknown: return "Unknown"
        }
    }
}

// MARK: - Preview

#Preview("With Devices") {
    DevicesListView(viewModel: DevicesListViewModel(
        deviceDataSource: nil,
        deviceManager: nil
    ))
    .frame(width: 450, height: 400)
}

#Preview("Empty") {
    Group {
        let viewModel = DevicesListViewModel(
            deviceDataSource: nil,
            deviceManager: nil
        )
        let _ = { viewModel.devices = [] }()
        
        DevicesListView(viewModel: viewModel)
            .frame(width: 450, height: 400)
    }
}
