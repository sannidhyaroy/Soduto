//
//  RunCommandService.swift
//  Soduto
//
//  Created on 2025-04-19.
//  Copyright © 2025 Soduto. All rights reserved.
//

import Foundation
import Cocoa
import CleanroomLogger

/// RunCommand service data packet utilities
fileprivate extension DataPacket {
    
    static let runCommandPacketType = "kdeconnect.runcommand"
    static let runCommandRequestPacketType = "kdeconnect.runcommand.request"
    
    var isRunCommandPacket: Bool { return self.type == DataPacket.runCommandPacketType }
    var isRunCommandRequestPacket: Bool { return self.type == DataPacket.runCommandRequestPacketType }
    
    static func runCommandRequestPacket(key: String) -> DataPacket {
        return DataPacket(type: runCommandRequestPacketType, body: ["key": key as AnyObject])
    }
    
    static func runCommandListRequestPacket() -> DataPacket {
        return DataPacket(type: runCommandRequestPacketType, body: ["requestCommandList": true as AnyObject])
    }
    
    static func runCommandListPacket(commandList: [String: [String: String]]) -> DataPacket {
        let commandListString = try? JSONSerialization.data(withJSONObject: commandList)
        let commandListJSON = commandListString != nil ? String(data: commandListString!, encoding: .utf8) : "{}"
        return DataPacket(type: runCommandPacketType, body: ["commandList": commandListJSON as AnyObject])
    }
    
    func getCommandList() throws -> [String: [String: String]]? {
        guard self.isRunCommandPacket else { throw RunCommandService.RunCommandError.wrongType }
        
        guard let commandListString = self.body["commandList"] as? String else { return nil }
        guard let data = commandListString.data(using: .utf8) else { return nil }
        guard let commandList = try JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else { return nil }
        
        return commandList
    }
    
    func getRequestKey() throws -> String? {
        guard self.isRunCommandRequestPacket else { throw RunCommandService.RunCommandError.wrongType }
        
        return self.body["key"] as? String
    }
    
    func isRequestingCommandList() throws -> Bool {
        guard self.isRunCommandRequestPacket else { throw RunCommandService.RunCommandError.wrongType }
        
        return self.body["requestCommandList"] as? Bool == true
    }
}

/// Run commands on remote devices or let remote devices run commands on this device
public class RunCommandService: Service {
    
    // MARK: Types
    
    enum RunCommandError: Error {
        case wrongType
        case invalidCommand
    }
    
    enum ActionId: ServiceAction.Id {
        case runCommand = 1
    }
    
    public struct Command: Codable {
        var uuid: String
        var name: String
        var command: String
    }
    
    // MARK: Properties
    
    public static let serviceId: Service.Id = "com.soduto.services.runcommand"
    
    public let incomingCapabilities = Set<Service.Capability>([ DataPacket.runCommandPacketType, DataPacket.runCommandRequestPacketType ])
    public let outgoingCapabilities = Set<Service.Capability>([ DataPacket.runCommandPacketType, DataPacket.runCommandRequestPacketType ])
    
    private var devices: [Device] = []
    private var remoteCommands: [Device.Id: [String: [String: String]]] = [:]
    
    // MARK: Service methods
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        guard dataPacket.isRunCommandPacket || dataPacket.isRunCommandRequestPacket else { return false }
        
        do {
            if dataPacket.isRunCommandPacket {
                // Handle received command list
                if let commandList = try dataPacket.getCommandList() {
                    self.remoteCommands[device.id] = commandList
                    Log.debug?.message("Received command list from \(device.name)")
                }
            } 
            else if dataPacket.isRunCommandRequestPacket {
                // Handle command execution request
                if let key = try dataPacket.getRequestKey() {
                    executeLocalCommand(key, device: device)
                }
                // Handle command list request
                else if try dataPacket.isRequestingCommandList() {
                    sendCommandList(to: device)
                }
            }
        }
        catch {
            Log.error?.message("Error handling run command packet: \(error)")
        }
        
        return true
    }
    
    public func setup(for device: Device) {
        guard !self.devices.contains(where: { $0.id == device.id }) else { return }
        
        self.devices.append(device)
        
        // Request the command list from the device
        if device.incomingCapabilities.contains(DataPacket.runCommandRequestPacketType) {
            device.send(DataPacket.runCommandListRequestPacket())
        }
        
        // Send our command list to the device if it supports receiving it
        if device.incomingCapabilities.contains(DataPacket.runCommandPacketType) {
            sendCommandList(to: device)
        }
    }
    
    public func cleanup(for device: Device) {
        // Remove device from array
        if let index = self.devices.firstIndex(where: { $0.id == device.id }) {
            self.devices.remove(at: index)
        }
        
        // Remove stored remote commands for this device
        self.remoteCommands.removeValue(forKey: device.id)
    }
    
    public func actions(for device: Device) -> [ServiceAction] {
        var actions: [ServiceAction] = []
        
        guard device.incomingCapabilities.contains(DataPacket.runCommandRequestPacketType) else { return actions }

        actions.append(ServiceAction(
            id: ActionId.runCommand.rawValue,
            title: "Run Command",
            description: "Run a command on the remote device",
            service: self,
            device: device
        ))
        
        return actions
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device) {
        // No supported actions
    }
    
    public func createRunCommandMenu(for device: Device) -> NSMenu {
        let menu = NSMenu(title: "Run Commands")
        
        var hasCommands = false
        if let deviceCommands = self.remoteCommands[device.id] {
            if !deviceCommands.isEmpty {
                hasCommands = true
                for (uuid, commandInfo) in deviceCommands {
                    guard let name = commandInfo["name"] else { continue }

                    let item = NSMenuItem(title: name, action: #selector(runCommandMenuItemClicked(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = (uuid: uuid, device: device)
                    menu.addItem(item)
                }
            }
        } 

        if !hasCommands {
            let item = NSMenuItem(title: "No commands configured", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        
        return menu
    }
    
    // MARK: Private methods
    
    @objc private func runCommandMenuItemClicked(_ sender: NSMenuItem) {
        guard let (uuid, device) = sender.representedObject as? (uuid: String, device: Device) else { return }
        
        device.send(DataPacket.runCommandRequestPacket(key: uuid))
    }
    
    private func executeLocalCommand(_ key: String, device: Device) {
        guard let commands = getLocalCommands() else { return }
        
        if let commandData = commands.first(where: { $0.uuid == key }) {
            Log.debug?.message("Executing command: \(commandData.name)")
            
            let task = Process()
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", commandData.command]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                Log.error?.message("Error executing command: \(error)")
            }
        } else {
            Log.error?.message("Command with key \(key) not found")
        }
    }
    
    private func sendCommandList(to device: Device) {
        let commandList = localCommandsToDict()
        device.send(DataPacket.runCommandListPacket(commandList: commandList))
    }
    
    private func localCommandsToDict() -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        
        if let commands = getLocalCommands() {
            for command in commands {
                result[command.uuid] = [
                    "name": command.name,
                    "command": command.command
                ]
            }
        }
        
        return result
    }
}

// MARK: - RunCommandsWindowControllerDelegate

extension RunCommandService: RunCommandsWindowControllerDelegate {
    func getLocalCommands() -> [RunCommandService.Command]? {
        return AppDelegate.shared().config.runCommands
    }
    
    func saveLocalCommands(_ commands: [RunCommandService.Command]) {
        AppDelegate.shared().config.runCommands = commands
        
        // Update command list on all connected devices
        for device in self.devices {
            if device.incomingCapabilities.contains(DataPacket.runCommandPacketType) {
                sendCommandList(to: device)
            }
        }
    }
}
