//
//  MediaService.swift
//  Soduto
//
//  Created by Kanishk Dhindsa on 14/07/23.
//  Copyright © 2023 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import AppleScriptObjC
import MediaPlayer
import SwiftyJSON

/// Constants relevant to the MediaService class.
fileprivate struct Constants {
    static let player: String = "Mac"
    // basically the player actually playing the audio.
}

// MARK: Struct Decleration

// Various structs used to exchange requests through packets.
struct MediaInfo {
    let player: String
    let title: String
    let artist: String
    let album: String
    let albumArtUrl: String
    let url: String
    var isPlaying: Bool

    var m_dict: Dictionary<String, AnyObject> {
        [
            "player": player as AnyObject,
            "title": title as AnyObject,
            "artist": artist as AnyObject,
            "album": album as AnyObject,
            "albumArtUrl": albumArtUrl as AnyObject,
            "url": url as AnyObject,
            "isPlaying": isPlaying as AnyObject
        ]
    }
}

struct PlaybackInfo {
    let player: String = "Mac"
    let canPause: Bool = true
    let canPlay: Bool = true
    let canGoNext: Bool = false
    let canGoPrevious: Bool = false
    let canSeek: Bool = true
    var shuffle: Bool = false
    
    var m_dict: Dictionary<String, AnyObject> {
        [
            "player": player as AnyObject,
            "canPause": canPause as AnyObject,
            "canPlay": canPlay as AnyObject,
            "canGoNext": canGoNext as AnyObject,
            "canGoPrevious": canGoPrevious as AnyObject,
            "canSeek": canSeek as AnyObject,
            "shuffle": shuffle as AnyObject
        ]
    }
    
    init(shuffle: Bool) {
        self.shuffle = shuffle
    }
}

struct TimelineProperties {
    let player: String
    let canSeek: Bool = true
    let pos: Int64
    let length: Int64
    
    var m_dict: Dictionary<String, AnyObject> {
        [
            "player": player as AnyObject,
            "canSeek": canSeek as AnyObject,
            "pos": pos as AnyObject,
            "length": length as AnyObject
        ]
    }
}

/// Service providing the capability to control the media playing through Apple Music.
public class MediaService: Service {
    // MARK: Properties
    
    private static let timeDiffTolerance: Int64 = 5
    
    private var devices: [Device] = []
    private var iTunesBridge: iTunesBridge?
    
    // MARK: Info
    private var currentMediaInfo: MediaInfo = MediaInfo(player: Constants.player, title: "title", artist: "artist", album: "album", albumArtUrl: "", url: "", isPlaying: true)
    private var currentPlaybackInfo: PlaybackInfo = PlaybackInfo(shuffle: false)
    private var currentTimelineInfo: TimelineProperties = TimelineProperties(player: Constants.player,pos: 0, length: 10)
    
    @objc dynamic var pos: Int64 {
        get {
            if let iTunesBridge = iTunesBridge {
                if iTunesBridge.isRunning {
                    return Int64(truncating: iTunesBridge.pos)
                }
            }
            return 0
        }
        set (newPos) {
            if let iTunesBridge = iTunesBridge {
                
                print("seeking to \(newPos)")
                
                iTunesBridge.pos = (newPos as NSNumber)
                updateCurrentPlaying()
            }
        }
        
    }
    
    @objc dynamic var volume: Int {
        get {
            if let iTunesBridge = iTunesBridge {
                if iTunesBridge.isRunning {
                    return Int(truncating: iTunesBridge.pos)
                }
            }
            
            return 0
        }
        set (newVol) {
            if let iTunesBridge = iTunesBridge {                iTunesBridge.soundVolume = newVol as NSNumber
            }
        }
    }
    
    @objc dynamic var shuffle: Bool {
        get {
            if let iTunesBridge = iTunesBridge {
                if iTunesBridge.isRunning {
                    return iTunesBridge.shuffle.boolValue
                }
            }
            
            return false
        }
        
        set (turnOn) {
            if let iTunesBridge = iTunesBridge {
                iTunesBridge.shuffle = (turnOn as NSNumber)
                
                self.currentPlaybackInfo = PlaybackInfo(shuffle: turnOn)
                
                sendPacket(DataPacket(type: DataPacket.mediaPacketType, body: currentPlaybackInfo.m_dict))
            }
        }
    }
    
    
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
            
            if try dataPacket.wantNowPlaying() {
                sendThemPackets()
            }
            
            if try dataPacket.isTypeAction() {
                switch try dataPacket.getActionType() {
                case .PlayPause: playPause()
                case .Next: next()
                case .Previous: previous()
                case .Stop: do {
                    stop()
                }
                default: print("default action idk")
                }
            }
            
            if let seekTo = try dataPacket.seekTo() {
                seek(seekTo: seekTo)
            }
            
            if let newPos = try dataPacket.setPos() {
                let seekingTo = (newPos/1000) - pos
                seek(seekTo: seekingTo)
            }
            
            if try dataPacket.wantVolume() {
                sendVolume()
            }
            
            if let newVol = try dataPacket.setVolume() {
                print("setting vol to \(newVol)")
                volume = newVol
            }
            
            if let setShuffleTo = try dataPacket.setShuffle() {
                print("setting shuffle to \(setShuffleTo)")
                shuffle = setShuffleTo
            }
                
        }
        catch {
            
        }
        
        return false
    }
    
    // sends all the packets with all the information relevant to the media playing
    private func sendThemPackets() {
        sendPacket(DataPacket(type: DataPacket.mediaPacketType, body: currentMediaInfo.m_dict))
        sendPacket(DataPacket(type: DataPacket.mediaPacketType, body: currentPlaybackInfo.m_dict))
        sendPacket(DataPacket(type: DataPacket.mediaPacketType, body: currentTimelineInfo.m_dict))
    }
    
    public func setup(for device: Device) {
        Bundle.main.loadAppleScriptObjectiveCScripts()
        guard !self.devices.contains(where: { $0.id == device.id }) else { return }
        let iTunesBridgeClass: AnyClass = NSClassFromString("iTunesBridge")!
        self.iTunesBridge = (iTunesBridgeClass.alloc() as! iTunesBridge)

        self.devices.append(device)
        
        let distributedNotificationCenter = DistributedNotificationCenter.default()
        distributedNotificationCenter.addObserver(self, selector: #selector(updateCurrentPlaying), name: Notification.Name("com.apple.Music.playerInfo"), object: nil)
        
        updateCurrentPlaying()
    }
     
    @objc func updateCurrentPlaying() {
        
        var info: [String: AnyObject]?
        
        var playerState: PlayerState = .stopped
        var name: String = ""
        var album: String = ""
        var artist: String = ""
        var albumArtUrl: String = ""
        var url: String = ""
        
        info = iTunesBridge?.trackInfo as [String : AnyObject]?
                           
        if let info = info {
            name = info["trackName"] as? String ?? ""
            album = info["trackAlbum"] as? String ?? ""
            artist = info["trackArtist"] as? String ?? ""

            
            let totalTime: Double = ((iTunesBridge?.trackDuration as! Double)) * 1000
            print("track duration is \(totalTime)")
            var isPlaying: Bool = true
            
            playerState = iTunesBridge?.playerState as? PlayerState ?? .stopped
            
            switch playerState {
            case .paused: isPlaying = false
            case .stopped: isPlaying = false
            default: break
                // since now playing is already true we dont need to change a thing
            }
            
            print(info as Any)
            
            print("pos is \(pos)")
            
            self.currentMediaInfo = MediaInfo(player: Constants.player, title: name, artist: artist, album: album, albumArtUrl: albumArtUrl, url: url, isPlaying: isPlaying)
            self.currentTimelineInfo = TimelineProperties(player: Constants.player, pos: Int64(pos) * 1000, length: Int64(totalTime))
            
            sendThemPackets()
            sendVolume()
        }
    }
    
    public func cleanup(for device: Device) {
        guard let index = self.devices.index(where: { $0.id == device.id }) else { return }
        
        self.devices.remove(at: index)
    }
    
    public func actions(for device: Device) -> [ServiceAction] {
        return []
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device) {
        // No supported actions
    }
    
    private func sendPacket(_ packet: DataPacket) {
        guard packet.isMediaPacket == true else { return }
        
        for device in devices {
            device.send(packet)
        }
    }
    
    private func sendPlayersList() -> Bool {
        for device in devices {
            device.send(DataPacket(type: DataPacket.mediaPacketType, body: [
                "playerList": ["Mac"] as AnyObject,
                "supportAlbumArtPayload": false as AnyObject
            ]))
        }
        return true
    }
    
    private func sendVolume() {
        let body =  [
            "player": Constants.player,
            "volume": iTunesBridge?.soundVolume as AnyObject
        ] as Dictionary<String, AnyObject>
        let packet = DataPacket(type: DataPacket.mediaPacketType, body: body)
        
        sendPacket(packet)
    }
    
    // MARK: Actions
    
    private func playPause() {
        self.iTunesBridge?.playPause()
    }
    
    private func next() {
        self.iTunesBridge?.gotoNextTrack()
    }
    
    private func previous() {
        self.iTunesBridge?.gotoPreviousTrack()
    }
    
    private func stop() {
        self.iTunesBridge?.reallyStop()
        self.currentMediaInfo.isPlaying = false
        sendPacket(DataPacket(type: DataPacket.mediaPacketType, body: currentMediaInfo.m_dict))
        self.pos = 0
        self.currentTimelineInfo = TimelineProperties(player: Constants.player, pos: pos * 1000, length: self.currentTimelineInfo.length)
        sendPacket(DataPacket(type: DataPacket.mediaPacketType, body: currentTimelineInfo.m_dict))
    }
    
    private func seek(seekTo: Int64) {
        let value = self.pos + seekTo
        let aboveZero = max(value, 0)
        let newPos = min(aboveZero, (currentTimelineInfo.length - 1)/1000)
        
        if abs(newPos - self.pos) <= MediaService.timeDiffTolerance {
            if self.pos <= MediaService.timeDiffTolerance {
                self.previous()
            }
        }
        else {
            self.pos = newPos
        }
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
        static let requestNowPlaying = "requestNowPlaying"
        static let player = "player"
        static let requestVolume = "requestVolume"
        static let seek = "Seek"
        static let setPos = "SetPosition"
        static let setVolume = "setVolume"
        static let setShuffle = "setShuffle"
    }
    
    // MARK: Properties
    
    static let mediaPacketType = "kdeconnect.mpris"
    static let mediaRequestPacketType = "kdeconnect.mpris.request"
    
    var isMediaPacket: Bool { return self.type == DataPacket.mediaPacketType }
    var isMediaRequestPacket: Bool {
        return self.type == DataPacket.mediaRequestPacketType
    }
    
    // MARK: Public static methods
    static func mediaPacket(body: Body) -> DataPacket {
        return DataPacket(type: mediaPacketType, body: body)
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
    
    func isTypeSeek() throws -> Bool {
        return body.keys.contains(MediaRequestProperty.seek)
    }
    
    func isTypeSetPos() throws -> Bool {
        return body.keys.contains(MediaRequestProperty.setPos)
    }
    
    func isTypeSetVolume() throws -> Bool {
        return body.keys.contains(MediaRequestProperty.setVolume)
    }
    
    func isTypeSetShuffle() throws -> Bool {
        return body.keys.contains(MediaRequestProperty.setShuffle)
    }
    
    func seekTo() throws -> Int64? {
        if try isTypeSeek() {
            return body[MediaRequestProperty.seek] as? Int64
        }
        return nil
    }
    
    func setShuffle() throws -> Bool? {
        if try isTypeSetShuffle() {
            return body[MediaRequestProperty.setShuffle] as? Bool
        }
        return nil
    }
    
    func setPos() throws -> Int64? {
        if try isTypeSetPos() {
            return body[MediaRequestProperty.setPos] as? Int64
        }
        return nil
    }
    
    func setVolume() throws -> Int? {
        if try isTypeSetVolume() {
            return body[MediaRequestProperty.setVolume] as? Int
        }
        return nil
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
    
    func wantVolume() throws -> Bool {
        guard body.keys.contains(MediaRequestProperty.requestVolume) else { return false }
        guard let value = body[MediaRequestProperty.requestVolume] as? NSNumber else {
            throw MediaError.wrongType
        }
        return value.boolValue
    }
    
    mutating func addInfo(_ info: Dictionary<String, AnyObject>) {
        for (m_key, m_val) in info {
            self.body[m_key] = m_val
        }
    }
}
