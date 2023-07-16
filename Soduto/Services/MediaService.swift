//
//  MediaService.swift
//  Soduto
//
//  Created by Kanishk Dhindsa on 14/07/23.
//  Copyright © 2023 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import MediaPlayer
import SwiftyJSON

public class MediaService: Service {
    
    // MARK: Properties
    
    private static let monitoringInterval: TimeInterval = 0.5
    
    private var monitoringTimer: Timer? = nil
    private var lastMediaID: String = ""
    private var lastExternalChangeID: String = ""
    private var lastExternalChangeDevice: Device? = nil
    private var devices: [Device] = []
    
    // MARK: Service
    
    public static let serviceId: Service.Id = "com.soduto.services.MediaPlayer"
    
    public let incomingCapabilities: Set<Capability> = Set<Capability>([DataPacket.mediaRequestPacketType])
    public let outgoingCapabilities: Set<Capability> = Set<Capability>([DataPacket.mediaPacketType])
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        guard dataPacket.isMediaRequestPacket else { return false }
        
        do {
            if try dataPacket.wantPlayerList() {
                return sendPlayersList()
            }
            let player = try dataPacket.getPlayerName()
            if try dataPacket.wantNowPlaying() {
                return sendNowPlaying(playerName: player)
            }
        }
        catch {
            
        }
        
        return false
    }
    
    public func setup(for device: Device) {
        guard !self.devices.contains(where: { $0.id == device.id }) else { return }
        
        self.devices.append(device)
        
        if self.monitoringTimer == nil {
            self.startMonitoring()
        }
    }
    
    public func cleanup(for device: Device) {
        guard let index = self.devices.index(where: { $0.id == device.id }) else { return }
        
        self.devices.remove(at: index)
        
        if self.devices.count == 0 {
            self.stopMonitoring()
        }
    }
    
    public func actions(for device: Device) -> [ServiceAction] {
        return []
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device) {
        // No supported actions
    }
    
    // MARK: Private methods
    
    private func startMonitoring() {
        let interval = MediaService.monitoringInterval
        self.monitoringTimer = Timer.compatScheduledTimer(withTimeInterval: interval, repeats: true, block: { [weak self] _ in
            self?.checkMediaUpdate()
        })
    }
    
    private func stopMonitoring() {
        self.monitoringTimer?.invalidate()
        self.monitoringTimer = nil
    }
    
    private func checkMediaUpdate() {
        let nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
        
//        if let nowPlayingInfo = nowPlayingInfo {
            
//            guard nowPlayingInfo[MPNowPlayingInfoPropertyExternalContentIdentifier] as! String != self.lastMediaID else { return }
            
//            let title: String = ("todo: " + (nowPlayingInfo[MPNowPlayingInfoPropertyExternalContentIdentifier] as! String))
            
            let content : JSON = ["title": "title"]
            
            for device in self.devices {
                guard !(self.lastMediaID == self.lastExternalChangeID && self.lastExternalChangeDevice === device) else { continue }
//                device.send(DataPacket.mediaPacket(withRequest: content.stringValue))
            }
        
        
    }
    
    private func sendNowPlaying(playerName: String) -> Bool {
        for device in devices {
            device.send(DataPacket.mediaPacket(player: playerName, title: "testing", artist: "dunno", album: "test", isPlaying: true))
        }
        
        return true
    }
    
    private func sendPlayersList() -> Bool {
        for device in devices {
            device.send(DataPacket(type: DataPacket.mediaPacketType, body: [
                "playerList": ["test"] as AnyObject,
                "supportAlbumArtPayload": false as AnyObject
            ]))
        }
        return true
    }
}

// MARK: DataPacket (MediaPlayer)

fileprivate extension DataPacket {
    
    // MARK: Types
    
    enum MediaError: Error {
        case wrongType
        case invalidContent
    }
    
    enum ActionType {
        case Next
        case Previous
        case Play
        case Stop
        case Pause
        case PlayPause
        case Invalid
    }
    
    struct MediaProperty {
        static let player = "player"
        static let title = "title"
        static let artist = "artist"
        static let album = "album"
        static let isPlaying = "isPlaying"
    }
    
    struct MediaRequestProperty {
        static let requestPlayerList = "requestPlayerList"
        static let action = "action"
        static let requestNowPlaying = "rerquestNowPlaying"
        static let player = "player"
    }
    
    // MARK: Properties
    
    static let mediaPacketType = "kdeconnect.mpris"
    static let mediaRequestPacketType = "kdeconnect.mpris.request"
    
    var isMediaPacket: Bool { return self.type == DataPacket.mediaPacketType }
    var isMediaRequestPacket: Bool {
        return self.type == DataPacket.mediaRequestPacketType
    }
    
    // MARK: Public static methods
    static func mediaPacket(player: String, title: String, artist: String, album: String, isPlaying: Bool) -> DataPacket {
        return DataPacket(type: mediaRequestPacketType, body: [
            MediaProperty.player: player as AnyObject,
            MediaProperty.title: title as AnyObject,
            MediaProperty.artist: artist as AnyObject,
            MediaProperty.album: album as AnyObject,
            MediaProperty.isPlaying: isPlaying as AnyObject
        ])
    }
    
    // MARK: Public methods
    
    func wantPlayerList() throws -> Bool {
        guard body.keys.contains(MediaRequestProperty.requestPlayerList) else {return false}
        guard let value = body[MediaRequestProperty.requestPlayerList] as? NSNumber else { throw MediaError.wrongType }
        return value.boolValue
    }
    
    func isTypeAction() throws -> Bool {
        return body.keys.contains(MediaRequestProperty.action)
    }
    
    func getActionType() throws -> ActionType {
        guard try isTypeAction() else { return .Invalid }
        switch body[MediaRequestProperty.action] as? String {
        case "Next":
            return .Next
        case "Previous":
            return .Previous
        case "Pause":
            return .Pause
        case "Stop":
            return .Stop
        case "Play":
            return .Play
        case "PlayPause":
            return .PlayPause
        default:
            throw MediaError.wrongType
        }
    }
    
    func wantNowPlaying() throws -> Bool {
        guard body.keys.contains(MediaRequestProperty.requestNowPlaying) else { return false }
        guard let value = body[MediaRequestProperty.requestNowPlaying] as? NSNumber else {
            throw MediaError.wrongType
        }
        return value.boolValue
    }
    
    func getPlayerName() throws -> String {
        guard body.keys.contains(MediaRequestProperty.player) else { throw MediaError.wrongType }
        guard let value = body[MediaRequestProperty.player] as? String else {
            throw MediaError.wrongType
        }
        return value
    }
}
