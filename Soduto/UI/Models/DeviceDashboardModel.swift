//
//  DeviceDashboardModel.swift
//  Soduto
//
//  Created by Sannidhya Roy on 20/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import Combine

/// Aggregated snapshot of a single paired device for the dashboard.
struct DashboardDevice: Identifiable {
    let id: Device.Id
    let device: Device
    var isReachable: Bool
    /// Stamped when this device last transitioned from reachable → unreachable
    var lastSeenDate: Date?
    /// Remote players reported by MediaPlayerService for this device
    var players: [PlayerRemote]
    /// Battery status: used as an invalidation key so SwiftUI re-renders when it changes
    /// Views use `batteryService.statusBarImage()` for the actual rendered image
    var batteryStatus: BatteryService.BatteryStatus?
    /// Connectivity status: used as an invalidation key so SwiftUI re-renders when it changes
    /// Views use `connectivityReportService.statusBarImage()` for the actual rendered image
    var connectivityStatus: [ConnectivityReportService.ConnectivityStatus]?
}

/// Central observable model for the Device Dashboard.
///
/// Aggregates state from `DeviceDataSource`, `MediaPlayerService`, `SystemVolumeService`,
/// and `BatteryService` into a unified list of `DashboardDevice` values. Views observe
/// this model and call its command methods, they never touch services directly.
@MainActor
final class DeviceDashboardModel: ObservableObject {
    
    @Published private(set) var devices: [DashboardDevice] = []
    @Published var selectedDeviceId: Device.Id?
    
    private let deviceDataSource: DeviceDataSource
    let mediaPlayerService: MediaPlayerService?
    let systemVolumeService: SystemVolumeService?
    let batteryService: BatteryService?
    let connectivityReportService: ConnectivityReportService?
    
    private var cancellables: Set<AnyCancellable> = []
    /// Stamped when a device transitions from reachable → unreachable
    private var lastSeenDates: [Device.Id: Date] = [:]
    
    init(deviceDataSource: DeviceDataSource,
         mediaPlayerService: MediaPlayerService?,
         systemVolumeService: SystemVolumeService?,
         batteryService: BatteryService?,
         connectivityReportService: ConnectivityReportService?) {
        self.deviceDataSource = deviceDataSource
        self.mediaPlayerService = mediaPlayerService
        self.systemVolumeService = systemVolumeService
        self.batteryService = batteryService
        self.connectivityReportService = connectivityReportService
        
        // Merge all service-change signals and debounce so rapid-fire packets
        // (battery every 3-8s, connectivity, player list) coalesce into a single
        // rebuildDevices() call instead of hammering the SwiftUI view tree.
        let serviceChanges: [AnyPublisher<Void, Never>] = [
            mediaPlayerService?.$players.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            systemVolumeService?.$remoteSinks.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            batteryService?.$statuses.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            connectivityReportService?.$statuses.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ].compactMap { $0 }
        
        Publishers.MergeMany(serviceChanges)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.rebuildDevices() }
            .store(in: &cancellables)
        
        rebuildDevices()
    }
    
    /// Called by `StatusBarMenuController` whenever device connectivity or pairing state changes.
    func refreshDeviceList() {
        rebuildDevices()
    }
    
    // MARK: - Media Player Commands
    
    func playPause(for player: PlayerRemote) {
        mediaPlayerService?.controlPlayPause(for: player)
    }
    
    func stop(for player: PlayerRemote) {
        mediaPlayerService?.controlStop(for: player)
    }
    
    func next(for player: PlayerRemote) {
        mediaPlayerService?.controlNext(for: player)
    }
    
    func previous(for player: PlayerRemote) {
        mediaPlayerService?.controlPrevious(for: player)
    }
    
    func setVolume(_ volume: Int, for player: PlayerRemote) {
        mediaPlayerService?.controlSetVolume(for: player, volume: volume)
    }
    
    func setPosition(_ positionMs: Int, for player: PlayerRemote) {
        mediaPlayerService?.controlSetPosition(for: player, positionMs: positionMs)
    }
    
    func seek(_ seconds: Int, for player: PlayerRemote) {
        mediaPlayerService?.controlSeek(for: player, offsetUs: seconds * 1_000_000)
    }
    
    func setLoopStatus(_ loopStatus: String, for player: PlayerRemote) {
        mediaPlayerService?.controlSetLoopStatus(for: player, loopStatus: loopStatus)
    }
    
    func setShuffle(_ shuffle: Bool, for player: PlayerRemote) {
        mediaPlayerService?.controlSetShuffle(for: player, shuffle: shuffle)
    }
    
    // MARK: - System Volume Commands
    
    func setSinkVolume(_ volume: Int, sink: SystemVolumeService.AudioSink, device: Device) {
        systemVolumeService?.setRemoteSinkVolume(volume, sinkName: sink.name, onDevice: device)
    }
    
    // MARK: - Private
    
    private func rebuildDevices() {
        // Defer to next runloop to avoid "Publishing changes from within view updates" error
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Snapshot previous reachability so we can detect transitions below
            let previousReachable = Dictionary(uniqueKeysWithValues: self.devices.map { ($0.id, $0.isReachable) })
            
            // Include both tracked (paired) and config-only (unavailable) devices so the
            // sidebar always shows all paired devices regardless of connectivity state
            let allPaired = self.deviceDataSource.pairedDevices + self.deviceDataSource.unavailableDevices
            let reachableIds = Set(self.deviceDataSource.pairedRechableDevices.map(\.id))
            
            // Stamp last-seen whenever a device transitions reachable → unreachable
            let now = Date()
            for device in allPaired {
                let wasReachable = previousReachable[device.id] ?? false
                let isNowReachable = reachableIds.contains(device.id)
                if wasReachable && !isNowReachable {
                    self.lastSeenDates[device.id] = now
                }
            }
            
            self.devices = allPaired.map { device in
                return DashboardDevice(
                    id: device.id,
                    device: device,
                    isReachable: reachableIds.contains(device.id),
                    lastSeenDate: self.lastSeenDates[device.id],
                    players: self.mediaPlayerService?.players[device.id] ?? [],
                    batteryStatus: self.batteryService?.statuses[device.id],
                    connectivityStatus: self.connectivityReportService?.statuses[device.id]
                )
            }
            .sorted { $0.device.name < $1.device.name }
            
            // Auto-select first device if nothing is selected or selection is gone
            if self.selectedDeviceId == nil || !self.devices.contains(where: { $0.id == self.selectedDeviceId }) {
                self.selectedDeviceId = self.devices.first?.id
            }
        }
    }
}
