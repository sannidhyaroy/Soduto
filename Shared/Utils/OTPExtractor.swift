//
//  OTPExtractor.swift
//  Soduto
//
//  Created by Sannidhya Roy on 05/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Cocoa
import os

/// Extracts OTP/verification codes from notification text and copies them to clipboard.
///
/// Detection strategy:
/// 1. **Package gate**: Uses the Android package ID (extracted from the notification ID)
///    to restrict scanning to known SMS/messaging apps — unforgeable unlike `appName`.
/// 2. **Keyword gate**: Requires an anchor word (OTP, code, PIN, etc.) to be present — avoids
///    false positives on arbitrary messages.
/// 3. **Regex extraction**: Finds standalone 4–8 digit sequences using `\b` word boundaries,
///    which naturally rejects digits embedded in hex hashes or alphanumeric tokens.
/// 4. **False positive filter**: Skips candidates preceded by currency symbols/words,
///    masking characters (even across spaces), date separators, or that appear too far
///    from a keyword anchor (with newlines penalized to prevent cross-paragraph matches).
///
/// Currently limited to a hardcoded allowlist of SMS/messaging apps. This will be
/// user-configurable once the preferences window is modernized.
enum OTPExtractor {
    
    // MARK: - Package Allowlist
    
    /// Android package IDs whose notification body text is scanned for OTP codes.
    ///
    /// Extracted from the notification `id` field which has the format:
    ///   `<number>|<package_name>|<id>|<tag>|<uid>`
    /// The package name is system-assigned and cannot be spoofed (unlike `appName`).
    static let allowedPackages: Set<String> = [
        "com.google.android.apps.messaging",    // Google Messages
        "com.samsung.android.messaging",        // Samsung Messages
        "com.truecaller",                       // Truecaller
        "xyz.klinker.messenger",                // Pulse SMS
        "com.textra",                           // Textra SMS
        "org.fossify.messages",                 // Fossify Messages
        "com.jio.messageslite",                 // JioMessages
        "com.google.android.gm",                // Gmail (Android)
        "net.thunderbird.android",              // Thunderbird (Android)
        "com.fsck.k9",                          // K-9 Mail
        "ch.protonmail.android",                // Proton Mail
        "com.microsoft.office.outlook",         // Microsoft Outlook
        "com.easilydo.mail",                    // Email (Edison Software)
        "eu.faircode.email",                    // FairEmail
        "com.samsung.android.email.provider",   // Samsung Email (Android)
        "com.pingapp.app",                      // Spike
        "com.yahoo.mobile.client.android.mail", // Yahoo Mail
        "ru.mail.mailapp",                      // Mail.ru
        "com.zoho.mail",                        // Zoho Mail
    ]
    
    // MARK: - Keyword Anchors
    
    /// Case-insensitive keywords that must appear in the text for OTP extraction to proceed.
    /// Acts as a cheap short-circuit before running regex.
    private static let keywords: [String] = [
        "otp", "code", "pin", "verification", "verify", "passcode",
        "one-time", "one time", "password"
    ]
    
    // MARK: - Regex Patterns
    
    /// Matches standalone 4–8 digit sequences. Uses `\b` word boundaries — digits adjacent
    /// to letters (hex hashes like `ad0177e`, tracking IDs) are naturally excluded, and
    /// substrings of longer digit runs (phone numbers, account numbers) won't match either.
    private static let digitCodePattern = try! NSRegularExpression(
        pattern: #"\b(\d{4,8})\b"#,
        options: []
    )
    
    /// Currency indicators that commonly precede monetary amounts (not OTPs).
    /// If a candidate digit sequence is preceded by one of these, it's likely an amount.
    private static let currencyPrefixPattern = try! NSRegularExpression(
        pattern: #"(?:Rs\.?|₹|\$|INR|USD|EUR|GBP)\s*$"#,
        options: [.caseInsensitive]
    )
    
    /// URL pattern — if the digit sequence appears inside a URL, skip it.
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"https?://\S+"#,
        options: [.caseInsensitive]
    )
    
    /// Month name appearing immediately before the candidate (with optional whitespace/comma).
    /// Catches written-out dates like "July 2026", "Jan, 2026", "December 2026".
    private static let monthBeforePattern = try! NSRegularExpression(
        pattern: #"(?:January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[.,\s]*$"#,
        options: [.caseInsensitive]
    )
    
    /// Month name appearing immediately after the candidate (with optional whitespace/comma).
    /// Catches reversed dates like "2026 July", "2026, December".
    private static let monthAfterPattern = try! NSRegularExpression(
        pattern: #"^[,\s]*(?:January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\b"#,
        options: [.caseInsensitive]
    )
    
    // MARK: - Proximity Thresholds
    
    /// Maximum character distance between a keyword anchor and a digit candidate for
    /// the candidate to be considered an OTP. Prevents matching stray numbers in long
    /// emails where a keyword appears paragraphs away from unrelated numbers.
    private static let maxKeywordDistance = 60
    
    /// Year-like candidates (2000–2099) are inherently suspicious — they need the keyword
    /// to be very close to override the suspicion that it's a calendar year.
    private static let maxYearKeywordDistance = 15
    
    /// Each newline between a keyword and candidate adds this many "virtual characters"
    /// to the effective proximity distance. Prevents false matches across structural/tabular
    /// boundaries in emails where a keyword (e.g. "Currency Code") appears many lines above
    /// an unrelated number (e.g. "5000" as an amount in a gift card table).
    private static let newlinePenalty = 25
    
    // MARK: - Public API
    
    /// Extracts an OTP/verification code from notification text.
    ///
    /// Detection pipeline (applied to every 4–8 digit candidate):
    /// 1. Keyword gate (cheap short-circuit)
    /// 2. URL stripping
    /// 3. `\b` word boundary regex (rejects digits glued to letters)
    /// 4. Per-candidate filters: currency prefix, `#` prefix, masking lookback,
    ///    date separators, month-name adjacency, newline-weighted keyword proximity, year range
    /// 5. Best-candidate selection by keyword proximity (closest wins)
    ///
    /// - Parameter text: The notification body text to scan.
    /// - Returns: The extracted code string, or `nil` if no OTP was detected.
    static func extractOTP(from text: String) -> String? {
        let lowercased = text.lowercased()
        
        // Step 1: Keyword gate — bail early if no anchor keyword is present
        guard keywords.contains(where: { lowercased.contains($0) }) else {
            return nil
        }
        
        // Step 2: Strip URLs to avoid matching port numbers, tracking IDs, etc.
        let cleaned = urlPattern.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
        let cleanedLower = cleaned.lowercased()
        let nsText = cleaned as NSString
        let nsTextLower = cleanedLower as NSString
        
        // Step 3: Find all 4–8 digit candidates
        let fullRange = NSRange(cleaned.startIndex..., in: cleaned)
        let matches = digitCodePattern.matches(in: cleaned, options: [], range: fullRange)
        
        // Step 4: Evaluate candidates — pick the one closest to a keyword anchor
        var bestCandidate: String? = nil
        var bestDistance = Int.max
        
        for match in matches {
            guard let candidateRange = Range(match.range(at: 1), in: cleaned) else { continue }
            let candidate = String(cleaned[candidateRange])
            let nsRange = match.range(at: 1)
            let prefixEnd = nsRange.location
            
            // Filter A: Skip if preceded by a currency indicator (Rs, ₹, $, INR, etc.)
            if prefixEnd > 0 {
                let prefixRange = NSRange(location: 0, length: prefixEnd)
                let prefixText = nsText.substring(with: prefixRange)
                if currencyPrefixPattern.firstMatch(
                    in: prefixText, options: [],
                    range: NSRange(location: 0, length: prefixText.utf16.count)
                ) != nil {
                    continue
                }
            }
            
            // Filter B: Skip if preceded by '#' (order/reference numbers like #123456)
            if prefixEnd > 0 {
                let charBefore = nsText.substring(with: NSRange(location: prefixEnd - 1, length: 1))
                if charBefore == "#" { continue }
            }
            
            // Filter C: Skip if preceded by masking characters, even with intervening spaces.
            // Catches: "XXXXXX1862" (already excluded by \b), "XXXX XXXX 2112", "**** 1234"
            if isMasked(in: nsText, candidateStart: prefixEnd) { continue }
            
            // Filter D: Skip if the candidate sits inside a date pattern (adjacent / or - with digits)
            if isDateAdjacent(in: nsText, candidateNSRange: nsRange) { continue }
            
            // Filter D2: Skip if adjacent to a month name ("July 2026", "Jan 2026", "2026 December")
            if isAdjacentToMonthName(in: nsText, candidateNSRange: nsRange) { continue }
            
            // Compute keyword proximity (newline-weighted) — needed by remaining filters and scoring
            let distance = distanceToNearestKeyword(
                in: nsTextLower,
                candidateLocation: nsRange.location,
                candidateEnd: nsRange.location + nsRange.length
            )
            
            // Filter E: Keyword proximity gate — candidate must be near a keyword
            guard distance <= maxKeywordDistance else { continue }
            
            // Filter F: 4-digit year-like numbers (2000–2099) require the keyword very close
            if candidate.count == 4, let num = Int(candidate), (2000...2099).contains(num) {
                guard distance <= maxYearKeywordDistance else { continue }
            }
            
            // Best candidate = closest to a keyword anchor
            if distance < bestDistance {
                bestDistance = distance
                bestCandidate = candidate
            }
        }
        
        return bestCandidate
    }
    
    // MARK: - Context Helpers
    
    /// Checks if the candidate digit sequence sits inside a date-like pattern —
    /// i.e. a `/` or `-` with adjacent digits appears immediately before or after it.
    ///
    /// Catches patterns like `03/03/2026`, `2026-03-05`, `28/02/26`, etc.
    private static func isDateAdjacent(in nsText: NSString, candidateNSRange nsRange: NSRange) -> Bool {
        let textLength = nsText.length
        let start = nsRange.location
        let end = start + nsRange.length
        
        // Check after: candidate followed by / or - then another digit
        if end + 1 < textLength {
            let charAfter = nsText.substring(with: NSRange(location: end, length: 1))
            if charAfter == "/" || charAfter == "-" {
                let nextChar = nsText.substring(with: NSRange(location: end + 1, length: 1))
                if nextChar.rangeOfCharacter(from: .decimalDigits) != nil {
                    return true
                }
            }
        }
        
        // Check before: / or - preceded by a digit, then this candidate
        if start >= 2 {
            let charBefore = nsText.substring(with: NSRange(location: start - 1, length: 1))
            if charBefore == "/" || charBefore == "-" {
                let charBeforeSep = nsText.substring(with: NSRange(location: start - 2, length: 1))
                if charBeforeSep.rangeOfCharacter(from: .decimalDigits) != nil {
                    return true
                }
            }
        }
        
        return false
    }
    
    /// Checks if masking characters (X, x, *) appear shortly before the candidate,
    /// possibly separated by whitespace. Handles patterns like "XXXX XXXX 2112"
    /// where the digits are a suffix of a masked number, not an OTP.
    ///
    /// Looks back up to 8 characters before the candidate, skipping spaces.
    /// Note: The direct-adjacency case ("XXXXXX1862") is already handled by `\b` word
    /// boundaries — `X` and `1` are both `\w`, so no boundary exists between them.
    private static func isMasked(in nsText: NSString, candidateStart: Int) -> Bool {
        var pos = candidateStart - 1
        let lookbackLimit = max(0, candidateStart - 8)
        while pos >= lookbackLimit {
            let ch = nsText.substring(with: NSRange(location: pos, length: 1))
            if ch == " " {
                pos -= 1
                continue
            }
            // First non-space character: is it a masking char?
            return ch == "X" || ch == "x" || ch == "*"
        }
        return false
    }
    
    /// Checks if a month name appears immediately before or after the candidate digit sequence.
    ///
    /// Catches written-out dates like "29th July 2026", "Jan 2026", "2026 December", "Dec, 2026".
    /// Uses a small window around the candidate to avoid matching month names that are far away.
    private static func isAdjacentToMonthName(in nsText: NSString, candidateNSRange nsRange: NSRange) -> Bool {
        let start = nsRange.location
        let end = start + nsRange.length
        
        // Check before: up to 15 characters before the candidate for a trailing month name
        if start > 0 {
            let lookback = min(start, 15)
            let prefixRange = NSRange(location: start - lookback, length: lookback)
            let prefixText = nsText.substring(with: prefixRange)
            if monthBeforePattern.firstMatch(
                in: prefixText, options: [],
                range: NSRange(location: 0, length: prefixText.utf16.count)
            ) != nil {
                return true
            }
        }
        
        // Check after: up to 15 characters after the candidate for a leading month name
        if end < nsText.length {
            let lookahead = min(nsText.length - end, 15)
            let suffixRange = NSRange(location: end, length: lookahead)
            let suffixText = nsText.substring(with: suffixRange)
            if monthAfterPattern.firstMatch(
                in: suffixText, options: [],
                range: NSRange(location: 0, length: suffixText.utf16.count)
            ) != nil {
                return true
            }
        }
        
        return false
    }
    
    /// Finds the shortest **weighted** distance from the candidate to any keyword occurrence.
    /// Returns `Int.max` if no keyword is found in the text.
    ///
    /// Measures edge-to-edge character gap, with each `\n` in the gap adding `newlinePenalty`
    /// virtual characters. This prevents false matches across structural boundaries in email
    /// notifications (e.g. tabular data, forwarded messages) where a keyword like "Currency Code"
    /// appears many lines above an unrelated number.
    ///
    /// Uses `NSString` coordinates (UTF-16) consistently with the regex match positions.
    private static func distanceToNearestKeyword(
        in nsTextLower: NSString,
        candidateLocation: Int,
        candidateEnd: Int
    ) -> Int {
        var minDistance = Int.max
        
        for keyword in keywords {
            var searchStart = 0
            while searchStart < nsTextLower.length {
                let searchRange = NSRange(location: searchStart, length: nsTextLower.length - searchStart)
                let kwRange = nsTextLower.range(of: keyword, options: [], range: searchRange)
                guard kwRange.location != NSNotFound else { break }
                
                let kwEnd = kwRange.location + kwRange.length
                
                // Determine the gap between keyword and candidate
                let gapStart: Int
                let gapEnd: Int
                if candidateLocation >= kwEnd {
                    gapStart = kwEnd
                    gapEnd = candidateLocation
                } else if kwRange.location >= candidateEnd {
                    gapStart = candidateEnd
                    gapEnd = kwRange.location
                } else {
                    return 0  // overlapping
                }
                
                let rawGap = gapEnd - gapStart
                
                // Count newlines in the gap and apply penalty
                let gapText = nsTextLower.substring(with: NSRange(location: gapStart, length: rawGap))
                let newlineCount = gapText.filter { $0 == "\n" }.count
                let weightedGap = rawGap + newlineCount * newlinePenalty
                
                minDistance = min(minDistance, weightedGap)
                if minDistance == 0 { return 0 }
                searchStart = kwEnd
            }
        }
        
        return minDistance
    }
    
    // MARK: - Package Extraction
    
    /// Extracts the Android package name from a KDE Connect notification ID.
    ///
    /// The notification ID format from Android's NotificationListenerService is:
    ///   `<number>|<package_name>|<id>|<tag>|<uid>`
    /// e.g. `0|com.google.android.apps.messaging|2|...|10279`
    ///
    /// - Parameter notificationId: The raw notification ID string from the packet.
    /// - Returns: The package name, or `nil` if the format is unexpected.
    static func extractPackageId(from notificationId: String) -> String? {
        let components = notificationId.split(separator: "|", omittingEmptySubsequences: false)
        guard components.count >= 2 else { return nil }
        let packageId = String(components[1])
        // Sanity check: package IDs contain at least one dot
        guard packageId.contains(".") else { return nil }
        return packageId
    }
    
    /// Checks if the notification is from an allowed SMS app and contains an OTP.
    /// Returns the extracted code (or `nil`), and optionally copies it to the clipboard
    /// and shows a HUD toast when `autoCopy` is `true`.
    ///
    /// The `@discardableResult` allows call sites that only need the return value (e.g. to
    /// populate a "Copy OTP" action button) to ignore it, and call sites that only want the
    /// side-effects to ignore the return value — all without changing the call signature.
    ///
    /// Uses the Android package ID (from the notification ID) for app identification —
    /// this is system-assigned and cannot be spoofed, unlike the user-facing `appName`.
    ///
    /// - Parameters:
    ///   - body: The notification body text (may be nil).
    ///   - title: The notification title (used for logging the sender).
    ///   - appName: The user-facing app name (used for logging context).
    ///   - packetNotificationId: The raw Android notification ID (e.g. `0|com.google.android.apps.messaging|2|...|10279`).
    ///   - autoCopy: When `true` (default), copies the OTP to the clipboard and shows the HUD toast.
    ///               Pass `false` during sync to detect the OTP for the action button without side-effects.
    @MainActor
    @discardableResult
    static func handleIfOTP(body: String?, title: String?, appName: String, packetNotificationId: String, autoCopy: Bool = true) -> String? {
        guard let packageId = extractPackageId(from: packetNotificationId),
              allowedPackages.contains(packageId),
              let body = body,
              let otp = extractOTP(from: body) else { return nil }
        
        if autoCopy {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(otp, forType: .string)
            
            let sender = title.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown sender"
            #if DEBUG
                Logger.services.info("OTP auto-copied: \(otp, privacy: .public) — app: \(appName, privacy: .public) [\(packageId, privacy: .public)], sender: \(sender, privacy: .public), body: \(body, privacy: .public)")
            #else
                Logger.services.info("OTP auto-copied: \(otp.prefix(2), privacy: .public)**** — app: \(appName, privacy: .public) [\(packageId, privacy: .public)], sender: \(sender, privacy: .public)")
            #endif
            
            HUDToast.show("OTP Copied")
        }
        
        return otp
    }
}
