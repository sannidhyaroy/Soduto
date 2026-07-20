//
//  KeyboardUtils.swift
//  Soduto
//
//  Created by Sannidhya Roy on 08/05/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import Foundation
import Carbon.HIToolbox


// MARK: - Raw base character (UCKeyTranslate)

/// Returns the base glyph for a key code with all modifiers stripped using UCKeyTranslate.
func rawBaseCharacter(for keyCode: UInt16) -> String? {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let data = unsafeBitCast(ptr, to: CFData.self) as Data
    guard let layout = data.withUnsafeBytes({ $0.bindMemory(to: UCKeyboardLayout.self).baseAddress }) else { return nil }
    var dead: UInt32 = 0
    var chars = [UniChar](repeating: 0, count: 4)
    var len = 0
    let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown),
                                0, UInt32(LMGetKbdType()),
                                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                &dead, 4, &len, &chars)
    guard status == noErr, len > 0 else { return nil }
    return String(utf16CodeUnits: Array(chars.prefix(len)), count: len)
}


// MARK: - KDE Connect special-key mapping

/// Maps a macOS virtual key code to a KDE Connect special-key code (1–32).
/// Returns `nil` for regular printable keys.
func kdeSpecialKey(for keyCode: UInt16) -> Int? {
    switch keyCode {
    case 51:  return 1   // Backspace
    case 48:  return 2   // Tab
    case 36:  return 12  // Return
    case 123: return 4   // Left Arrow
    case 126: return 5   // Up Arrow
    case 124: return 6   // Right Arrow
    case 125: return 7   // Down Arrow
    case 116: return 8   // Page Up
    case 121: return 9   // Page Down
    case 115: return 10  // Home
    case 119: return 11  // End
    case 117: return 13  // Forward Delete
    case 53:  return 14  // Escape
    case 122: return 21  // F1
    case 120: return 22  // F2
    case 99:  return 23  // F3
    case 118: return 24  // F4
    case 96:  return 25  // F5
    case 97:  return 26  // F6
    case 98:  return 27  // F7
    case 100: return 28  // F8
    case 101: return 29  // F9
    case 109: return 30  // F10
    case 103: return 31  // F11
    case 111: return 32  // F12
    default:  return nil
    }
}


// MARK: - Shift application (vanilla Android spoon-feed)

/// Applies Shift to a single character (US layout). Used when sticky shift is the only source for vanilla Android Client.
func applyShift(_ key: String) -> String {
    guard key.count == 1, let c = key.first else { return key }
    if c.isLetter { return key.uppercased() }
    let map: [Character: Character] = [
        "`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
        "6": "^", "7": "&", "8": "*", "9": "(", "0": ")", "-": "_",
        "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"",
        ",": "<", ".": ">", "/": "?"
    ]
    return map[c].map(String.init) ?? key
}
