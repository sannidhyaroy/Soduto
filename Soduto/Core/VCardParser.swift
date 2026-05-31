//
//  VCardParser.swift
//  Soduto
//
//  Created by Sannidhya Roy on 03/05/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import AppKit

/// A parsed vCard record
public struct VCard: Equatable {
    
    public struct PhoneNumber: Equatable {
        /// The raw value from the TEL property (may include +, dashes, spaces, parentheses).
        public let raw: String
        /// Canonical lookup key: digits only, last 10 retained (or full digits if shorter).
        public let normalized: String
        /// TYPE parameters lower-cased: "cell", "home", "work", "voice", etc.
        public let types: [String]
    }
    
    public struct EmailAddress: Equatable {
        public let address: String
        public let types: [String]
    }
    
    public struct PostalAddress: Equatable {
        /// Raw ADR value, semicolon-delimited per RFC: po-box;ext;street;locality;region;postal;country
        public let raw: String
        public let types: [String]
        public var poBox: String { component(0) }
        public var extended: String { component(1) }
        public var street: String { component(2) }
        public var locality: String { component(3) }
        public var region: String { component(4) }
        public var postalCode: String { component(5) }
        public var country: String { component(6) }
        private func component(_ idx: Int) -> String {
            let parts = raw.components(separatedBy: ";")
            return idx < parts.count ? parts[idx] : ""
        }
    }
    
    public struct Organization: Equatable {
        /// Raw ORG value, semicolon-delimited: organization;unit1;unit2;…
        public let raw: String
        public var name: String { raw.components(separatedBy: ";").first ?? raw }
        public var units: [String] { Array(raw.components(separatedBy: ";").dropFirst()) }
    }
    
    // MARK: Core fields
    
    /// Display name from `FN`. May be empty if the vCard only had `N`.
    public let formattedName: String
    /// Structured name from `N` (family;given;middle;prefix;suffix). May be nil.
    public let structuredName: String?
    public let phoneNumbers: [PhoneNumber]
    /// Decoded photo bytes from `PHOTO;ENCODING=BASE64`. nil when absent.
    public let photoData: Data?
    /// `X-KDECONNECT-TIMESTAMP` value (epoch ms). nil when absent.
    public let timestamp: Int64?
    /// `X-KDECONNECT-ID-DEV-<deviceId>` value (the contact UID on the phone). nil when absent.
    public let kdeConnectUID: String?
    
    // MARK: Extended fields
    
    public let nickname: String?
    public let emails: [EmailAddress]
    public let organization: Organization?
    public let title: String?
    public let postalAddresses: [PostalAddress]
    /// `BDAY` raw value (typically `YYYY-MM-DD` or `YYYYMMDD`).
    public let birthday: String?
    public let note: String?
    public let urls: [String]
    public let categories: [String]
    /// IMPP (instant messaging) handles, e.g. `xmpp:user@server` or `aim:screenname`.
    public let imHandles: [String]
    
    /// Best display label: nickname → formattedName → structured name → nil.
    public var displayName: String? {
        if let nick = nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nick.isEmpty {
            return nick
        }
        let trimmed = formattedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let n = structuredName?.replacingOccurrences(of: ";", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            return n
        }
        return nil
    }
    
    /// Lazily-decoded photo as NSImage.
    public var photoImage: NSImage? {
        guard let data = photoData else { return nil }
        return NSImage(data: data)
    }
}

public enum VCardParser {
    
    /// Parse a single vCard string. Returns nil if no `BEGIN:VCARD` envelope is found.
    public static func parse(_ source: String) -> VCard? {
        let lines = unfold(source)
        guard lines.contains(where: { $0.uppercased().hasPrefix("BEGIN:VCARD") }) else { return nil }
        
        var fn = ""
        var n: String?
        var phones: [VCard.PhoneNumber] = []
        var photoData: Data?
        var timestamp: Int64?
        var uid: String?
        var nickname: String?
        var emails: [VCard.EmailAddress] = []
        var org: VCard.Organization?
        var title: String?
        var addresses: [VCard.PostalAddress] = []
        var birthday: String?
        var note: String?
        var urls: [String] = []
        var categories: [String] = []
        var imHandles: [String] = []
        
        for line in lines {
            guard let (rawName, params, value) = splitLine(line) else { continue }
            let upperName = rawName.uppercased()
            
            switch upperName {
            case "FN":
                fn = decodeValue(value, params: params)
            case "N":
                n = decodeValue(value, params: params)
            case "TEL":
                let decoded = decodeValue(value, params: params)
                if !decoded.isEmpty {
                    phones.append(makePhone(raw: decoded, params: params))
                }
            case "PHOTO":
                if isBase64(params: params) {
                    photoData = Data(base64Encoded: stripWhitespace(value))
                }
            case "NICKNAME":
                nickname = decodeValue(value, params: params)
            case "EMAIL":
                let decoded = decodeValue(value, params: params)
                if !decoded.isEmpty {
                    emails.append(VCard.EmailAddress(address: decoded, types: typeParams(params)))
                }
            case "ORG":
                let decoded = decodeValue(value, params: params)
                if !decoded.isEmpty {
                    org = VCard.Organization(raw: decoded)
                }
            case "TITLE":
                title = decodeValue(value, params: params)
            case "ADR":
                let decoded = decodeValue(value, params: params)
                if !decoded.isEmpty {
                    addresses.append(VCard.PostalAddress(raw: decoded, types: typeParams(params)))
                }
            case "BDAY":
                birthday = value.trimmingCharacters(in: .whitespacesAndNewlines)
            case "NOTE":
                note = decodeValue(value, params: params)
            case "URL":
                let decoded = decodeValue(value, params: params)
                if !decoded.isEmpty { urls.append(decoded) }
            case "CATEGORIES":
                let decoded = decodeValue(value, params: params)
                categories.append(contentsOf: decoded.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty })
            case "IMPP", "X-AIM", "X-MSN", "X-ICQ", "X-JABBER", "X-SKYPE", "X-GOOGLE-TALK":
                let decoded = decodeValue(value, params: params)
                if !decoded.isEmpty { imHandles.append(decoded) }
            default:
                if upperName == "X-KDECONNECT-TIMESTAMP" {
                    timestamp = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
                } else if upperName.hasPrefix("X-KDECONNECT-ID-DEV-") {
                    uid = value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        
        return VCard(
            formattedName: fn,
            structuredName: n,
            phoneNumbers: phones,
            photoData: photoData,
            timestamp: timestamp,
            kdeConnectUID: uid,
            nickname: nickname,
            emails: emails,
            organization: org,
            title: title,
            postalAddresses: addresses,
            birthday: birthday,
            note: note,
            urls: urls,
            categories: categories,
            imHandles: imHandles
        )
    }
    
    /// Normalize a phone number to a canonical lookup key:
    /// - Strip everything except digits.
    /// - Keep the last 10 digits if longer (drops leading country code for US-style matching).
    /// - Return the digit string as-is when shorter than 10 (short codes, international snippets).
    public static func normalize(phoneNumber: String) -> String {
        let digits = phoneNumber.unicodeScalars
            .filter { CharacterSet.decimalDigits.contains($0) }
            .map { Character($0) }
        if digits.count > 10 {
            return String(digits.suffix(10))
        }
        return String(digits)
    }
    
    // MARK: - Internals
    
    /// Unfold continuation lines (lines starting with space or tab continue the previous line).
    /// Handles both `\r\n` and `\n` endings.
    private static func unfold(_ source: String) -> [String] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        var result: [String] = []
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let first = line.first, first == " " || first == "\t" {
                if !result.isEmpty {
                    result[result.count - 1].append(String(line.dropFirst()))
                }
            } else {
                result.append(line)
            }
        }
        return result.filter { !$0.isEmpty }
    }
    
    /// Split a line into (name, params, value).
    /// `FN;CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:Bj=C3=B6rk` ->
    ///   ("FN", ["CHARSET":"UTF-8", "ENCODING":"QUOTED-PRINTABLE"], "Bj=C3=B6rk")
    private static func splitLine(_ line: String) -> (name: String, params: [String: String], value: String)? {
        guard let colonIdx = line.firstIndex(of: ":") else { return nil }
        let head = String(line[..<colonIdx])
        let value = String(line[line.index(after: colonIdx)...])
        
        let parts = head.split(separator: ";", omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        let name = String(first)
        
        var params: [String: String] = [:]
        for p in parts.dropFirst() {
            let kv = p.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            if kv.count == 2 {
                params[String(kv[0]).uppercased()] = String(kv[1])
            } else {
                // vCard 2.1 bare type token: TEL;CELL;VOICE:...
                // Stash under the token name itself so typeParams() can pick it up.
                params[String(p).uppercased()] = ""
            }
        }
        return (name, params, value)
    }
    
    private static func decodeValue(_ value: String, params: [String: String]) -> String {
        let encoding = params["ENCODING"]?.uppercased()
        let charset = params["CHARSET"]?.uppercased() ?? "UTF-8"
        if encoding == "QUOTED-PRINTABLE" {
            return decodeQuotedPrintable(value, charset: charset) ?? value
        }
        return value
    }
    
    private static func decodeQuotedPrintable(_ input: String, charset: String) -> String? {
        var bytes: [UInt8] = []
        let scalars = Array(input.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if s == "=" && i + 2 < scalars.count {
                let hi = scalars[i + 1]
                let lo = scalars[i + 2]
                if let h = hexDigit(hi), let l = hexDigit(lo) {
                    bytes.append(UInt8(h * 16 + l))
                    i += 3
                    continue
                }
            }
            if s.value < 0x80 {
                bytes.append(UInt8(s.value))
            } else {
                bytes.append(contentsOf: Array(String(s).utf8))
            }
            i += 1
        }
        let stringEncoding: String.Encoding = (charset == "UTF-8") ? .utf8 : .isoLatin1
        return String(data: Data(bytes), encoding: stringEncoding)
    }
    
    private static func hexDigit(_ s: Unicode.Scalar) -> Int? {
        switch s {
        case "0"..."9": return Int(s.value - Unicode.Scalar("0").value)
        case "A"..."F": return Int(s.value - Unicode.Scalar("A").value + 10)
        case "a"..."f": return Int(s.value - Unicode.Scalar("a").value + 10)
        default: return nil
        }
    }
    
    private static func isBase64(params: [String: String]) -> Bool {
        if let enc = params["ENCODING"]?.uppercased() {
            return enc == "BASE64" || enc == "B"
        }
        return false
    }
    
    private static func stripWhitespace(_ s: String) -> String {
        return s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .reduce(into: "") { $0.append(Character($1)) }
    }
    
    /// Extract TYPE values from params, supporting both `TYPE=CELL,VOICE` and bare-token forms.
    private static func typeParams(_ params: [String: String]) -> [String] {
        var types: [String] = []
        if let typeParam = params["TYPE"], !typeParam.isEmpty {
            for t in typeParam.split(separator: ",") {
                types.append(String(t).lowercased())
            }
        }
        for (key, val) in params where val.isEmpty && key != "TYPE" && key != "ENCODING" && key != "CHARSET" {
            types.append(key.lowercased())
        }
        return types
    }
    
    private static func makePhone(raw: String, params: [String: String]) -> VCard.PhoneNumber {
        return VCard.PhoneNumber(
            raw: raw,
            normalized: normalize(phoneNumber: raw),
            types: typeParams(params)
        )
    }
}
