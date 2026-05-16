//
//  RunCommandService.swift
//  Soduto
//
//  Created by Swapnil Devesh on 2025-04-19.
//  Copyright © 2025 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import os

/// Run commands on remote devices or let remote devices run commands on this device
public class RunCommandService: BidirectionalService {
    
    // MARK: Types
    
    enum ActionId: ServiceAction.Id {
        case runCommand = 1
    }
    
    public struct Command: Codable {
        let uuid: String
        var name: String
        var command: String
    }
    
    
    // MARK: Properties
    
    public static let serviceId: Service.Id = "com.soduto.services.runcommand"
    
    public var incomingCapabilities: Set<Service.Capability> {
        var caps = Set<Service.Capability>()
        if incomingEnabled { caps.insert(DataPacket.runCommandRequestPacketType) }
        if outgoingEnabled { caps.insert(DataPacket.runCommandPacketType) }
        return caps
    }
    public var outgoingCapabilities: Set<Service.Capability> {
        var caps = Set<Service.Capability>()
        if incomingEnabled { caps.insert(DataPacket.runCommandPacketType) }
        if outgoingEnabled { caps.insert(DataPacket.runCommandRequestPacketType) }
        return caps
    }
    
    var userDefaults: UserDefaults = .standard
    let incomingPreferenceKey = AppDefaultsStore.Preferences.Services.RunCommand.incomingKey
    let outgoingPreferenceKey = AppDefaultsStore.Preferences.Services.RunCommand.outgoingKey
    
    public var localCommands: [Command] {
        get {
            guard let data = userDefaults.data(forKey: AppDefaultsStore.Preferences.Services.RunCommand.commandsKey) else { return [] }
            return (try? JSONDecoder().decode([Command].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            userDefaults.set(data, forKey: AppDefaultsStore.Preferences.Services.RunCommand.commandsKey)
            guard incomingEnabled else { return }
            for device in devices where device.incomingCapabilities.contains(DataPacket.runCommandPacketType) {
                sendCommandList(to: device)
            }
        }
    }
    
    private var devices: [Device] = []
    private var remoteCommands: [Device.Id: [String: [String: String]]] = [:]
    
    
    // MARK: Service
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        do {
            switch dataPacket.type {
            case DataPacket.runCommandPacketType:
                guard outgoingEnabled else { return true }
                if let commandList = try dataPacket.getCommandList() {
                    self.remoteCommands[device.id] = commandList
                    Logger.services.debug("Received command list from \(device.name, privacy: .public)")
                }
            case DataPacket.runCommandRequestPacketType:
                if let key = try dataPacket.getRequestKey() {
                    guard incomingEnabled else { return true }
                    executeLocalCommand(key, device: device)
                } else if try dataPacket.isRequestingCommandList() {
                    guard incomingEnabled else { return true }
                    sendCommandList(to: device)
                }
            default:
                return false
            }
        } catch {
            Logger.services.error("Error handling run command packet: \(error, privacy: .public)")
        }
        return true
    }
    
    public func setup(for device: Device) {
        guard !self.devices.contains(where: { $0.id == device.id }) else { return }
        
        self.devices.append(device)
        
        if device.incomingCapabilities.contains(DataPacket.runCommandRequestPacketType) {
            send(DataPacket.runCommandListRequestPacket(), to: device)
        }
        
        if incomingEnabled, device.incomingCapabilities.contains(DataPacket.runCommandPacketType) {
            sendCommandList(to: device)
        }
    }
    
    public func cleanup(for device: Device) {
        if let index = self.devices.firstIndex(where: { $0.id == device.id }) {
            self.devices.remove(at: index)
        }
        self.remoteCommands.removeValue(forKey: device.id)
    }
    
    public func actions(for device: Device) -> [ServiceAction] {
        guard outgoingEnabled else { return [] }
        guard device.incomingCapabilities.contains(DataPacket.runCommandRequestPacketType) else { return [] }
        guard let deviceCommands = remoteCommands[device.id], !deviceCommands.isEmpty else { return [] }
        
        let commandActions: [ServiceAction] = deviceCommands.compactMap { uuid, commandInfo in
            guard let name = commandInfo["name"] else { return nil }
            return ServiceAction(
                id: ActionId.runCommand.rawValue,
                title: name,
                description: "Run command on remote device",
                service: self,
                device: device,
                userInfo: ["uuid": uuid]
            )
        }
        
        return [ServiceAction(
            id: ActionId.runCommand.rawValue,
            title: "Run Command",
            description: "Run a command on the remote device",
            service: self,
            device: device,
            children: commandActions
        )]
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device, userInfo: [String: Any]?) {
        guard let actionId = ActionId(rawValue: id) else { return }
        
        switch actionId {
        case .runCommand:
            guard let userInfo = userInfo, let uuid = userInfo["uuid"] as? String else { return }
            send(DataPacket.runCommandRequestPacket(key: uuid), to: device)
        }
    }
    
    
    // MARK: Private methods
    
    private func executeLocalCommand(_ key: String, device: Device) {
        guard let commandData = localCommands.first(where: { $0.uuid == key }) else {
            Logger.services.error("Command with key \(key, privacy: .public) not found")
            return
        }
        
        Logger.services.debug("Executing command: \(commandData.name, privacy: .public)")
        
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", commandData.command]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            Logger.services.error("Error executing command: \(error, privacy: .public)")
        }
    }
    
    private func sendCommandList(to device: Device) {
        device.send(DataPacket.runCommandListPacket(commandList: localCommandsToDict()))
    }
    
    private func localCommandsToDict() -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for command in localCommands {
            result[command.uuid] = ["name": command.name, "command": command.command]
        }
        return result
    }
}


// MARK: - DataPacket (Run Command)

fileprivate extension DataPacket {
    
    // MARK: Types
    
    enum RunCommandError: Error {
        case wrongType
        case invalidCommandList
        case invalidKey
        case invalidRequestFlag
    }
    
    struct RunCommandProperty {
        static let key = "key"
        static let commandList = "commandList"
        static let requestCommandList = "requestCommandList"
    }
    
    
    // MARK: Properties
    
    static let runCommandPacketType = "kdeconnect.runcommand"
    static let runCommandRequestPacketType = "kdeconnect.runcommand.request"
    
    var isRunCommandPacket: Bool { return self.type == DataPacket.runCommandPacketType }
    var isRunCommandRequestPacket: Bool { return self.type == DataPacket.runCommandRequestPacketType }
    
    
    // MARK: Public static methods
    
    static func runCommandRequestPacket(key: String) -> DataPacket {
        return DataPacket(type: runCommandRequestPacketType, body: [RunCommandProperty.key: key as AnyObject])
    }
    
    static func runCommandListRequestPacket() -> DataPacket {
        return DataPacket(type: runCommandRequestPacketType, body: [RunCommandProperty.requestCommandList: true as AnyObject])
    }
    
    static func runCommandListPacket(commandList: [String: [String: String]]) -> DataPacket {
        let commandListString = try? JSONSerialization.data(withJSONObject: commandList)
        let commandListJSON = commandListString.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return DataPacket(type: runCommandPacketType, body: [RunCommandProperty.commandList: commandListJSON as AnyObject])
    }
    
    
    // MARK: Public methods
    
    func getCommandList() throws -> [String: [String: String]]? {
        try self.validateRunCommandType()
        guard body.keys.contains(RunCommandProperty.commandList) else { return nil }
        guard let commandListString = body[RunCommandProperty.commandList] as? String else { throw RunCommandError.invalidCommandList }
        guard let data = commandListString.data(using: .utf8) else { throw RunCommandError.invalidCommandList }
        return try JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
    }
    
    func getRequestKey() throws -> String? {
        try self.validateRunCommandRequestType()
        guard body.keys.contains(RunCommandProperty.key) else { return nil }
        guard let value = body[RunCommandProperty.key] as? String else { throw RunCommandError.invalidKey }
        return value
    }
    
    func isRequestingCommandList() throws -> Bool {
        try self.validateRunCommandRequestType()
        guard body.keys.contains(RunCommandProperty.requestCommandList) else { return false }
        guard let value = body[RunCommandProperty.requestCommandList] as? NSNumber else { throw RunCommandError.invalidRequestFlag }
        return value.boolValue
    }
    
    func validateRunCommandType() throws {
        guard self.isRunCommandPacket else { throw RunCommandError.wrongType }
    }
    
    func validateRunCommandRequestType() throws {
        guard self.isRunCommandRequestPacket else { throw RunCommandError.wrongType }
    }
}
