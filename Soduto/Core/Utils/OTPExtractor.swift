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
///    to restrict scanning to known SMS/messaging apps, unforgeable unlike `appName`.
/// 2. **Keyword gate**: Requires a word-boundary anchor word (OTP, code, PIN, etc.) to be
///    present, avoids false positives on arbitrary messages.
/// 3. **Regex extraction**: Finds standalone 4–8 digit sequences using `\b` word boundaries,
///    which naturally rejects digits embedded in hex hashes or alphanumeric tokens.
/// 4. **False positive filter**: Skips candidates preceded by currency symbols/words,
///    masking characters (even across spaces), date/decimal separators, currency or time
///    unit suffixes, fragments of spaced digit groups (phone numbers, card numbers),
///    or that appear too far from a keyword anchor (with newlines and sentence boundaries
///    penalized to prevent cross-paragraph and cross-sentence matches).
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
        "ch.protonmail.android",                // Proton Mail (Android)
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
    
    /// Word-boundary anchored keywords that must appear in the text for OTP extraction to proceed.
    /// `\b` anchoring prevents matches inside unrelated words ("pin" in "shopping", "code" in "codebase").
    /// `verif\w+` / `authenticat\w+` cover the inflected forms (verify, verified, verification, authentication, authenticator).
    private static let keywordPattern = try! NSRegularExpression(
        pattern: #"\b(?:otps?|codes?|pins?|pass(?:code|word)s?|verif\w+|authenticat\w+|one[\s-]?time|two[\s-]?factor|2fa)\b"#,
        options: [.caseInsensitive]
    )
    
    // MARK: - Regex Patterns
    
    /// Matches standalone 4–8 digit sequences, plus dash-grouped 6-digit codes ("482-913", WhatsApp style, with the dash stripped before returning).
    /// Uses `\b` word boundaries, so digits adjacent to letters (hex hashes like `ad0177e`, tracking IDs) are naturally excluded, and substrings of longer digit runs (phone numbers, account numbers) won't match either.
    private static let digitCodePattern = try! NSRegularExpression(
        pattern: #"\b(\d{4,8}|\d{3}-\d{3})\b"#,
        options: []
    )
    
    /// Currency indicators that commonly precede monetary amounts (not OTPs).
    /// If a candidate digit sequence is preceded by one of these, it's likely an amount.
    /// Ordered by rough global popularity: symbols, then ISO codes, then local abbreviations.
    /// The `\b` before the word-like alternatives prevents words ending in "rs" ("hours", "yours") or embedded code fragments from being mistaken for currency markers.
    private static let currencyPrefixPattern = try! NSRegularExpression(
        pattern: #"(?:[$€£¥₹]|\b(?:USD|EUR|JPY|GBP|CNY|INR|AUD|CAD|Rs\.?))\s*$"#,
        options: [.caseInsensitive]
    )
    
    /// Currency indicators appearing immediately after the candidate ("5000 INR", "1234€").
    /// Anchored at the start of the suffix window following the candidate.
    /// Same popularity ordering as `currencyPrefixPattern`.
    private static let currencySuffixPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:[$€£¥₹]|(?:USD|EUR|JPY|GBP|CNY|INR|AUD|CAD|dollars?|euros?|yen|yuan|pounds?|rupees?)\b|Rs\.?(?:\s|$))"#,
        options: [.caseInsensitive]
    )
    
    /// Time-of-day / duration units appearing immediately after the candidate ("1130 am", "1300 hrs").
    /// Anchored at the start of the suffix window.
    private static let timeSuffixPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:a\.?m\.?|p\.?m\.?|hrs?|hours?)\b"#,
        options: [.caseInsensitive]
    )
    
    /// Destination marker immediately before the candidate ("text STORE to 88039", "send GO to: 69988", "up to 5000").
    /// A number that something is sent *to*, or a quantity bounded by "up to", is a shortcode, recipient, or limit, not a code to copy.
    private static let destinationPrefixPattern = try! NSRegularExpression(
        pattern: #"\bto:?\s+$"#,
        options: [.caseInsensitive]
    )
    
    /// Verbal masked-number references immediately before the candidate, e.g. "card ending 1234", "A/c ending in 4829", "number ends with 7548".
    /// The digits are the visible suffix of a longer masked number, not a code.
    private static let maskedReferencePattern = try! NSRegularExpression(
        pattern: #"\b(?:ending(?:\s+(?:in|with))?|ends\s+with)\s*$"#,
        options: [.caseInsensitive]
    )
    
    /// Labeled reference numbers immediately before the candidate, e.g. "Bug 22056", "BugTraq ID: 5347", "Ticket 48293", "Invoice no. 4829".
    /// A number introduced by one of these labels is an identifier, not a code to enter anywhere.
    private static let labeledReferencePattern = try! NSRegularExpression(
        pattern: #"\b(?:id|bug|ticket|issue|case|ref(?:erence)?|order|invoice|track(?:ing)?)\s*(?:no\.?|num(?:ber)?)?\s*[:.]?\s*$"#,
        options: [.caseInsensitive]
    )
    
    /// Date-context words immediately before a year-like candidate, e.g. "in 1999", "since 1998", "dated 1637", "copyright 2026".
    /// Applied only to candidates in `yearRange`, where such a preposition marks the number as a calendar year regardless of keyword proximity.
    private static let dateContextPrefixPattern = try! NSRegularExpression(
        pattern: #"\b(?:in|since|before|after|from|until|till|by|circa|dated|est\.?|copyright|©)\s+$"#,
        options: [.caseInsensitive]
    )
    
    /// URL pattern: if the digit sequence appears inside a URL, skip it.
    /// Also matches scheme-less links common in calendar/meeting invites ("meet.google.com/xyz", "zoom.us/j/1234567"), any dotted domain followed by a path.
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"https?://\S+|\bwww\.\S+|\b(?:[a-z0-9-]+\.)+[a-z]{2,}/\S+"#,
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
    
    /// Maximum character distance between a keyword anchor and a digit candidate for the candidate to be considered an OTP.
    /// Prevents matching stray numbers in long emails where a keyword appears paragraphs away from unrelated numbers.
    private static let maxKeywordDistance = 60
    
    /// Year-like candidates are inherently suspicious, so they need the keyword to be very close to override the suspicion that it's a calendar year.
    private static let maxYearKeywordDistance = 15
    
    /// 4-digit values treated as year-like for the keyword-proximity gate (e.g. "valid through 2027", "Doubleday, 1999").
    /// Kept narrow so ordinary 4-digit codes like "1234" aren't burdened with the stricter proximity requirement.
    private static let yearRange = 1900...2099
    
    /// 4-digit values accepted as a year when explicitly introduced by a date-context word (e.g. "dated 1637", "circa 1500", "in 1999").
    /// Wider than `yearRange` because the preceding word already asserts this is a date.
    private static let dateContextYearRange = 1000...2099
    
    /// Each newline between a keyword and candidate adds this many "virtual characters" to the effective proximity distance.
    /// Prevents false matches across structural/tabular boundaries in emails where a keyword (e.g. "Currency Code") appears many lines above an unrelated number (e.g. "5000" as an amount in a gift card table).
    private static let newlinePenalty = 25
    
    /// Each sentence boundary (`.`, `!`, or `?` followed by whitespace) between a keyword and candidate adds this many "virtual characters".
    /// A keyword should anchor numbers in its own sentence far more readily than numbers a sentence or two away.
    private static let sentencePenalty = 15
    
    // MARK: - Public API
    
    /// Extracts an OTP/verification code from notification text.
    ///
    /// Detection pipeline (applied to every 4–8 digit candidate):
    /// 1. URL stripping (including scheme-less meeting/tracking links)
    /// 2. Keyword gate: word-boundary anchored, ranges computed once for proximity scoring
    /// 3. `\b` word boundary regex (rejects digits glued to letters)
    /// 4. Per-candidate filters: currency prefix/suffix, time suffix, `#` prefix, masking lookback, date/decimal separators, month-name adjacency, digit-group fragments (phone/card numbers), newline-weighted keyword proximity, year range
    /// 5. Best-candidate selection by keyword proximity (closest wins)
    ///
    /// - Parameter text: The notification body text to scan.
    /// - Returns: The extracted code string, or `nil` if no OTP was detected.
    static func extractOTP(from text: String) -> String? {
        // Step 1: Strip URLs to avoid matching port numbers, tracking IDs, meeting links, etc
        let cleaned = urlPattern.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
        let nsText = cleaned as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        
        // Step 2: Keyword gate, bail early if no anchor keyword is present
        // The match ranges double as the anchors for proximity scoring below
        let keywordRanges = keywordPattern.matches(in: cleaned, options: [], range: fullRange).map { $0.range }
        guard !keywordRanges.isEmpty else {
            return nil
        }
        
        // Step 3: Find all 4–8 digit candidates
        let matches = digitCodePattern.matches(in: cleaned, options: [], range: fullRange)
        
        // Step 4: Evaluate candidates, pick the one closest to a keyword anchor
        var bestCandidate: String? = nil
        var bestDistance = Int.max
        
        for match in matches {
            guard let candidateRange = Range(match.range(at: 1), in: cleaned) else { continue }
            let candidate = String(cleaned[candidateRange])
            let nsRange = match.range(at: 1)
            let prefixEnd = nsRange.location
            
            // Filter A: Skip if preceded by a currency indicator ($, ₹, INR, Rs, etc.), a destination marker ("text STORE to 88039"), or a verbal masked-number reference ("card ending 1234")
            if prefixEnd > 0 {
                let prefixRange = NSRange(location: 0, length: prefixEnd)
                let prefixText = nsText.substring(with: prefixRange)
                let prefixFullRange = NSRange(location: 0, length: prefixText.utf16.count)
                if currencyPrefixPattern.firstMatch(in: prefixText, options: [], range: prefixFullRange) != nil {
                    continue
                }
                if destinationPrefixPattern.firstMatch(in: prefixText, options: [], range: prefixFullRange) != nil {
                    continue
                }
                if maskedReferencePattern.firstMatch(in: prefixText, options: [], range: prefixFullRange) != nil {
                    continue
                }
                if labeledReferencePattern.firstMatch(in: prefixText, options: [], range: prefixFullRange) != nil {
                    continue
                }
                // Year-like candidates preceded by a date-context word ("in 1999",
                // "dated 1637") are calendar years regardless of keyword proximity
                if candidate.count == 4, let num = Int(candidate), dateContextYearRange.contains(num),
                   dateContextPrefixPattern.firstMatch(in: prefixText, options: [], range: prefixFullRange) != nil {
                    continue
                }
            }
            
            // Filter A2: Skip if followed by a currency indicator ("5000 INR", "1234€") or a time/duration unit ("1130 am", "1300 hrs")
            if hasNonOTPSuffix(in: nsText, candidateEnd: nsRange.location + nsRange.length) { continue }
            
            // Filter B: Skip if preceded by '#' (order/reference numbers like #123456)
            if prefixEnd > 0 {
                let charBefore = nsText.substring(with: NSRange(location: prefixEnd - 1, length: 1))
                if charBefore == "#" { continue }
            }
            
            // Filter C: Skip if preceded by masking characters, even with intervening spaces
            // Catches: "XXXXXX1862" (already excluded by \b), "XXXX XXXX 2112", "**** 1234"
            if isMasked(in: nsText, candidateStart: prefixEnd) { continue }
            
            // Filter D: Skip if the candidate sits inside a date, decimal, or time pattern (adjacent /, -, ., or : with digits on the other side)
            if isDateAdjacent(in: nsText, candidateNSRange: nsRange) { continue }
            
            // Filter D2: Skip if adjacent to a month name ("July 2026", "Jan 2026", "2026 December")
            if isAdjacentToMonthName(in: nsText, candidateNSRange: nsRange) { continue }
            
            // Filter D3: Skip fragments of larger spaced digit groups, e.g. phone numbers ("+61 2 9051 6489"), card numbers ("4111 1111 1111 1111"), formatted account numbers
            if isDigitGroupFragment(in: nsText, candidateNSRange: nsRange) { continue }
            
            // Compute keyword proximity (newline-weighted), needed by remaining filters and scoring
            let distance = distanceToNearestKeyword(
                in: nsText,
                keywordRanges: keywordRanges,
                candidateLocation: nsRange.location,
                candidateEnd: nsRange.location + nsRange.length
            )
            
            // Filter E: Keyword proximity gate, candidate must be near a keyword
            guard distance <= maxKeywordDistance else { continue }
            
            // Filter F: 4-digit year-like numbers require the keyword very close
            if candidate.count == 4, let num = Int(candidate), yearRange.contains(num) {
                guard distance <= maxYearKeywordDistance else { continue }
            }
            
            // Best candidate = closest to a keyword anchor
            if distance < bestDistance {
                bestDistance = distance
                bestCandidate = candidate
            }
        }
        
        // Normalize dash-grouped codes ("482-913" → "482913") so the clipboard gets the digits the user actually types into the verification field
        return bestCandidate?.replacingOccurrences(of: "-", with: "")
    }
    
    // MARK: - Context Helpers
    
    /// Separators that glue two digit runs into one larger number: dates (`03/03/2026`, `2026-03-05`), decimals (`1234.56`), and times (`12:3456`).
    private static let digitRunSeparators: Set<String> = ["/", "-", ".", ":"]
    
    /// Checks if the candidate digit sequence sits inside a date/decimal/time-like pattern, i.e. a `/`, `-`, `.`, or `:` with adjacent digits appears immediately before or after it.
    ///
    /// Catches patterns like `03/03/2026`, `2026-03-05`, `28/02/26`, `4599.00`, etc.
    private static func isDateAdjacent(in nsText: NSString, candidateNSRange nsRange: NSRange) -> Bool {
        let textLength = nsText.length
        let start = nsRange.location
        let end = start + nsRange.length
        
        // Check after: candidate followed by a separator then another digit
        if end + 1 < textLength {
            let charAfter = nsText.substring(with: NSRange(location: end, length: 1))
            if digitRunSeparators.contains(charAfter) {
                let nextChar = nsText.substring(with: NSRange(location: end + 1, length: 1))
                if nextChar.rangeOfCharacter(from: .decimalDigits) != nil {
                    return true
                }
            }
        }
        
        // Check before: separator preceded by a digit, then this candidate
        if start >= 2 {
            let charBefore = nsText.substring(with: NSRange(location: start - 1, length: 1))
            if digitRunSeparators.contains(charBefore) {
                let charBeforeSep = nsText.substring(with: NSRange(location: start - 2, length: 1))
                if charBeforeSep.rangeOfCharacter(from: .decimalDigits) != nil {
                    return true
                }
            }
        }
        
        return false
    }
    
    /// Checks whether the candidate is one group of a larger spaced/bracketed digit sequence, e.g. phone numbers ("+61 2 9051 6489", "(020) 1234 5678"), spaced card numbers ("4111 1111 1111 1111"), or formatted account numbers.
    ///
    /// Looking **before** the candidate, skips up to 3 spaces/parentheses; a digit or `+` there means the candidate continues an earlier group.
    /// Looking **after**, skips spaces only (so "123456 (10 min validity)" is not misread as grouped); a digit there means another group follows.
    /// Newlines are never skipped, since a digit on the next line is unrelated.
    private static func isDigitGroupFragment(in nsText: NSString, candidateNSRange nsRange: NSRange) -> Bool {
        let start = nsRange.location
        let end = nsRange.location + nsRange.length
        let groupSeparators: Set<String> = [" ", "\u{00A0}", "(", ")"]
        
        // Look before: digit or '+' across at most 3 space/parenthesis characters
        var pos = start - 1
        var skipped = 0
        while pos >= 0 && skipped < 3 {
            let ch = nsText.substring(with: NSRange(location: pos, length: 1))
            if groupSeparators.contains(ch) {
                pos -= 1
                skipped += 1
                continue
            }
            if ch == "+" || ch.rangeOfCharacter(from: .decimalDigits) != nil { return true }
            break
        }
        
        // Look after: digit across at most 2 space characters
        pos = end
        skipped = 0
        while pos < nsText.length && skipped < 2 {
            let ch = nsText.substring(with: NSRange(location: pos, length: 1))
            if ch == " " || ch == "\u{00A0}" {
                pos += 1
                skipped += 1
                continue
            }
            if ch.rangeOfCharacter(from: .decimalDigits) != nil { return true }
            break
        }
        
        return false
    }
    
    /// Checks if the candidate is immediately followed by a currency indicator ("5000 INR") or a time/duration unit ("1130 am", "1300 hrs"), examining a small suffix window.
    private static func hasNonOTPSuffix(in nsText: NSString, candidateEnd: Int) -> Bool {
        guard candidateEnd < nsText.length else { return false }
        let lookahead = min(nsText.length - candidateEnd, 12)
        let suffixText = nsText.substring(with: NSRange(location: candidateEnd, length: lookahead))
        let suffixRange = NSRange(location: 0, length: suffixText.utf16.count)
        if currencySuffixPattern.firstMatch(in: suffixText, options: [], range: suffixRange) != nil {
            return true
        }
        if timeSuffixPattern.firstMatch(in: suffixText, options: [], range: suffixRange) != nil {
            return true
        }
        return false
    }
    
    /// Checks if masking characters (X, x, *) appear shortly before the candidate, possibly separated by whitespace.
    /// Handles patterns like "XXXX XXXX 2112" where the digits are a suffix of a masked number, not an OTP.
    ///
    /// Looks back up to 8 characters before the candidate, skipping spaces.
    /// Note: The direct-adjacency case ("XXXXXX1862") is already handled by `\b` word boundaries, since `X` and `1` are both `\w`, so no boundary exists between them.
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
    /// Returns `Int.max` if `keywordRanges` is empty.
    ///
    /// Measures edge-to-edge character gap, with each `\n` in the gap adding `newlinePenalty` virtual characters and each sentence boundary (`.`, `!`, `?` followed by whitespace) adding `sentencePenalty`.
    /// This prevents false matches across structural boundaries in email notifications (e.g. tabular data, forwarded messages) where a keyword like "Currency Code" appears many lines above an unrelated number, and weakens anchoring across sentence breaks within a line.
    ///
    /// Uses `NSString` coordinates (UTF-16) consistently with the regex match positions.
    private static func distanceToNearestKeyword(
        in nsText: NSString,
        keywordRanges: [NSRange],
        candidateLocation: Int,
        candidateEnd: Int
    ) -> Int {
        var minDistance = Int.max
        
        for kwRange in keywordRanges {
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
            // The newline penalty only adds to the raw gap, so a raw gap already at or above
            // the current minimum can't improve it, skip the substring work
            guard rawGap < minDistance else { continue }
            
            // Weight structural boundaries in the gap: newlines and sentence-ending punctuation
            // A "." followed by "\n" counts once, as a newline
            let gapText = nsText.substring(with: NSRange(location: gapStart, length: rawGap))
            var penalty = 0
            var previous: Character = " "
            for ch in gapText {
                if ch == "\n" {
                    penalty += newlinePenalty
                } else if ch.isWhitespace && (previous == "." || previous == "!" || previous == "?") {
                    penalty += sentencePenalty
                }
                previous = ch
            }
            let weightedGap = rawGap + penalty
            
            minDistance = min(minDistance, weightedGap)
            if minDistance == 0 { return 0 }
        }
        
        return minDistance
    }
    
    // MARK: - OTP Handling
    
    /// Checks if the notification is from an allowed SMS app and contains an OTP.
    /// Returns the extracted code (or `nil`), and optionally copies it to the clipboard and shows a HUD toast when `autoCopy` is `true`.
    ///
    /// The `@discardableResult` allows call sites that only need the return value (e.g. to populate a "Copy OTP" action button) to ignore it, and call sites that only want the side-effects to ignore the return value, all without changing the call signature.
    ///
    /// - Parameters:
    ///   - body: The notification body text (may be nil).
    ///   - title: The notification title (used for logging the sender).
    ///   - appName: The user-facing app name (used for logging context).
    ///   - packageId: The Android package ID (e.g. `com.google.android.apps.messaging`), parsed by the caller from the raw notification ID.
    ///   - autoCopy: When `true` (default), copies the OTP to the clipboard and shows the HUD toast. Pass `false` during sync to detect the OTP for the action button without side-effects.
    @MainActor
    @discardableResult
    static func handleIfOTP(body: String?, title: String?, appName: String, packageId: String?, autoCopy: Bool = true) -> String? {
        guard let packageId,
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
