//
//  ContactsService.swift
//  Soduto
//
//  Created by Sannidhya Roy on 03/05/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import AppKit
import Contacts
import Combine
import os

/// Service that mirrors phone contacts to the Mac as vCards.
///
/// On device setup, requests all contact UIDs + last-modified timestamps from the phone,
/// diffs against the local cache, and lazily fetches changed/new vCards in batches.
/// Stores parsed vCards in memory and the raw `.vcf` files on disk so reconnects only
/// pull what changed.
///
/// Public `lookupContact(phoneNumber:deviceId:)` resolves a phone number to a contact,
/// preferring the phone's vCard cache and falling back to macOS `CNContactStore` so that
/// contacts saved only on the Mac (iPhone-primary users) still produce caller ID.
public class ContactsService: IncomingService, ObservableObject {
    
    // MARK: Types
    
    public struct ResolvedContact: Equatable {
        public enum Source: Equatable {
            case phone(deviceId: Device.Id, uid: String?)
            case mac
        }
        public let displayName: String
        public let photo: NSImage?
        public let source: Source
    }
    
    // MARK: Service
    
    public static let serviceId: Service.Id = "com.soduto.services.contacts"
    
    public var incomingCapabilities: Set<Service.Capability> {
        incomingEnabled ? [
            DataPacket.contactsResponseUidsTimestampsPacketType,
            DataPacket.contactsResponseVcardsPacketType
        ] : []
    }
    
    public var outgoingCapabilities: Set<Service.Capability> {
        // We send the request packets; advertising them as outgoing capabilities lets the peer know we'll initiate sync
        // The request packets are gated on `incomingEnabled` via the `request(_:from:)` helper since the purpose is to receive a response
        incomingEnabled ? [
            DataPacket.contactsRequestAllUidsTimestampsPacketType,
            DataPacket.contactsRequestVcardsByUidPacketType
        ] : []
    }
    
    // MARK: IncomingService
    
    var userDefaults: UserDefaults = .standard
    let incomingPreferenceKey = AppDefaultsStore.Preferences.Services.Contacts.incomingKey
    
    // MARK: Published State
    
    /// Per-device vCard cache keyed by UID (source of truth for diff sync).
    @Published public private(set) var vcardsByUID: [Device.Id: [String: VCard]] = [:]
    
    // MARK: Internal State
    
    /// Per-device index keyed by normalized phone number → UID, for O(1) lookup.
    /// Derived from vcardsByUID; rebuilt incrementally as vCards are added/replaced.
    private var phoneIndex: [Device.Id: [String: String]] = [:]
    
    /// Pre-resolved Mac contacts: normalized phone → ResolvedContact (display name + photo already extracted).
    /// Built on a background queue so the per-lookup path makes ZERO `CNContactStore` calls on the main thread.
    /// Those calls block and trip Apple's "should not be called on the main thread" warning under load.
    /// Refreshed on `CNContactStoreDidChange`.
    private var macContactsByPhone: [String: ResolvedContact] = [:]
    private var macIndexLoaded = false
    private let cnStore = CNContactStore()
    private var macStoreObserver: NSObjectProtocol?
    
    /// Memoized resolution results (cleared whenever indices change).
    private let resolveCache = NSCache<NSString, ResolvedContactBox>()
    
    /// Devices currently set up for sync.
    private var devices: [Device.Id: Device] = [:]
    
    /// Size of each `request_vcards_by_uid` batch (KDE Desktop uses similar batching).
    private static let vcardBatchSize = 50
    
    // MARK: Lifecycle
    
    public init() {
        // Re-build Mac index whenever the user edits their Mac contacts
        macStoreObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidateMacIndex()
        }
    }
    
    deinit {
        if let obs = macStoreObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }
    
    // MARK: Service Protocol
    
    public func handleDataPacket(_ dataPacket: DataPacket, fromDevice device: Device, onConnection connection: Connection) -> Bool {
        switch dataPacket.type {
        case DataPacket.contactsResponseUidsTimestampsPacketType:
            guard incomingEnabled else { return true }
            handleUidsTimestamps(dataPacket, from: device)
            return true
        case DataPacket.contactsResponseVcardsPacketType:
            guard incomingEnabled else { return true }
            handleVcardsResponse(dataPacket, from: device)
            return true
        default:
            return false
        }
    }
    
    public func setup(for device: Device) {
        guard devices[device.id] == nil else { return }
        devices[device.id] = device
        
        loadCacheFromDisk(deviceId: device.id)
        Logger.services.debug("ContactsService requesting UID list from \(device.id, privacy: .public)")
        request(DataPacket.contactsRequestAllUidsTimestampsPacket(), from: device)
    }
    
    public func cleanup(for device: Device) {
        devices.removeValue(forKey: device.id)
        // Keep the on-disk + in-memory cache around so it's immediately available on reconnect
    }
    
    public func actions(for device: Device) -> [ServiceAction] {
        return []
    }
    
    public func performAction(_ id: ServiceAction.Id, forDevice device: Device, userInfo: [String: Any]?) {
        // No supported actions
    }
    
    // MARK: Public Lookup API
    
    /// Resolve a phone number to a contact.
    /// Looks in the phone's vCard cache first (Android wins all conflicts), falls back to macOS Contacts for iPhone-primary users who keep contacts on Mac but not the Android phone.
    ///
    /// Safe to call from the main thread / SwiftUI render context.
    /// The first call for a given number may trigger a synchronous `CNContactStore` query; subsequent calls hit the in-memory `resolveCache`.
    public func lookupContact(phoneNumber: String, deviceId: Device.Id) -> ResolvedContact? {
        let normalized = VCardParser.normalize(phoneNumber: phoneNumber)
        guard !normalized.isEmpty else { return nil }
        let key = "\(deviceId)|\(normalized)" as NSString
        if let cached = resolveCache.object(forKey: key) {
            return cached.value
        }
        
        // Phone (Android) Contact, authoritative when present
        if let uid = phoneIndex[deviceId]?[normalized],
           let vcard = vcardsByUID[deviceId]?[uid] {
            let resolved = ResolvedContact(
                displayName: vcard.displayName ?? phoneNumber,
                photo: vcard.photoImage,
                source: .phone(deviceId: deviceId, uid: uid)
            )
            resolveCache.setObject(ResolvedContactBox(resolved), forKey: key)
            return resolved
        }
        
        // Mac Contact as fallback
        ensureMacIndexLoaded()
        if let resolved = macContactsByPhone[normalized] {
            resolveCache.setObject(ResolvedContactBox(resolved), forKey: key)
            return resolved
        }
        
        return nil
    }
    
    /// All known phone contacts for a device, used by the new-conversation picker.
    /// Phone source only; Mac fallbacks are added by the picker UI on top of this.
    public func allPhoneContacts(deviceId: Device.Id) -> [VCard] {
        guard let map = vcardsByUID[deviceId] else { return [] }
        return Array(map.values)
    }
    
    /// Snapshot of the Mac contacts index keyed by normalized phone.
    /// Used by the new-conversation picker to merge Mac contacts into autocomplete results.
    /// Returns an empty dict until the background load has finished.
    /// Call `lookupContact(...)` once first to trigger the lazy load if you need data from a cold start.
    public func macContactsSnapshot() -> [String: ResolvedContact] {
        return macContactsByPhone
    }
    
    // MARK: Diff Sync (UIDs + Timestamps)
    
    private func handleUidsTimestamps(_ packet: DataPacket, from device: Device) {
        guard let uids = packet.body["uids"] as? [String] else {
            Logger.services.error("Contacts response_uids_timestamps missing uids array from \(device.id, privacy: .public)")
            return
        }
        
        var staleOrMissing: [String] = []
        let current = vcardsByUID[device.id] ?? [:]
        for uid in uids {
            // Timestamps may arrive as NSNumber or String depending on the sender's JSON shape
            let remoteTs: Int64? = (packet.body[uid] as? NSNumber)?.int64Value
            ?? (packet.body[uid] as? String).flatMap(Int64.init)
            let localTs = current[uid]?.timestamp
            if localTs == nil || (remoteTs != nil && remoteTs! != localTs) {
                staleOrMissing.append(uid)
            }
        }
        
        // Drop locally-cached vCards that the phone no longer reports
        let remoteSet = Set(uids)
        let toRemove = current.keys.filter { !remoteSet.contains($0) }
        if !toRemove.isEmpty {
            removeFromCache(uids: Array(toRemove), deviceId: device.id)
        }
        
        Logger.services.info("Contacts sync for \(device.id, privacy: .public): \(uids.count) remote, \(staleOrMissing.count, privacy: .public) to fetch, \(toRemove.count, privacy: .public) to drop")
        
        // Fan out vCard requests in batches
        for batch in staleOrMissing.chunked(into: Self.vcardBatchSize) {
            request(DataPacket.contactsRequestVcardsByUidPacket(uids: batch), from: device)
        }
    }
    
    // MARK: Receive vCards
    
    private func handleVcardsResponse(_ packet: DataPacket, from device: Device) {
        guard let uids = packet.body["uids"] as? [String] else {
            Logger.services.error("Contacts response_vcards missing uids array from \(device.id, privacy: .public)")
            return
        }
        
        var parsed: [(uid: String, vcard: VCard, raw: String)] = []
        for uid in uids {
            guard let raw = packet.body[uid] as? String else { continue }
            guard let vcard = VCardParser.parse(raw) else {
                Logger.services.notice("Failed to parse vCard for uid \(uid, privacy: .public) from \(device.id, privacy: .public)")
                continue
            }
            parsed.append((uid, vcard, raw))
        }
        
        // Persist to disk on a background queue, then publish on main
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            for entry in parsed {
                self.writeVcardToDisk(uid: entry.uid, raw: entry.raw, deviceId: device.id)
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            var map = self.vcardsByUID[device.id] ?? [:]
            var idx = self.phoneIndex[device.id] ?? [:]
            for entry in parsed {
                // Replacing a UID drops its old phone-index entries; re-derive them
                if let old = map[entry.uid] {
                    for p in old.phoneNumbers where idx[p.normalized] == entry.uid {
                        idx.removeValue(forKey: p.normalized)
                    }
                }
                map[entry.uid] = entry.vcard
                for p in entry.vcard.phoneNumbers where !p.normalized.isEmpty {
                    idx[p.normalized] = entry.uid
                }
            }
            self.vcardsByUID[device.id] = map
            self.phoneIndex[device.id] = idx
            self.resolveCache.removeAllObjects()
            Logger.services.debug("Contacts cached \(parsed.count, privacy: .public) vCards for \(device.id, privacy: .public)")
        }
    }
    
    // MARK: Disk Cache
    
    private static let cacheRootName = "Contacts"
    
    private func cacheDirectory(for deviceId: Device.Id) -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let bundleId = Bundle.main.bundleIdentifier ?? "com.soduto.Soduto"
        let safeDeviceId = sanitizeDeviceIdComponent(deviceId)
        let url = appSupport
            .appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent(Self.cacheRootName, isDirectory: true)
            .appendingPathComponent(safeDeviceId, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    
    private func loadCacheFromDisk(deviceId: Device.Id) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self,
                  let dir = self.cacheDirectory(for: deviceId) else { return }
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            var map: [String: VCard] = [:]
            var idx: [String: String] = [:]
            for url in files where url.pathExtension == "vcf" {
                guard let raw = try? String(contentsOf: url, encoding: .utf8),
                      let vcard = VCardParser.parse(raw),
                      let uid = vcard.kdeConnectUID else { continue }
                map[uid] = vcard
                for p in vcard.phoneNumbers where !p.normalized.isEmpty {
                    idx[p.normalized] = uid
                }
            }
            DispatchQueue.main.async {
                if self.vcardsByUID[deviceId] == nil {
                    self.vcardsByUID[deviceId] = map
                    self.phoneIndex[deviceId] = idx
                    Logger.services.debug("Loaded \(map.count, privacy: .public) cached vCards for \(deviceId, privacy: .public)")
                }
            }
        }
    }
    
    private func writeVcardToDisk(uid: String, raw: String, deviceId: Device.Id) {
        guard let dir = cacheDirectory(for: deviceId) else { return }
        let url = dir.appendingPathComponent("\(sanitizeUIDComponent(uid)).vcf")
        // Belt-and-suspenders: the SHA256 output is always 64 hex chars (no `..`/`/`), but verify path containment anyway in case sanitization is ever changed
        guard url.resolvingSymlinksInPath().path.hasPrefix(dir.resolvingSymlinksInPath().path) else {
            Logger.services.error("Refusing to write vCard outside cache dir for uid \(uid, privacy: .public)")
            return
        }
        do {
            try raw.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Logger.services.error("Failed to write vCard for \(uid, privacy: .public): \(error, privacy: .public)")
        }
    }
    
    private func removeFromCache(uids: [String], deviceId: Device.Id) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self, let dir = self.cacheDirectory(for: deviceId) else { return }
            for uid in uids {
                let url = dir.appendingPathComponent("\(self.sanitizeUIDComponent(uid)).vcf")
                try? FileManager.default.removeItem(at: url)
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            var map = self.vcardsByUID[deviceId] ?? [:]
            var idx = self.phoneIndex[deviceId] ?? [:]
            for uid in uids {
                if let removed = map.removeValue(forKey: uid) {
                    for p in removed.phoneNumbers where idx[p.normalized] == uid {
                        idx.removeValue(forKey: p.normalized)
                    }
                }
            }
            self.vcardsByUID[deviceId] = map
            self.phoneIndex[deviceId] = idx
            self.resolveCache.removeAllObjects()
        }
    }
    
    /// Device IDs are short alphanumeric hex (32 chars from KDE Connect's identity packet).
    /// Percent-encoding keeps the cache directory inspectable per device.
    private func sanitizeDeviceIdComponent(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "invalid"
    }
    
    /// Contact UIDs come from Android's `ContactsContract.LOOKUP_KEY`.
    /// Merged contacts (one person across Google + SIM + Samsung account, etc.) get concatenated keys that can exceed several hundred chars, past macOS's 255-byte `NAME_MAX` limit; hash the UID for the filename.
    /// The original UID is recoverable from the `X-KDECONNECT-ID-DEV-*` field inside the vCard on cache load.
    private func sanitizeUIDComponent(_ s: String) -> String {
        return StableHashing.sha256(s)
    }
    
    // MARK: Mac Contacts Fallback
    
    private func ensureMacIndexLoaded() {
        guard !macIndexLoaded else { return }
        macIndexLoaded = true  // claim immediately so concurrent lookups don't all kick off a load
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.loadMacIndex()
        }
    }
    
    private func invalidateMacIndex() {
        macIndexLoaded = false
        macContactsByPhone.removeAll()
        resolveCache.removeAllObjects()
    }
    
    /// Off-main: enumerate every Mac contact, format the display name and decode the photo, and stash the pre-resolved values in `macContactsByPhone` keyed by normalized phone.
    /// Once the dict is populated, `lookupContact` is a pure read with no `CN*` calls; this eliminates the main-thread warning even under render load.
    private func loadMacIndex() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
        // `descriptorForRequiredKeys` returns every key `CNContactFormatter` touches for the chosen style
        // Required to avoid `CNPropertyNotFetchedException` at format time
        let formatterDescriptor = CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        let keys: [CNKeyDescriptor] = [
            formatterDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactImageDataKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        let formatter = CNContactFormatter()
        formatter.style = .fullName
        var index: [String: ResolvedContact] = [:]
        do {
            try cnStore.enumerateContacts(with: request) { contact, _ in
                let formatted = formatter.string(from: contact)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let displayName: String
                if !formatted.isEmpty {
                    displayName = formatted
                } else {
                    let org = contact.organizationName
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !org.isEmpty else { return }
                    displayName = org
                }
                let image = contact.imageData.flatMap { NSImage(data: $0) }
                let resolved = ResolvedContact(displayName: displayName, photo: image, source: .mac)
                for labeled in contact.phoneNumbers {
                    let normalized = VCardParser.normalize(phoneNumber: labeled.value.stringValue)
                    guard !normalized.isEmpty else { continue }
                    // First contact wins on ambiguity, phone numbers are rarely shared
                    if index[normalized] == nil { index[normalized] = resolved }
                }
            }
        } catch {
            Logger.services.notice("Mac contacts index load failed: \(error, privacy: .public)")
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.macContactsByPhone = index
            self.resolveCache.removeAllObjects()  // make existing rows re-resolve with Mac data
            Logger.services.debug("Mac contacts index loaded: \(index.count, privacy: .public) phone numbers")
        }
    }
}

// MARK: - NSCache Boxing

/// NSCache requires AnyObject; wrap the struct value.
private final class ResolvedContactBox {
    let value: ContactsService.ResolvedContact
    init(_ v: ContactsService.ResolvedContact) { self.value = v }
}

// MARK: - Array Chunking

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var result: [[Element]] = []
        var i = 0
        while i < count {
            let end = Swift.min(i + size, count)
            result.append(Array(self[i..<end]))
            i = end
        }
        return result
    }
}

// MARK: - DataPacket (Contacts)

fileprivate extension DataPacket {
    
    // MARK: Types
    
    enum ContactsError: Error {
        case wrongType
        case malformedBody
    }
    
    enum ContactsProperty: String {
        case uids = "uids"
    }
    
    // MARK: Properties
    
    // Android's `ContactsPlugin.kt` is the source of truth: request uses `request_all_uids_timestamps`, response uses `response_uids_timestamps` (no `_all_`)
    // The protocol.md JSON example shows `response_all_uids_timestamps`, which is a docs typo (verified against kdeconnect-android)
    static let contactsRequestAllUidsTimestampsPacketType = "kdeconnect.contacts.request_all_uids_timestamps"
    static let contactsRequestVcardsByUidPacketType = "kdeconnect.contacts.request_vcards_by_uid"
    static let contactsResponseUidsTimestampsPacketType = "kdeconnect.contacts.response_uids_timestamps"
    static let contactsResponseVcardsPacketType = "kdeconnect.contacts.response_vcards"
    
    var isContactsResponseUidsTimestampsPacket: Bool {
        type == DataPacket.contactsResponseUidsTimestampsPacketType
    }
    var isContactsResponseVcardsPacket: Bool {
        type == DataPacket.contactsResponseVcardsPacketType
    }
    
    // MARK: Public static methods
    
    static func contactsRequestAllUidsTimestampsPacket() -> DataPacket {
        return DataPacket(type: contactsRequestAllUidsTimestampsPacketType, body: [:])
    }
    
    static func contactsRequestVcardsByUidPacket(uids: [String]) -> DataPacket {
        return DataPacket(type: contactsRequestVcardsByUidPacketType, body: [
            ContactsProperty.uids.rawValue: uids as AnyObject
        ])
    }
}
