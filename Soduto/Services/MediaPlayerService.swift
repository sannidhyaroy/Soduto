//
//  MediaPlayerService.swift
//  Soduto
//
//  Created by Swapnil Devesh on 2025-05-20.
//  Copyright © 2025 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import os
import MediaPlayer
import UserNotifications
import CryptoKit

/// Media Player Service (KDE Connect MPRIS Remote Plugin)
///
/// Implements the KDE Connect MPRIS remote (controller) side: receives media player state
/// from a connected device and exposes it via macOS Now Playing (MPNowPlayingInfoCenter),
/// allowing macOS media keys and the Control Center widget to control remote playback.
///
/// The outgoing/exposer side (advertising macOS media state to the remote device so the
/// phone can control Mac playback) is not yet implemented. The planned approach is to use
/// MediaRemote.framework via dlopen/dlsym to observe system-wide Now Playing changes.
///
/// Packets received — type "kdeconnect.mpris":
/// - playerList (array): list of active media players on the remote device
/// - supportAlbumArtPayload (boolean): sent with playerList; indicates the remote
///   supports transferring album art as a packet payload (Soduto reads this flag
///   and gates all album art requests on it)
/// - player (string): name of the player this status update applies to
/// - isPlaying (boolean): whether the player is currently playing
/// - canPlay, canPause, canGoNext, canGoPrevious, canSeek (boolean): player capabilities
/// - pos (int): current playback position (ms)
/// - length (int): total track length (ms)
/// - artist, title, album (string): track metadata
/// - nowPlaying (string): deprecated "Artist - Title" combined field — received but ignored
/// - albumArtUrl (string): URL of the current track's album art
/// - transferringAlbumArt (boolean): marks a packet that carries an album art payload
/// - volume (int): player volume (0–100)
/// - loopStatus (string): loop mode — "None", "Track", or "Playlist" (received, not yet exposed in UI)
/// - shuffle (boolean): shuffle state (received, not yet exposed in UI)
///
/// Packets sent — type "kdeconnect.mpris.request":
/// - requestPlayerList (boolean): ask the remote to send its player list
/// - player (string): the player to target for the following command
/// - requestNowPlaying (boolean): ask the remote to send current track info
/// - requestVolume (boolean): ask the remote to send current volume
/// - action (string): playback command — "Play", "Pause", "PlayPause", "Stop", "Next", "Previous"
/// - setVolume (int): set player volume (0–100)
/// - Seek (int): seek relative to current position (µs — note capital S, different unit)
/// - SetPosition (int): set absolute playback position (ms — note capital S)
/// - albumArtUrl (string): request the remote to transfer album art for this URL as a payload
/// - setLoopStatus (string): set loop mode (protocol-defined, not yet implemented)
/// - setShuffle (boolean): set shuffle mode (protocol-defined, not yet implemented)
///
public class MediaPlayerService: Service, DownloadTaskDelegate, ObservableObject {
    
    let un = UNUserNotificationCenter.current()
    
    // MARK: Types
    
    public typealias PlayerIdentity = String
    
    enum UserInfoProperty: String {
        case deviceId = "com.soduto.services.mpris.deviceId"
        case playerIdentity = "com.soduto.services.mpris.playerIdentity"
    }
    
    enum ActionId: ServiceAction.Id {
        case refresh
    }
    
    private struct DownloadInfo {
        let task: DownloadTask
        let fileHash: String?
        let playerIdentity: String
        let albumArtUrl: String
        let partFileURL: URL
        let device: Device
    }
    
    
    /// Owns a temporary download stream and guarantees closure
    private final class TempDownloadStream {
        let stream: OutputStream
        private var isTransferred = false
        
        init(stream: OutputStream) {
            self.stream = stream
        }
        
        deinit {
            if !isTransferred {
                stream.close()
            }
        }
        
        func transfer() -> OutputStream {
            isTransferred = true
            return stream
        }
    }
    
    // MARK: Service properties
    
    public static let serviceId: Service.Id = "com.soduto.services.mpris"
    
    public let incomingCapabilities = Set<Service.Capability>([ DataPacket.mprisPacketType ])
    public let outgoingCapabilities = Set<Service.Capability>([ DataPacket.mprisRequestPacketType ])
    
    private var albumArtDownloadInfos: [DownloadInfo] = []
    private var downloadedAlbumArtFileURLByPlayerIdentity: [String: URL] = [:]
    private var cachedDownloadedAlbumArtFileURLByHash: [String: URL] = [:]
    
    /// Tracks per-device whether the remote supports album art payload transfers
    /// Read from `supportAlbumArtPayload` in incoming `kdeconnect.mpris` packets
    private var deviceSupportsAlbumArtPayload: [String: Bool] = [:]
    
    /// Available players grouped by device
    @Published private var players: [String: [PlayerRemote]] = [:]
    /// Keeps track of the last player that was playing
    private var lastActivePlayer: PlayerRemote? = nil
    private var nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
    private var commandCenter = MPRemoteCommandCenter.shared()
    
    // MARK: Initialization
    
    public init() {
        setupCommandCenter()
        
        // Clean up old cache files on startup
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.cleanupOldCacheFiles()
            self?.logCacheStats()
        }
    }
    
    // MARK: Service methods
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        guard dataPacket.isMprisPacket else { return false }
        
        Logger.services.debug("MPRIS::handleDataPacket(<\(dataPacket, privacy: .public)> fromDevice:<\(device, privacy: .public)>)")
        
        do {
            // Read `supportAlbumArtPayload` from any `kdeconnect.mpris` packet
            // Per protocol it's sent with playerList, but we read it from any packet for robustness
            if let supportsAlbumArt = try dataPacket.getSupportAlbumArtPayload() {
                deviceSupportsAlbumArtPayload[device.id] = supportsAlbumArt
                Logger.services.debug("MPRIS::Device \(device.name, privacy: .public) supportAlbumArtPayload: \(supportsAlbumArt, privacy: .public)")
            }
            
            if let playerList = try dataPacket.getPlayerList() {
                handlePlayerList(playerList, from: device)
            } else if let player = try dataPacket.getPlayer() {
                // Check if this is an album art transfer packet
                if let isTransferringAlbumArt = try dataPacket.getTransferringAlbumArt(), isTransferringAlbumArt,
                   let albumArtUrl = try dataPacket.getAlbumArtUrl(),
                   dataPacket.hasPayload() {
                    if let downloadTask = dataPacket.downloadTask {
                        handleAlbumArtTransfer(player: player, albumArtUrl: albumArtUrl, downloadTask: downloadTask, from: device)
                    }
                } else {
                    // Regular player update
                    handlePlayerUpdate(player: player, packet: dataPacket, from: device)
                }
            }
        } catch {
            Logger.services.error("MPRIS::Error handling MPRIS packet: \(error, privacy: .public)")
        }
        
        return true
    }
    
    public func setup(for device: Device) {
        requestPlayerList(from: device)
    }
    
    public func cleanup(for device: Device) {
        // Remove players for this device
        if let devicePlayers = players.removeValue(forKey: device.id) {
            if devicePlayers.contains(where: { $0 === lastActivePlayer }) {
                setActivePlayer(nil)
                // Promote a player from another still-connected device if one is playing
                if let fallback = findActivePlayer() {
                    setActivePlayer(fallback)
                }
            }
            for player in devicePlayers {
                player.cleanup()
            }
        }
        
        // Remove album art capability flag for this device
        deviceSupportsAlbumArtPayload.removeValue(forKey: device.id)
        
        // Cancel any ongoing album art downloads for this device
        let downloadsToCancel = albumArtDownloadInfos.filter { $0.device.id == device.id }
        for downloadInfo in downloadsToCancel {
            Logger.services.debug("MPRIS::Cancelling album art download for device \(device.name, privacy: .public)")
            downloadInfo.task.cancel()
        }
        
        // Remove download info for this device
        albumArtDownloadInfos.removeAll { $0.device.id == device.id }
        
        // Clean up any player-specific album art files (keep cache for reuse)
        let playerIdentities = Set(players.values.flatMap { $0 }.map { $0.identity })
        downloadedAlbumArtFileURLByPlayerIdentity = downloadedAlbumArtFileURLByPlayerIdentity.filter { key, _ in
            playerIdentities.contains(key)
        }
    }
    
    public func actions(for device: Device) -> [ServiceAction] {
        guard device.incomingCapabilities.contains(DataPacket.mprisPacketType) else { return [] }
        guard device.pairingStatus == .Paired else { return [] }
        
        return [
            ServiceAction(id: ActionId.refresh.rawValue, group: "setup", title: "Request Media Players", description: "Request available media players from the remote device", service: self, device: device)
        ]
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device) {
        guard let actionId = ActionId(rawValue: id) else { return }
        guard device.pairingStatus == .Paired else { return }
        
        switch actionId {
        case .refresh:
            requestPlayerList(from: device)
        }
    }
    
    // MARK: DownloadTaskDelegate
    
    public func downloadTask(_ task: DownloadTask, finishedWithSuccess success: Bool) {
        Logger.services.debug("MPRIS::downloadTask(<\(task.id, privacy: .public)> finishedWithSuccess:<\(success, privacy: .public)>)")
        
        guard let index = self.albumArtDownloadInfos.firstIndex(where: { $0.task === task }) else {
            Logger.services.error("MPRIS::Download task not found in tracking list")
            return
        }
        let info = self.albumArtDownloadInfos.remove(at: index)
        
        if success {
            do {
                // Create a more descriptive filename with proper extension detection
                let fileExtension: String
                if let artURL = URL(string: info.albumArtUrl),
                   !artURL.pathExtension.isEmpty {
                    fileExtension = artURL.pathExtension.lowercased()
                } else {
                    // Default to png if we can't determine the extension
                    fileExtension = "png"
                }
                
                let fileName = "\(info.playerIdentity)-albumart-\(Int(Date().timeIntervalSince1970)).\(fileExtension)"
                
                let finalFileURL = try self.renamePartFile(url: info.partFileURL, to: fileName)
                Logger.services.debug("MPRIS::Album art downloaded to: \(finalFileURL.path, privacy: .public)")
                
                self.downloadedAlbumArtFileURLByPlayerIdentity[info.playerIdentity] = finalFileURL
                
                // Cache the album art using the hash
                if let fileHash = info.fileHash {
                    do {
                        let cachedFileURL = try self.copyFileToCache(url: finalFileURL, hash: fileHash)
                        self.cachedDownloadedAlbumArtFileURLByHash[fileHash] = cachedFileURL
                        Logger.services.debug("MPRIS::Album art cached with hash \(fileHash, privacy: .public) at \(cachedFileURL.path, privacy: .public)")
                    } catch {
                        Logger.services.error("MPRIS::Failed to cache album art: \(error, privacy: .public)")
                        // Continue even if caching fails
                    }
                }
                
                // Update the player with the downloaded album art
                if let devicePlayers = players[info.device.id] {
                    for player in devicePlayers {
                        if player.identity == info.playerIdentity {
                            Logger.services.debug("MPRIS::Updating player \(player.identity, privacy: .public) with downloaded album art")
                            player.updateAlbumArt(finalFileURL)
                            break
                        }
                    }
                }
                
            } catch {
                Logger.services.error("MPRIS::Error processing downloaded album art: \(error, privacy: .public)")
            }
        } else {
            Logger.services.error("MPRIS::Album art download failed for player \(info.playerIdentity, privacy: .public)")
            
            // Clean up the partial file
            do {
                if FileManager.default.fileExists(atPath: info.partFileURL.path) {
                    try FileManager.default.removeItem(at: info.partFileURL)
                }
            } catch {
                Logger.services.error("MPRIS::Failed to clean up partial file: \(error, privacy: .public)")
            }
        }
    }
    
    
    // MARK: Private methods - Packet Handlers
    
    private func handlePlayerList(_ playerList: [String], from device: Device) {
        Logger.services.debug("MPRIS::Handle player list \(playerList, privacy: .public) from device \(device.name, privacy: .public)")
        
        // Remove any players that are no longer available
        if var devicePlayers = players[device.id] {
            devicePlayers = devicePlayers.filter { player in
                if !playerList.contains(player.identity) {
                    if player === lastActivePlayer {
                        setActivePlayer(nil)
                    }
                    player.cleanup()
                    return false
                }
                return true
            }
            players[device.id] = devicePlayers
        }
        
        // Create or update players
        var updatedPlayers = [PlayerRemote]()
        for playerIdentity in playerList {
            var existingPlayer: PlayerRemote? = nil
            
            if let devicePlayers = players[device.id] {
                existingPlayer = devicePlayers.first { $0.identity == playerIdentity }
            }
            
            if let player = existingPlayer {
                updatedPlayers.append(player)
            } else {
                let player = PlayerRemote(device: device, identity: playerIdentity)
                updatedPlayers.append(player)
            }
            
            // Request current track info and volume for all players
            requestPlayerInfo(player: playerIdentity, from: device)
        }
        
        players[device.id] = updatedPlayers
    }
    
    private func handleAlbumArtTransfer(player: String, albumArtUrl: String, downloadTask: DownloadTask, from device: Device) {
        Logger.services.debug("MPRIS::Handle album art transfer for player \(player, privacy: .public) from device \(device.name, privacy: .public)")
        startAlbumArtDownload(player: player, albumArtUrl: albumArtUrl, downloadTask: downloadTask, from: device)
    }
    
    private func handlePlayerUpdate(player: String, packet: DataPacket, from device: Device) {
        Logger.services.debug("MPRIS::Handle player update for \(player, privacy: .public) from device \(device.name, privacy: .public)")
        
        guard let devicePlayers = players[device.id] else { return }
        guard let playerToUpdate = devicePlayers.first(where: { $0.identity == player }) else { return }
        
        do {
            let isPlaying = try packet.getIsPlaying() ?? playerToUpdate.isPlaying
            let position = try packet.getPosition() ?? playerToUpdate.position
            let artist = try packet.getArtist() ?? playerToUpdate.artist
            let title = try packet.getTitle() ?? playerToUpdate.title
            let album = try packet.getAlbum() ?? playerToUpdate.album
            let length = try packet.getLength() ?? playerToUpdate.length
            let albumArtUrl = try packet.getAlbumArtUrl()
            let volume = try packet.getVolume() ?? playerToUpdate.volume
            let canPause = try packet.getCanPause() ?? playerToUpdate.canPause
            let canPlay = try packet.getCanPlay() ?? playerToUpdate.canPlay
            let canGoNext = try packet.getCanGoNext() ?? playerToUpdate.canGoNext
            let canGoPrevious = try packet.getCanGoPrevious() ?? playerToUpdate.canGoPrevious
            let canSeek = try packet.getCanSeek() ?? playerToUpdate.canSeek
            
            playerToUpdate.update(
                isPlaying: isPlaying,
                position: position,
                artist: artist,
                title: title,
                album: album,
                length: length,
                volume: volume,
                canPause: canPause,
                canPlay: canPlay,
                canGoNext: canGoNext,
                canGoPrevious: canGoPrevious,
                canSeek: canSeek
            )
            
            // If this player is playing, promote it to active
            if isPlaying {
                Logger.services.debug("MPRIS::handlePlayerUpdate - setting lastActivePlayer to: \(player, privacy: .public)")
                setActivePlayer(playerToUpdate)
            }
            
            // Handle album art updates
            if let albumArtUrl = albumArtUrl {
                // Request album art if the URL changed, or if a previous download for this URL failed (albumArtUrl is set but albumArtImage is still nil)
                if playerToUpdate.albumArtUrl != albumArtUrl || playerToUpdate.albumArtImage == nil {
                    Logger.services.debug("MPRIS::Album art URL changed for \(player, privacy: .public): \(albumArtUrl, privacy: .public)")
                    playerToUpdate.albumArtUrl = albumArtUrl
                    
                    // Check if we already have this album art in cache before requesting
                    if let hash = getHashForAlbumArt(player: player, albumArtUrl: albumArtUrl),
                       let cachedFileURL = getCachedAlbumArt(hash: hash) {
                        Logger.services.debug("MPRIS::Using cached album art for \(player, privacy: .public)")
                        do {
                            let copiedFileURL = try copyFileFromCache(url: cachedFileURL, playerIdentity: player)
                            downloadedAlbumArtFileURLByPlayerIdentity[player] = copiedFileURL
                            playerToUpdate.updateAlbumArt(copiedFileURL)
                        } catch {
                            Logger.services.error("MPRIS::Failed to use cached album art: \(error, privacy: .public)")
                            if deviceSupportsAlbumArtPayload[device.id] == true {
                                requestAlbumArt(player: player, albumArtUrl: albumArtUrl, from: device)
                            }
                        }
                    } else if deviceSupportsAlbumArtPayload[device.id] == true {
                        requestAlbumArt(player: player, albumArtUrl: albumArtUrl, from: device)
                    } else {
                        Logger.services.debug("MPRIS::Skipping album art request — device has not declared supportAlbumArtPayload")
                    }
                }
            } else if playerToUpdate.albumArtUrl != nil {
                // Album art URL was cleared
                Logger.services.debug("MPRIS::Album art cleared for \(player, privacy: .public)")
                playerToUpdate.albumArtUrl = nil
                playerToUpdate.albumArtImage = nil
                playerToUpdate.updateNowPlayingInfo()
            }
            
            // Update the command center only if this is already the active player
            // (capability changes while paused). New active player transition is handled by setActivePlayer()
            if !isPlaying && playerToUpdate === lastActivePlayer {
                updateCommandCenterForActivePlayer(playerToUpdate)
            }
            
            // If this player is playing, ensure other players are marked as not playing
            if isPlaying {
                for deviceID in players.keys {
                    if let devicePlayers = players[deviceID] {
                        for otherPlayer in devicePlayers {
                            if otherPlayer !== playerToUpdate && otherPlayer.isPlaying {
                                Logger.services.debug("MPRIS::handlePlayerUpdate - marking \(otherPlayer.identity, privacy: .public) as not playing")
                                otherPlayer.isPlaying = false
                            }
                        }
                    }
                }
            }
            
        } catch {
            Logger.services.error("MPRIS::Error parsing player update: \(error, privacy: .public)")
        }
    }
    
    // MARK: Private methods - Remote Command Center
    
    private func setupCommandCenter() {
        // Remove all targets from command center
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.stopCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        
        // Setup command handlers
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let activePlayer = self?.findActivePlayer() else { return .commandFailed }
            self?.sendPauseCommand(to: activePlayer)
            return .success
        }
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let activePlayer = self?.findActivePlayer() else { return .commandFailed }
            self?.sendPlayCommand(to: activePlayer)
            return .success
        }
        
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let activePlayer = self?.findActivePlayer() else { return .commandFailed }
            self?.sendPlayPauseCommand(to: activePlayer)
            return .success
        }
        
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let activePlayer = self?.findActivePlayer() else { return .commandFailed }
            guard activePlayer.canGoNext else { return .commandFailed }
            self?.sendNextCommand(to: activePlayer)
            return .success
        }
        
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let activePlayer = self?.findActivePlayer() else { return .commandFailed }
            guard activePlayer.canGoPrevious else { return .commandFailed }
            self?.sendPreviousCommand(to: activePlayer)
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            Logger.services.debug("MPRIS::changePlaybackPositionCommand triggered")
            guard let activePlayer = self?.findActivePlayer() else {
                Logger.services.debug("MPRIS::changePlaybackPositionCommand - no active player found")
                return .commandFailed
            }
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                let position = Int(event.positionTime)
                Logger.services.debug("MPRIS::changePlaybackPositionCommand - activePlayer: \(activePlayer.identity, privacy: .public), position: \(position, privacy: .public)")
                self?.sendSetPositionCommand(to: activePlayer, position: position)
                return .success
            }
            Logger.services.debug("MPRIS::changePlaybackPositionCommand - invalid event type")
            return .commandFailed
        }
    }
    
    // MARK: Active Player Management
    //
    // macOS constraint: MPNowPlayingInfoCenter.default() is a per-app singleton
    // The entire Soduto process gets exactly one slot in the Now Playing widget /
    // Control Center, regardless of how many remote players or devices are connected
    //
    // KDE Desktop handles this differently: it creates a separate D-Bus connection
    // per remote player, registering each as an independent MPRIS2 service
    // (org.mpris.MediaPlayer2.kdeconnect.<uuid>), so the system sees N virtual
    // players. macOS has no equivalent mechanism without spawning separate processes
    // (too heavy to justify)
    //
    // Soduto's approach: one "active" player at a time owns the info center slot
    // The most recently playing player wins. A future status bar menu will let the
    // user manually switch the active player between all connected players/devices.
    // `setActivePlayer()` is the single choke-point for all active player transitions
    
    private func setActivePlayer(_ player: PlayerRemote?) {
        guard player !== lastActivePlayer else { return }
        lastActivePlayer?.isActive = false  // deactivate old player first, then reassign
        lastActivePlayer = player
        if let player = player {
            player.isActive = true
            player.updateNowPlayingInfo()
            updateCommandCenterForActivePlayer(player)
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }
    
    private func findActivePlayer() -> PlayerRemote? {
        Logger.services.debug("MPRIS::findActivePlayer() called")
        
        // First, check if we have a last active player and it's still valid (exists in players dictionary)
        if let lastPlayer = lastActivePlayer {
            Logger.services.debug("MPRIS::findActivePlayer() - checking lastActivePlayer: \(lastPlayer.identity, privacy: .public)")
            // Make sure this player still exists in the dictionary
            if let devicePlayers = players[lastPlayer.device.id], devicePlayers.contains(where: { $0 === lastPlayer }) {
                Logger.services.debug("MPRIS::findActivePlayer() - returning lastActivePlayer: \(lastPlayer.identity, privacy: .public)")
                return lastPlayer
            } else {
                Logger.services.debug("MPRIS::findActivePlayer() - lastActivePlayer no longer exists, clearing it")
                self.lastActivePlayer = nil
            }
        }
        
        // Next, look for a player that is currently playing
        for deviceID in players.keys {
            if let devicePlayers = players[deviceID] {
                for player in devicePlayers {
                    Logger.services.debug("MPRIS::findActivePlayer() - checking player: \(player.identity, privacy: .public), isPlaying: \(player.isPlaying, privacy: .public)")
                    if player.isPlaying {
                        Logger.services.debug("MPRIS::findActivePlayer() - found playing player: \(player.identity, privacy: .public)")
                        return player
                    }
                }
            }
        }
        
        // If no player is playing, return the first player
        for deviceID in players.keys {
            if let devicePlayers = players[deviceID], let player = devicePlayers.first {
                Logger.services.debug("MPRIS::findActivePlayer() - no playing player found, returning first player: \(player.identity, privacy: .public)")
                return player
            }
        }
        
        Logger.services.debug("MPRIS::findActivePlayer() - no players found, returning nil")
        return nil
    }
    
    private func updateCommandCenterForActivePlayer(_ player: PlayerRemote) {
        // Update commands availability
        commandCenter.pauseCommand.isEnabled = player.canPause
        commandCenter.playCommand.isEnabled = player.canPlay
        commandCenter.togglePlayPauseCommand.isEnabled = player.canPause || player.canPlay
        commandCenter.nextTrackCommand.isEnabled = player.canGoNext
        commandCenter.previousTrackCommand.isEnabled = player.canGoPrevious
        commandCenter.changePlaybackPositionCommand.isEnabled = player.canSeek && player.length > 0
    }
    
    // MARK: Private methods - Player Commands
    
    private func sendPlayPauseCommand(to player: PlayerRemote) {
        player.device.send(DataPacket.mprisRequestPacket(player: player.identity, action: "PlayPause"))
    }
    
    private func sendPlayCommand(to player: PlayerRemote) {
        player.device.send(DataPacket.mprisRequestPacket(player: player.identity, action: "Play"))
    }
    
    private func sendPauseCommand(to player: PlayerRemote) {
        player.device.send(DataPacket.mprisRequestPacket(player: player.identity, action: "Pause"))
    }
    
    private func sendNextCommand(to player: PlayerRemote) {
        player.device.send(DataPacket.mprisRequestPacket(player: player.identity, action: "Next"))
    }
    
    private func sendPreviousCommand(to player: PlayerRemote) {
        player.device.send(DataPacket.mprisRequestPacket(player: player.identity, action: "Previous"))
    }
    
    private func sendStopCommand(to player: PlayerRemote) {
        player.device.send(DataPacket.mprisRequestPacket(player: player.identity, action: "Stop"))
    }
    
    private func sendSetVolumeCommand(to player: PlayerRemote, volume: Int) {
        player.device.send(DataPacket.mprisSetVolumePacket(player: player.identity, volume: volume))
    }
    
    private func sendSeekCommand(to player: PlayerRemote, offset: Int) {
        player.device.send(DataPacket.mprisSeekPacket(player: player.identity, offset: offset))
    }
    
    private func sendSetPositionCommand(to player: PlayerRemote, position: Int) {
        let positionInMs = position * 1000
        Logger.services.debug("MPRIS::sendSetPositionCommand() - player: \(player.identity, privacy: .public), position: \(position, privacy: .public)s -> \(positionInMs, privacy: .public)ms")
        player.device.send(DataPacket.mprisSetPositionPacket(player: player.identity, position: positionInMs))
    }
    
    // MARK: Private methods - Information Requests
    
    private func requestPlayerList(from device: Device) {
        device.send(DataPacket.mprisRequestPlayerListPacket())
    }
    
    private func requestPlayerInfo(player: String, from device: Device) {
        device.send(DataPacket.mprisRequestInfoPacket(player: player))
    }
    
    private func requestAlbumArt(player: String, albumArtUrl: String, from device: Device) {
        device.send(DataPacket.mprisRequestAlbumArtPacket(player: player, albumArtUrl: albumArtUrl))
    }
    
    // MARK: Private methods - Album Art Download
    
    private func startAlbumArtDownload(player: String, albumArtUrl: String, downloadTask: DownloadTask, from device: Device) {
        Logger.services.debug("MPRIS::Starting album art download for player \(player, privacy: .public) from \(albumArtUrl, privacy: .public)")
        
        let downloadFileHash = getHashForAlbumArt(player: player, albumArtUrl: albumArtUrl)
        
        // Check if we already have this album art cached
        if let hash = downloadFileHash, let cachedFileURL = getCachedAlbumArt(hash: hash) {
            Logger.services.debug("MPRIS::Found cached album art for hash \(hash, privacy: .public) at \(cachedFileURL, privacy: .public)")
            do {
                let copiedFromCacheFileURL = try self.copyFileFromCache(url: cachedFileURL, playerIdentity: player)
                self.downloadedAlbumArtFileURLByPlayerIdentity[player] = copiedFromCacheFileURL
                
                // Update the player with the album art
                if let devicePlayers = players[device.id] {
                    for playerObj in devicePlayers {
                        if playerObj.identity == player {
                            playerObj.updateAlbumArt(copiedFromCacheFileURL)
                            break
                        }
                    }
                }
                return
            } catch {
                Logger.services.error("MPRIS::Failed to copy from cache: \(error, privacy: .public)")
                // Continue with download if cache copy fails
            }
        }
        
        // Check if we already have a download in progress for this album art
        if albumArtDownloadInfos.contains(where: { $0.albumArtUrl == albumArtUrl && $0.playerIdentity == player }) {
            Logger.services.debug("MPRIS::Album art download already in progress for \(albumArtUrl, privacy: .public)")
            return
        }
        
        // Start new download
        if let (tempStream, partFileURL) = self.streamForTempDownload() {
            let downloadInfo = DownloadInfo(
                task: downloadTask,
                fileHash: downloadFileHash,
                playerIdentity: player,
                albumArtUrl: albumArtUrl,
                partFileURL: partFileURL,
                device: device
            )
            self.albumArtDownloadInfos.append(downloadInfo)
            downloadTask.delegate = self
            downloadTask.start(withStream: tempStream.transfer())
            Logger.services.debug("MPRIS::Started download task for album art")
        } else {
            Logger.services.error("MPRIS::Failed to create download stream for album art")
        }
    }
    
    private func getHashForAlbumArt(player: String, albumArtUrl: String) -> String? {
        // Generate a deterministic hash of the album art URL for caching.
        // Using SHA256 for stable, cross-session cache keys.
        
        guard let data = albumArtUrl.data(using: .utf8) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    private func getCacheDirectory() -> URL {
        // Use a proper cache directory like GSConnect
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cacheDirectory.appendingPathComponent("com.soduto.mpris", isDirectory: true)
    }
    
    private func streamForTempDownload() -> (TempDownloadStream, URL)? {
        let temporaryDirectory = NSTemporaryDirectory()
        
        for attempt in 1...10000 {
            let partFileURL = URL(fileURLWithPath: temporaryDirectory).appendingPathComponent("\(UUID().uuidString).part")
            
            Logger.services.debug("MPRIS::Attempt \(attempt, privacy: .public): creating temp album art file at \(partFileURL.path, privacy: .public)")
            if FileManager.default.fileExists(atPath: partFileURL.path) {
                Logger.services.debug("MPRIS::Temp file already exists, retrying")
                continue
            }
            guard let stream = OutputStream(url: partFileURL, append: false) else {
                Logger.services.debug("MPRIS::Failed to create OutputStream for \(partFileURL.path, privacy: .public)")
                continue
            }
            stream.open()
            if stream.hasSpaceAvailable {
                Logger.services.debug("MPRIS::Successfully opened writable stream at \(partFileURL.path, privacy: .public)")
                return (TempDownloadStream(stream: stream), partFileURL)
            }
            Logger.services.debug("MPRIS::Stream opened but not writable (status=\(stream.streamStatus.rawValue, privacy: .public)), retrying")
            stream.close()
        }
        Logger.services.error("MPRIS::Failed to create writable temp album art stream after 10000 attempts")
        return nil
    }
    
    private func renamePartFile(url partFileURL: URL, to fileName: String) throws -> URL {
        // Try rename file from temporary *.part name to final path based on original file name
        var finalFileURL = partFileURL.deletingLastPathComponent().appendingPathComponent(fileName)
        
        for _ in 1...10000 {
            if !FileManager.default.fileExists(atPath: finalFileURL.path) {
                try FileManager.default.moveItem(at: partFileURL, to: finalFileURL)
                return finalFileURL
            }
            
            let random = UUID().uuidString
            finalFileURL = partFileURL.deletingLastPathComponent().appendingPathComponent("\(fileName).\(random)")
        }
        
        throw DataPacket.MprisError.partFileRenameFailed
    }
    
    private func copyFileToCache(url fileURL: URL, hash fileHash: String) throws -> URL {
        let cacheDirURL = getCacheDirectory()
        
        try FileManager.default.createDirectory(at: cacheDirURL, withIntermediateDirectories: true, attributes: nil)
        
        let cacheFileURL = cacheDirURL.appendingPathComponent(fileHash)
        
        if !FileManager.default.fileExists(atPath: cacheFileURL.path) {
            try FileManager.default.copyItem(at: fileURL, to: cacheFileURL)
        }
        
        return cacheFileURL
    }
    
    private func copyFileFromCache(url fileURL: URL, playerIdentity: String) throws -> URL {
        let temporaryDirectory = NSTemporaryDirectory()
        let fileName = "\(playerIdentity)-\(UUID().uuidString).png"
        let finalURL = URL(fileURLWithPath: fileName, relativeTo: URL(fileURLWithPath: temporaryDirectory, isDirectory: true))
        try FileManager.default.copyItem(at: fileURL, to: finalURL)
        return finalURL
    }
    
    private func getCachedAlbumArt(hash: String) -> URL? {
        let cacheFileURL = getCacheDirectory().appendingPathComponent(hash)
        if FileManager.default.fileExists(atPath: cacheFileURL.path) {
            return cacheFileURL
        }
        return nil
    }
    
    // MARK: Cache Management
    
    private func cleanupOldCacheFiles() {
        let cacheDirectory = getCacheDirectory()
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: cacheDirectory,
                                                                       includingPropertiesForKeys: [.contentModificationDateKey],
                                                                       options: [])
            
            let cutoffDate = Date().addingTimeInterval(-7 * 24 * 60 * 60) // 7 days ago
            
            for fileURL in contents {
                if let modificationDate = try fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modificationDate < cutoffDate {
                    try FileManager.default.removeItem(at: fileURL)
                    Logger.services.debug("MPRIS::Cleaned up old cache file: \(fileURL.lastPathComponent, privacy: .public)")
                }
            }
        } catch {
            Logger.services.error("MPRIS::Failed to cleanup old cache files: \(error, privacy: .public)")
        }
    }
    
    private func logCacheStats() {
        let cacheDirectory = getCacheDirectory()
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: cacheDirectory,
                                                                       includingPropertiesForKeys: [.fileSizeKey],
                                                                       options: [])
            
            let totalSize = contents.compactMap { url -> Int? in
                guard let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
                      let fileSize = resourceValues.fileSize else {
                    return nil
                }
                return fileSize
            }.reduce(0, +)
            
            Logger.services.debug("MPRIS::Cache stats - Files: \(contents.count, privacy: .public), Total size: \(totalSize, privacy: .public) bytes")
        } catch {
            Logger.services.debug("MPRIS::Could not get cache stats: \(error, privacy: .public)")
        }
    }
}

// MARK: - Player Remote Class

class PlayerRemote: NSObject {
    // Player identity
    let device: Device
    let identity: String
    
    // Player state
    var isPlaying: Bool = false {
        didSet {
            if isPlaying != oldValue {
                updateNowPlayingInfo()
            }
        }
    }
    var position: Int = 0
    // timestamp records when `position` was last received from the remote.
    // macOS interpolates the displayed playback position automatically from
    // MPNowPlayingInfoPropertyElapsedPlaybackTime + MPNowPlayingInfoPropertyPlaybackRate,
    // so we don't need to extrapolate manually (unlike Android's lastPositionTime
    // or KDE's lastPositionTime which are used for D-Bus position reporting).
    // Stored here for potential future use, e.g. more precise seek offset calculation.
    var timestamp: Date = Date()
    
    // Track metadata
    var artist: String?
    var title: String?
    var album: String?
    var albumArtUrl: String?
    var albumArtImage: NSImage?
    var length: Int = 0
    
    // Player capabilities
    var volume: Int = 50
    var canPause: Bool = false
    var canPlay: Bool = false
    var canGoNext: Bool = false
    var canGoPrevious: Bool = false
    var canSeek: Bool = false
    var isActive: Bool = false
    
    // Now playing info
    private let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
    
    init(device: Device, identity: String) {
        self.device = device
        self.identity = identity
        super.init()
    }
    
    func update(isPlaying: Bool,
                position: Int,
                artist: String?,
                title: String?,
                album: String?,
                length: Int,
                volume: Int,
                canPause: Bool,
                canPlay: Bool,
                canGoNext: Bool,
                canGoPrevious: Bool,
                canSeek: Bool) {
        
        var needsInfoUpdate = false
        
        if self.isPlaying != isPlaying {
            self.isPlaying = isPlaying
            needsInfoUpdate = true
        }
        
        // Check if position changed significantly (more than 2 seconds difference)
        // This helps detect seeks while avoiding constant updates during normal playback
        let positionDiff = abs(self.position - position)
        if positionDiff > 2000 {
            needsInfoUpdate = true
        }
        
        self.position = position
        self.timestamp = Date()
        
        if self.artist != artist || self.title != title || self.album != album || self.length != length {
            self.artist = artist
            self.title = title
            self.album = album
            self.length = length
            needsInfoUpdate = true
        }
        
        self.volume = volume
        self.canPause = canPause
        self.canPlay = canPlay
        self.canGoNext = canGoNext
        self.canGoPrevious = canGoPrevious
        self.canSeek = canSeek
        
        if needsInfoUpdate {
            updateNowPlayingInfo()
        }
    }
    
    func updateAlbumArt(_ fileURL: URL) {
        Logger.services.debug("MPRIS::PlayerRemote updating album art for \(self.identity, privacy: .public) from \(fileURL.path, privacy: .public)")
        
        if let image = NSImage(contentsOf: fileURL) {
            self.albumArtImage = image
            Logger.services.debug("MPRIS::PlayerRemote successfully loaded album art image (\(image.size.width, privacy: .public)x\(image.size.height, privacy: .public))")
        } else {
            Logger.services.error("MPRIS::PlayerRemote failed to load album art image from \(fileURL.path, privacy: .public)")
            self.albumArtImage = nil
        }
        
        updateNowPlayingInfo()
    }
    
    func updateNowPlayingInfo() {
        guard isActive else { return }
        // Always start from a fresh dictionary. Inheriting the existing info center
        // state would leave stale fields from a previous player (e.g. artwork from
        // player A lingering when player B takes over and has no art of its own)
        var nowPlayingInfo = [String: Any]()
        
        // Set track info
        if let title = self.title, !title.isEmpty {
            nowPlayingInfo[MPMediaItemPropertyTitle] = title
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyTitle)
        }
        
        if let artist = self.artist, !artist.isEmpty {
            nowPlayingInfo[MPMediaItemPropertyArtist] = artist
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtist)
        }
        
        if let album = self.album, !album.isEmpty {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = album
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyAlbumTitle)
        }
        
        // Set playback info
        if length > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = TimeInterval(length / 1000)
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = TimeInterval(position / 1000)
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
            nowPlayingInfo.removeValue(forKey: MPNowPlayingInfoPropertyElapsedPlaybackTime)
        }
        
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        // Set artwork
        if let image = albumArtImage {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                return image
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
            Logger.services.debug("MPRIS::PlayerRemote set artwork for \(self.identity, privacy: .public)")
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtwork)
        }
        
        // Add device and player info for identification
        nowPlayingInfo["deviceName"] = device.name
        nowPlayingInfo["playerName"] = identity
        
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
        Logger.services.debug("MPRIS::PlayerRemote updated now playing info for \(self.identity, privacy: .public)")
    }
    
    func cleanup() {
        if isActive {
            nowPlayingInfoCenter.nowPlayingInfo = nil
        }
        isActive = false
        isPlaying = false
    }
}

// MARK: - DataPacket (MPRIS)

/// MPRIS service data packet utilities
fileprivate extension DataPacket {
    
    // MARK: Types
    
    enum MprisError: Error {
        case wrongType
        case invalidPlayer
        case invalidPlayerList
        case invalidArtUrl
        case invalidIsPlaying
        case invalidCanPause
        case invalidCanPlay
        case invalidCanGoNext
        case invalidCanGoPrevious
        case invalidCanSeek
        case invalidPosition
        case invalidLength
        case invalidArtist
        case invalidTitle
        case invalidAlbum
        case invalidVolume
        case invalidTransferringAlbumArt
        case partFileRenameFailed
    }
    
    enum MprisProperty: String {
        case playerList = "playerList"
        case player = "player"
        case isPlaying = "isPlaying"
        case canPause = "canPause"
        case canPlay = "canPlay"
        case canGoNext = "canGoNext"
        case canGoPrevious = "canGoPrevious"
        case canSeek = "canSeek"
        case pos = "pos"
        case length = "length"
        case artist = "artist"
        case title = "title"
        case album = "album"
        case albumArtUrl = "albumArtUrl"
        case volume = "volume"
        case supportAlbumArtPayload = "supportAlbumArtPayload"
        case transferringAlbumArt = "transferringAlbumArt"
        case action = "action"
        case requestPlayerList = "requestPlayerList"
        case requestNowPlaying = "requestNowPlaying"
        case requestVolume = "requestVolume"
        case setVolume = "setVolume"
        case Seek = "Seek"
        case SetPosition = "SetPosition"
    }
    
    // MARK: Properties
    
    static let mprisPacketType = "kdeconnect.mpris"
    static let mprisRequestPacketType = "kdeconnect.mpris.request"
    
    var isMprisPacket: Bool { return self.type == DataPacket.mprisPacketType }
    var isMprisRequestPacket: Bool { return self.type == DataPacket.mprisRequestPacketType }
    
    
    // MARK: Public static methods
    
    static func mprisRequestPlayerListPacket() -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            MprisProperty.requestPlayerList.rawValue: true as AnyObject
        ])
    }
    
    static func mprisRequestInfoPacket(player: String) -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            MprisProperty.player.rawValue: player as AnyObject,
            MprisProperty.requestNowPlaying.rawValue: true as AnyObject,
            MprisProperty.requestVolume.rawValue: true as AnyObject
        ])
    }
    
    static func mprisRequestAlbumArtPacket(player: String, albumArtUrl: String) -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            MprisProperty.player.rawValue: player as AnyObject,
            MprisProperty.albumArtUrl.rawValue: albumArtUrl as AnyObject
        ])
    }
    
    static func mprisRequestPacket(player: String, action: String) -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            MprisProperty.player.rawValue: player as AnyObject,
            MprisProperty.action.rawValue: action as AnyObject
        ])
    }
    
    static func mprisSetVolumePacket(player: String, volume: Int) -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            MprisProperty.player.rawValue: player as AnyObject,
            MprisProperty.setVolume.rawValue: volume as AnyObject
        ])
    }
    
    static func mprisSeekPacket(player: String, offset: Int) -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            MprisProperty.player.rawValue: player as AnyObject,
            MprisProperty.Seek.rawValue: offset as AnyObject
        ])
    }
    
    static func mprisSetPositionPacket(player: String, position: Int) -> DataPacket {
        return DataPacket(type: mprisRequestPacketType, body: [
            MprisProperty.player.rawValue: player as AnyObject,
            MprisProperty.SetPosition.rawValue: position as AnyObject
        ])
    }
    
    // MARK: Public methods
    
    func validateMprisType() throws {
        guard self.isMprisPacket || self.isMprisRequestPacket else { throw MprisError.wrongType }
    }
    
    func getPlayer() throws -> String? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.player.rawValue) else { return nil }
        guard let value = body[MprisProperty.player.rawValue] as? String else { throw MprisError.invalidPlayer }
        return value
    }
    
    func getPlayerList() throws -> [String]? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.playerList.rawValue) else { return nil }
        guard let value = body[MprisProperty.playerList.rawValue] as? [String] else { throw MprisError.invalidPlayerList }
        return value
    }
    
    func getAlbumArtUrl() throws -> String? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.albumArtUrl.rawValue) else { return nil }
        guard let value = body[MprisProperty.albumArtUrl.rawValue] as? String else { throw MprisError.invalidArtUrl }
        return value
    }
    
    func getIsPlaying() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.isPlaying.rawValue) else { return nil }
        guard let value = body[MprisProperty.isPlaying.rawValue] as? Bool else { throw MprisError.invalidIsPlaying }
        return value
    }
    
    func getCanPause() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.canPause.rawValue) else { return nil }
        guard let value = body[MprisProperty.canPause.rawValue] as? Bool else { throw MprisError.invalidCanPause }
        return value
    }
    
    func getCanPlay() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.canPlay.rawValue) else { return nil }
        guard let value = body[MprisProperty.canPlay.rawValue] as? Bool else { throw MprisError.invalidCanPlay }
        return value
    }
    
    func getCanGoNext() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.canGoNext.rawValue) else { return nil }
        guard let value = body[MprisProperty.canGoNext.rawValue] as? Bool else { throw MprisError.invalidCanGoNext }
        return value
    }
    
    func getCanGoPrevious() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.canGoPrevious.rawValue) else { return nil }
        guard let value = body[MprisProperty.canGoPrevious.rawValue] as? Bool else { throw MprisError.invalidCanGoPrevious }
        return value
    }
    
    func getCanSeek() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.canSeek.rawValue) else { return nil }
        guard let value = body[MprisProperty.canSeek.rawValue] as? Bool else { throw MprisError.invalidCanSeek }
        return value
    }
    
    func getPosition() throws -> Int? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.pos.rawValue) else { return nil }
        guard let value = body[MprisProperty.pos.rawValue] as? Int else { throw MprisError.invalidPosition }
        return value
    }
    
    func getLength() throws -> Int? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.length.rawValue) else { return nil }
        guard let value = body[MprisProperty.length.rawValue] as? Int else { throw MprisError.invalidLength }
        return value
    }
    
    func getArtist() throws -> String? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.artist.rawValue) else { return nil }
        guard let value = body[MprisProperty.artist.rawValue] as? String else { throw MprisError.invalidArtist }
        return value
    }
    
    func getTitle() throws -> String? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.title.rawValue) else { return nil }
        guard let value = body[MprisProperty.title.rawValue] as? String else { throw MprisError.invalidTitle }
        return value
    }
    
    func getAlbum() throws -> String? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.album.rawValue) else { return nil }
        guard let value = body[MprisProperty.album.rawValue] as? String else { throw MprisError.invalidAlbum }
        return value
    }
    
    func getVolume() throws -> Int? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.volume.rawValue) else { return nil }
        guard let value = body[MprisProperty.volume.rawValue] as? Int else { throw MprisError.invalidVolume }
        return value
    }
    
    func getTransferringAlbumArt() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.transferringAlbumArt.rawValue) else { return nil }
        guard let value = body[MprisProperty.transferringAlbumArt.rawValue] as? Bool else {
            throw MprisError.invalidTransferringAlbumArt
        }
        return value
    }
    
    func getSupportAlbumArtPayload() throws -> Bool? {
        try validateMprisType()
        guard body.keys.contains(MprisProperty.supportAlbumArtPayload.rawValue) else { return nil }
        guard let value = body[MprisProperty.supportAlbumArtPayload.rawValue] as? Bool else { return nil }
        return value
    }
    
}
