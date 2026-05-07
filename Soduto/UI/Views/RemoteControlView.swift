//
//  RemoteControlView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 07/05/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI
import Carbon.HIToolbox


// MARK: - Main view

struct RemoteControlView: View {
    @ObservedObject var service: RemoteControlService
    let device: Device
    
    @State private var skeActive = false
    @StateObject private var modifiers = StickyModifiers()
    @State private var physicalModifiers: NSEvent.ModifierFlags = []
    @State private var clickHighlight: ClickHighlight?
    @State private var showHelp = false
    @State private var isHolding = false   // explicit Hold toggle for mobile drag
    @State private var showLockHint = false // briefly shows ⌥+⎋ hint after clicking Lock
    
    private var isMobile: Bool { device.type == .Phone || device.type == .Tablet }
    
    // True when the peer is Android but NOT Soduto — standard KDE Connect Android.
    // These clients ignore shift/alt/ctrl modifier flags and just insert the raw key value,
    // so macOS must pre-apply modifiers (spoon-feed) for them.
    private var isVanillaAndroid: Bool {
        inferredPlatform == "Android" && !device.isAndroidCompanion
    }
    
    // Best-effort OS name: exact from Soduto identity extension, inferred from device type otherwise.
    // Standard KDE Connect clients don't send platformName, so we fall back to reasonable guesses.
    private var inferredPlatform: String {
        if let p = device.platformName, !p.isEmpty { return p }
        switch device.type {
        case .Phone, .Tablet: return "Android"   // overwhelmingly the common case
        case .TV:             return "Android"   // Android TV
        case .Desktop, .Laptop: return "Linux"   // most KDE Connect desktop users are Linux
        default:              return "Unknown"
        }
    }
    
    // Keyboard is available on Android only when the Remote Keyboard plugin is active.
    // On all other platforms (Linux, Windows, macOS) physical keyboard is always present.
    private var keyboardAvailable: Bool {
        inferredPlatform == "Android" ? service.remoteKeyboardEnabled : true
    }
    
    // The "Option/Alt" modifier icon — platform-neutral for all targets
    private var altIcon: String { "option" }
    
    // The "Command/Super/Meta/Windows" modifier icon — adapts to peer OS
    private var commandOrSuperIcon: String {
        switch inferredPlatform {
        case "macOS", "iOS", "iPadOS", "tvOS":  return "command"
        case "Windows":                         return "square.grid.2x2"
        default:                                return "diamond.fill"  // Linux, Android, unknown → Super/Meta
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            
            Divider()
            
            HStack(spacing: 0) {
                if keyboardAvailable || isMobile {
                    modifierColumn
                    Divider()
                }
                if service.isCapturing {
                    lockedOverlay
                } else {
                    trackpadArea
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider()
            
            clickButtonRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .onAppear { skeActive = IsSecureEventInputEnabled() }
        .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in
            // Refresh physical modifier state every 200ms.
            // Catch modifier releases outside trackpad area (flagsChanged only fires when TrackpadNSView is first responder).
            let current = NSEvent.modifierFlags.intersection([.shift, .control, .option, .command])
            if current != physicalModifiers { physicalModifiers = current }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            skeActive = IsSecureEventInputEnabled()
        }
    }
    
    
    // MARK: Header
    
    private var headerBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.headline)
                    .lineLimit(1)
                statusLabel
            }
            Spacer()
            Button {
                showHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                helpContent
            }
            lockButton
        }
    }
    
    private var statusLabel: some View {
        Group {
            if skeActive {
                Label("Secure Input is active: keyboard blocked", systemImage: "lock.fill")
                    .foregroundStyle(.orange)
            } else if inferredPlatform == "Android" {
                // Remote Keyboard status only meaningful on Android (requires Remote Keyboard plugin).
                if service.remoteKeyboardEnabled {
                    Label("Remote keyboard active", systemImage: "keyboard")
                        .foregroundStyle(.green)
                } else {
                    Label("Remote keyboard inactive", systemImage: "keyboard")
                        .foregroundStyle(.secondary)
                }
            }
            // For Linux/Windows/macOS peers the physical keyboard is always active, hence no label needed
        }
        .font(.caption)
    }
    
    // Clicking when unlocked shows hint only (does not lock). Intentional: prevent accidental lock-in.
    private var lockButton: some View {
        let locked   = service.isCapturing
        let tint: Color = locked ? .orange : .secondary
        let bg: Color   = locked ? Color.orange.opacity(0.15) : Color(NSColor.controlBackgroundColor)
        let border      = locked ? Color.orange : Color(NSColor.separatorColor)
        
        return Button {
            if locked {
                service.stopCapturing()
            } else {
                showLockHint = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { showLockHint = false }
                service.checkAccessibilityForLock()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: locked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 13, weight: .medium))
                ZStack {
                    Text("⌥+⎋ to lock").font(.caption)
                        .opacity(!locked && showLockHint ? 1 : 0)
                    Text(locked ? "Unlock" : "Lock Input").font(.subheadline)
                        .opacity(!locked && showLockHint ? 0 : 1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(border, lineWidth: 1))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.25), value: locked)
        .animation(.easeInOut(duration: 0.3), value: showLockHint)
    }
    
    
    // MARK: Locked overlay
    
    private var lockedOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Mouse & keyboard locked")
                .font(.headline)
            Text("Move your mouse to control the remote device.\nPress Option+Escape to exit.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
    
    
    // MARK: Modifier column
    
    private var modifierColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                // Modifier keys (keyboard only)
                if keyboardAvailable {
                    Spacer(minLength: 4)
                    shiftModifierButton
                    modifierButton("control", isActive: modifiers.ctrl || physicalModifiers.contains(.control)) { modifiers.ctrl.toggle() }
                    modifierButton(altIcon, isActive: modifiers.alt || physicalModifiers.contains(.option))  { modifiers.alt.toggle() }
                    osModifierButton
                    Divider().padding(.horizontal, 8).padding(.vertical, 2)
                }
                
                // Navigation keys (mobile)
                if isMobile {
                    Spacer(minLength: keyboardAvailable ? 0 : 4)
                    navButton("chevron.backward", isHighlit: service.navHighlight == .back)    { service.sendBack(to: device) }
                    navButton("house.fill",       isHighlit: service.navHighlight == .home)    { service.sendHome(to: device) }
                    navButton("rectangle.stack.fill",     isHighlit: service.navHighlight == .recents) { service.sendRecents(to: device) }
                    
                    // Volume + power: Soduto-specific extensions (other clients ignore them)
                    if device.isAndroidCompanion {
                        Divider().padding(.horizontal, 8).padding(.vertical, 2)
                        navButton("speaker.plus.fill", isHighlit: service.navHighlight == .volumeUp)   { service.sendVolumeUp(to: device) }
                        navButton("speaker.minus.fill", isHighlit: service.navHighlight == .volumeDown) { service.sendVolumeDown(to: device) }
                        navButton("powersleep",        isHighlit: service.navHighlight == .power)      { service.sendPower(to: device) }
                    }
                    Spacer(minLength: 4)
                } else if !keyboardAvailable {
                    Spacer(minLength: 4)
                }
            }
        }
        .frame(width: 52)
    }
    
    private func navButton(_ systemImage: String,
                           isHighlit: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .background(isHighlit ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(isHighlit ? Color.accentColor : Color(NSColor.separatorColor), lineWidth: 1))
                .foregroundStyle(isHighlit ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isHighlit)
    }
    
    // 3-state Shift button: off → once → locked → off.
    private var shiftModifierButton: some View {
        let physShift = physicalModifiers.contains(.shift)
        let state     = modifiers.shiftState
        let isActive  = state != .off || physShift
        let icon = state == .locked ? "capslock.fill"
                 : isActive         ? "shift.fill"
                 : "shift"

        return Button { modifiers.toggleShift() } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 34)
                .background(isActive ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(isActive ? Color.accentColor : Color(NSColor.separatorColor), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary))
        .animation(.easeOut(duration: 0.1), value: state == .off)
    }
    
    // Dual icon (Windows + Meta) only when peer OS is genuinely unknown and device is desktop/laptop.
    // Known platforms show their exact icon; mobile/TV infers Android → Meta only.
    private var superKeyIsDual: Bool {
        guard device.platformName == nil || device.platformName!.isEmpty else { return false }
        return device.type == .Desktop || device.type == .Laptop || device.type == .Unknown
    }
    
    private var osModifierButton: some View {
        let isActive = modifiers.command || physicalModifiers.contains(.command)
        let isDual   = superKeyIsDual
        
        return Button { modifiers.command.toggle() } label: {
            Group {
                if isDual {
                    VStack(spacing: 1) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 9.5, weight: .medium))
                        Rectangle().frame(width: 18, height: 0.6)
                            .foregroundStyle(isActive ? Color.accentColor.opacity(0.8) : Color(NSColor.secondaryLabelColor))
                        Image(systemName: "diamond.fill").font(.system(size: 9.5, weight: .medium))
                    }
                } else {
                    Image(systemName: commandOrSuperIcon).font(.system(size: 14, weight: .medium))
                }
            }
            .frame(width: 34, height: 34)
            .background(isActive ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(isActive ? Color.accentColor : Color(NSColor.separatorColor), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary))
        .animation(.easeOut(duration: 0.1), value: isActive)
    }
    
    private func modifierButton(_ image: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 34)
                .background(isActive ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isActive ? Color.accentColor : Color(NSColor.separatorColor), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary))
        .animation(.easeOut(duration: 0.1), value: isActive)
    }
    
    
    // MARK: Trackpad area
    
    private var trackpadArea: some View {
        ZStack(alignment: .bottom) {
            TrackpadView(
                service: service,
                device: device,
                modifiers: modifiers,
                onModifierFlagsChanged: { flags in physicalModifiers = flags },
                onClickHighlight: { type in flashClickHighlight(type) },
                onHoldChanged: { holding in isHolding = holding },
                isVanillaAndroid: isVanillaAndroid,
                isHolding: isHolding
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                trackpadDotPattern
                    .background(Color(NSColor.underPageBackgroundColor))
            )
            
            trackpadHint.padding(.bottom, 8)
        }
        .padding(12)
    }
    
    private var trackpadDotPattern: some View {
        Canvas { context, size in
            let spacing: CGFloat = 18
            let r: CGFloat = 1.2
            var x = spacing
            while x < size.width {
                var y = spacing
                while y < size.height {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .color(Color.secondary.opacity(0.18))
                    )
                    y += spacing
                }
                x += spacing
            }
        }
        .allowsHitTesting(false)
    }
    
    private var trackpadHint: some View {
        Text(isMobile ? "Hover · Tap · 2-finger Scroll/Swipe · ⌥ Pause · ⌃ Capture" : "Hover · Tap · Scroll · ⌥ Pause · ⌃ Capture")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
    
    private var helpContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Gesture Guide")
                    .font(.headline)
                    .padding(.bottom, 8)
                
                helpSection("Trackpad gestures") {
                    helpRow("Hover",                    "Move remote cursor")
                    helpRow("Tap",                      isMobile ? "Tap on device" : "Left click")
                    helpRow("Hold 500ms",               "Long press / drag start")
                    helpRow("Click + drag",             "Drag")
                    helpRow("2-finger tap / R-click",   isMobile ? "Back" : "Right click")
                    helpRow("Force Click (Force Touch)", isMobile ? "Home" : "Middle click")
                    helpRow("2-finger scroll",          "Scroll")
                    helpRow("Quick 2-finger swipe",     "Touch-drag swipe")
                }
                
                helpSection("Keyboard lock") {
                    helpRow("⌥ + Esc",    "Toggle cursor lock (works globally)")
                    helpRow("Hold ⌥",     "Pause cursor while held")
                    helpRow("Hold ⌃",     "Freeze cursor inside trackpad")
                    helpRow("⌘ + W",      "Close window")
                    helpRow("⌘⌃ + F",     "Toggle fullscreen")
                }
                
                if isMobile {
                    helpSection("Navigation shortcuts") {
                        helpRow("⌘ + [",          "Back")
                        helpRow("⌘⇧ + H",         "Home")
                        helpRow("⌘⇧ + R",         "Recents")
                        helpRow("⌘⇧ + ↑",         "Volume up")
                        helpRow("⌘⇧ + ↓",         "Volume down")
                        helpRow("⌘⇧ + L",         "Power button")
                    }
                    
                    helpSection("Notes") {
                        helpRow("Power",        "Locks the screen. Wake tip: press Home, it triggers screen-on as a side effect!")
                        helpRow("Home/Recents", "Require MouseReceiver accessibility service on Android")
                        helpRow("Vol+/Vol−",    "Adjusts media (music) volume")
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 340, height: 480)
    }
    
    private func helpSection<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            content()
        }
    }
    
    private func helpRow(_ gesture: String, _ description: String) -> some View {
        HStack(alignment: .top) {
            Text(gesture)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(width: 160, alignment: .leading)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }
    
    
    // MARK: Click button row
    
    private var clickButtonRow: some View {
        Group {
            if isMobile {
                mobileClickButtonRow
            } else {
                desktopClickButtonRow
            }
        }
    }
    
    // Desktop: standard left / middle / right mouse buttons
    private var desktopClickButtonRow: some View {
        HStack(spacing: 16) {
            clickButton("Left",   systemImage: "cursorarrow.click", isHighlit: clickHighlight == .left)   { service.sendSingleClick(to: device) }
            clickButton("Middle", systemImage: "dot.circle.and.cursorarrow", isHighlit: clickHighlight == .middle) { service.sendMiddleClick(to: device) }
            clickButton("Right",  systemImage: "cursorarrow.click.2", isHighlit: clickHighlight == .right)  { service.sendRightClick(to: device) }
        }
    }
    
    // Mobile: Android-style touch actions
    private var mobileClickButtonRow: some View {
        HStack(spacing: 16) {
            // Tap = singleclick
            clickButton("Tap", systemImage: "hand.rays.fill", isHighlit: clickHighlight == .left) {
                service.sendSingleClick(to: device)
            }
            
            // Long Tap = discrete long press → uses Soduto-specific `longclick` field,
            // only show when connected to Soduto Android (other clients silently ignore it)
            if device.isAndroidCompanion {
                clickButton("Long Tap", systemImage: "hand.tap.fill", isHighlit: false) {
                    service.sendLongTap(to: device)
                }
            }
            
            // Hold = toggle singlehold / singlerelease for drag operations
            clickButton(isHolding ? "Release" : "Hold",
                        systemImage: isHolding ? "hand.raised.slash.fill" : "hand.raised.fill",
                        isHighlit: isHolding) {
                if isHolding {
                    service.sendMouseUp(to: device)
                    isHolding = false
                } else {
                    service.sendMouseDown(to: device)
                    isHolding = true
                }
            }
        }
    }
    
    private func clickButton(_ title: String, systemImage: String, isHighlit: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(isHighlit ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isHighlit ? Color.accentColor : Color(NSColor.separatorColor), lineWidth: 1)
            )
            .foregroundStyle(isHighlit ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isHighlit)
    }
    
    private func flashClickHighlight(_ type: ClickHighlight) {
        clickHighlight = type
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if clickHighlight == type { clickHighlight = nil }
        }
    }
}


// MARK: - Sticky modifier state

/// Shift has three states (like on-screen keyboard convention):
///   .off    — not active
///   .once   — active for the next keystroke only, then clears (shown in accent blue)
///   .locked — caps-lock equivalent, stays active until tapped off (shown in orange)
enum ShiftState { case off, once, locked }

final class StickyModifiers: ObservableObject {
    @Published var shiftState: ShiftState = .off
    @Published var ctrl    = false
    @Published var alt     = false
    @Published var command = false
    
    var shift: Bool { shiftState != .off }
    
    func toggleShift() {
        switch shiftState {
        case .off:    shiftState = .once
        case .once:   shiftState = .locked
        case .locked: shiftState = .off
        }
    }
    
    func consume() -> (shift: Bool, ctrl: Bool, alt: Bool, command: Bool) {
        let s = shift
        if shiftState == .once { shiftState = .off }  // .once clears; .locked persists.
        defer { ctrl = false; alt = false; command = false }
        return (s, ctrl, alt, command)
    }
}


// MARK: - Click highlight type

enum ClickHighlight: Equatable { case left, middle, right }


// MARK: - Trackpad NSViewRepresentable

struct TrackpadView: NSViewRepresentable {
    let service: RemoteControlService
    let device: Device
    let modifiers: StickyModifiers
    let onModifierFlagsChanged: ((NSEvent.ModifierFlags) -> Void)?
    let onClickHighlight: ((ClickHighlight) -> Void)?
    let onHoldChanged: ((Bool) -> Void)?
    let isVanillaAndroid: Bool
    let isHolding: Bool
    
    func makeNSView(context: Context) -> TrackpadNSView {
        let view = TrackpadNSView()
        let coord = context.coordinator
        
        view.isMobileDevice = (device.type == .Phone || device.type == .Tablet)
        view.isVanillaAndroid = isVanillaAndroid
        view.onSingleClick = { [weak service] in
            // If explicit Hold button is active, release it (button sets isHolding but bypasses drag callbacks).
            if coord.holdActive {
                service?.sendMouseUp(to: coord.device)
                coord.holdActive = false
                coord.onHoldChanged?(false)
            } else {
                service?.sendSingleClick(to: coord.device)
                coord.onClickHighlight?(.left)
            }
        }
        view.onDoubleClick = { [weak service] in
            service?.sendDoubleClick(to: coord.device)
        }
        view.onMouseDown = { [weak service] in
            service?.sendMouseDown(to: coord.device)
            coord.holdActive = true
            coord.onHoldChanged?(true)
        }
        view.onMouseUp = { [weak service] in
            service?.sendMouseUp(to: coord.device)
            coord.holdActive = false
            coord.onHoldChanged?(false)
        }
        view.onRightClick = { [weak service] in
            // Mobile: right-click = Back. Route through helpers for correct navHighlight.
            if coord.isMobileDevice {
                service?.sendBack(to: coord.device)   // flashes .back via service.navHighlight
            } else {
                service?.sendRightClick(to: coord.device)
            }
            coord.onClickHighlight?(.right)
        }
        view.onMiddleClick = { [weak service] in
            // Mobile: middle-click = Home.
            if coord.isMobileDevice {
                service?.sendHome(to: coord.device)   // flashes .home via service.navHighlight
            } else {
                service?.sendMiddleClick(to: coord.device)
            }
            coord.onClickHighlight?(.middle)
        }
        view.onMouseMove = { [weak service] dx, dy in service?.sendMouseMove(dx: dx, dy: dy, to: coord.device) }
        view.onScroll    = { [weak service] dx, dy in service?.sendScroll(dx: dx, dy: dy, to: coord.device) }
        view.onSwipe     = { [weak service] dx, dy in service?.sendSwipe(dx: dx, dy: dy, to: coord.device) }
        view.onNavBack    = { [weak service] in service?.sendBack(to: coord.device) }
        view.onNavHome    = { [weak service] in service?.sendHome(to: coord.device) }
        view.onNavRecents = { [weak service] in service?.sendRecents(to: coord.device) }
        view.onKeyDown   = { [weak service] key, specialKey, shift, ctrl, alt, command in
            guard let service else { return }
            let sticky = coord.modifiers.consume()
            let s = shift  || sticky.shift
            let c = ctrl   || sticky.ctrl
            let a = alt    || sticky.alt
            let su = command || sticky.command
            if let sk = specialKey {
                service.sendSpecialKey(sk, shift: s, ctrl: c, alt: a, command: su, to: coord.device)
            } else if let k = key {
                // Vanilla Android Client: only physical shift is in event.characters. Apply sticky shift manually if it's the sole source.
                let finalKey = (coord.isVanillaAndroid && sticky.shift && !shift) ? applyShift(k) : k
                service.sendKey(finalKey, shift: s, ctrl: c, alt: a, command: su, to: coord.device)
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: TrackpadNSView, context: Context) {
        let isMobile = (device.type == .Phone || device.type == .Tablet)
        context.coordinator.device = device
        context.coordinator.modifiers = modifiers
        context.coordinator.onClickHighlight = onClickHighlight
        context.coordinator.onHoldChanged = onHoldChanged
        context.coordinator.isMobileDevice = isMobile
        context.coordinator.isVanillaAndroid = isVanillaAndroid
        // Sync explicit Hold button state so onSingleClick can detect active hold
        context.coordinator.holdActive = isHolding
        nsView.onModifierFlagsChanged = onModifierFlagsChanged
        nsView.isMobileDevice = isMobile
        nsView.isVanillaAndroid = isVanillaAndroid
    }
    
    func makeCoordinator() -> Coordinator {
        let c = Coordinator(device: device, modifiers: modifiers, onClickHighlight: onClickHighlight)
        c.isMobileDevice = (device.type == .Phone || device.type == .Tablet)
        c.isVanillaAndroid = isVanillaAndroid
        c.onHoldChanged = onHoldChanged
        return c
    }
    
    final class Coordinator {
        var device: Device
        var modifiers: StickyModifiers
        var onClickHighlight: ((ClickHighlight) -> Void)?
        var onHoldChanged: ((Bool) -> Void)?
        var isMobileDevice: Bool = false
        var isVanillaAndroid: Bool = false
        var holdActive: Bool = false  // Set by Hold button and drag callbacks.
        
        init(device: Device, modifiers: StickyModifiers, onClickHighlight: ((ClickHighlight) -> Void)?) {
            self.device = device
            self.modifiers = modifiers
            self.onClickHighlight = onClickHighlight
        }
    }
}


// MARK: - Trackpad NSView

final class TrackpadNSView: NSView {
    
    var onSingleClick:  (() -> Void)?
    var onDoubleClick:  (() -> Void)?
    var onMouseDown:    (() -> Void)?
    var onMouseUp:      (() -> Void)?
    var onRightClick:   (() -> Void)?
    var onMiddleClick:  (() -> Void)?
    var onMouseMove:    ((CGFloat, CGFloat) -> Void)?
    var onScroll:       ((Double, Double) -> Void)?
    var onSwipe:        ((Double, Double) -> Void)?
    var onKeyDown:      ((_ key: String?, _ specialKey: Int?, _ shift: Bool, _ ctrl: Bool, _ alt: Bool, _ command: Bool) -> Void)?
    var onModifierFlagsChanged: ((NSEvent.ModifierFlags) -> Void)?
    
    var isMobileDevice: Bool = false
    var isVanillaAndroid: Bool = false
    
    private var trackingArea: NSTrackingArea?
    private var mouseDownLocation: NSPoint?
    private var isDragging = false
    private var isLongPressing = false
    private var longPressTimer: Timer?
    private var forceTouchFired = false
    private var skipNextMouseUp = false  // suppresses the singleclick that follows a Force Touch
    private let dragThreshold: CGFloat = 4
    private let longPressDelay: TimeInterval = 0.5
    
    // Swipe detection — accumulated delta + timing within a single gesture
    private var scrollAccumDx: Double = 0
    private var scrollAccumDy: Double = 0
    private var scrollGestureStart: Date?
    // Threshold: accumulated magnitude > 40pt in under 0.35 s = swipe
    private let swipeMagnitudeThreshold: Double = 30
    private let swipeTimeThreshold: TimeInterval = 0.35
    
    override var acceptsFirstResponder: Bool { true }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }
    
    
    // MARK: Hover-to-move
    
    // Control-lock anchor: record from mouseMoved (not flagsChanged) so it works even when not first responder.
    private var controlLockAnchor: NSPoint?
    
    override func mouseEntered(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }
    
    override func mouseMoved(with event: NSEvent) {
        guard !NSEvent.modifierFlags.contains(.option) else { return }
        let dx = event.deltaX, dy = event.deltaY
        if abs(dx) > 0.1 || abs(dy) > 0.1 { onMouseMove?(dx, dy) }
        
        if NSEvent.modifierFlags.contains(.control) {
            // Record anchor on first Control detection during movement.
            if controlLockAnchor == nil {
                let pos = convert(event.locationInWindow, from: nil)
                controlLockAnchor = NSPoint(
                    x: min(max(pos.x, 4), bounds.width  - 4),
                    y: min(max(pos.y, 4), bounds.height - 4)
                )
            }
            warpCursor(to: controlLockAnchor!)
        } else {
            controlLockAnchor = nil
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        guard let anchor = controlLockAnchor else { return }
        warpCursor(to: anchor)
    }
    
    private func warpCursor(to posInView: NSPoint) {
        let posInWindow = convert(posInView, to: nil)
        guard let window else { return }
        let screen = window.convertToScreen(NSRect(origin: posInWindow, size: .zero)).origin
        CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: (NSScreen.main?.frame.height ?? 0) - screen.y))
    }
    
    
    // MARK: Click and drag
    
    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        isDragging = false
        isLongPressing = false
        window?.makeFirstResponder(self)
        
        // Timer for long press (500 ms): fires singlehold if no drag occurs.
        longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressDelay, repeats: false) { [weak self] _ in
            guard let self, !self.isDragging else { return }
            self.isLongPressing = true
            self.onMouseDown?()  // singlehold
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        longPressTimer?.invalidate(); longPressTimer = nil
        
        if !isDragging, let start = mouseDownLocation {
            let pos = event.locationInWindow
            if hypot(pos.x - start.x, pos.y - start.y) > dragThreshold {
                isDragging = true
                if !isLongPressing { onMouseDown?() }  // singlehold (if not already sent)
            }
        }
        if isDragging {
            let dx = event.deltaX, dy = event.deltaY
            if abs(dx) > 0.1 || abs(dy) > 0.1 { onMouseMove?(dx, dy) }
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        longPressTimer?.invalidate(); longPressTimer = nil
        defer { isDragging = false; isLongPressing = false; mouseDownLocation = nil }
        
        // Force Touch already handled this click — swallow the mouseUp
        if skipNextMouseUp { skipNextMouseUp = false; return }
        
        if isDragging || isLongPressing {
            onMouseUp?()  // singlerelease
        } else if !isMobileDevice && event.clickCount == 2 {
            onDoubleClick?()  // desktop: send doubleclick packet
        } else {
            onSingleClick?()
        }
    }
    
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }
    override func otherMouseDown(with event: NSEvent)  { onMiddleClick?() }
    
    
    // MARK: Two-finger scroll / swipe
    
    // Quick gesture (< 0.35 s) with magnitude > 30 pt = swipe; otherwise = scroll.
    override func scrollWheel(with event: NSEvent) {
        let dx = Double(event.scrollingDeltaX)
        let dy = Double(event.scrollingDeltaY)
        
        switch event.phase {
        case .began:
            scrollAccumDx = dx
            scrollAccumDy = dy
            scrollGestureStart = Date()
            if abs(dx) > 0.1 || abs(dy) > 0.1 { onScroll?(dx, dy) }
            
        case .changed:
            scrollAccumDx += dx
            scrollAccumDy += dy
            if abs(dx) > 0.1 || abs(dy) > 0.1 { onScroll?(dx, dy) }
            
        case .ended:
            if let start = scrollGestureStart {
                let elapsed = Date().timeIntervalSince(start)
                let magnitude = hypot(scrollAccumDx, scrollAccumDy)
                if elapsed < swipeTimeThreshold && magnitude > swipeMagnitudeThreshold {
                    onSwipe?(scrollAccumDx, scrollAccumDy)
                }
            }
            scrollAccumDx = 0; scrollAccumDy = 0; scrollGestureStart = nil
            
        default:
            // Old-style or momentum scroll: send as scroll.
            if abs(dx) > 0.1 || abs(dy) > 0.1 { onScroll?(dx, dy) }
        }
    }
    
    
    // MARK: Force Touch
    
    // Stage 2: deep Force Click → long tap. Stage 0: finger lifted → reset trigger.
    override func pressureChange(with event: NSEvent) {
        switch event.stage {
        case 2 where !forceTouchFired:
            forceTouchFired = true
            skipNextMouseUp = true  // Prevent singleclick from trailing mouseUp.
            longPressTimer?.invalidate(); longPressTimer = nil
            onMiddleClick?()  // Force Click: Home on mobile, middle click on desktop.
        case 0:
            forceTouchFired = false
        default: break
        }
    }
    
    
    // MARK: Keyboard input
    
    var onNavBack:    (() -> Void)?
    var onNavHome:    (() -> Void)?
    var onNavRecents: (() -> Void)?
    
    override func keyDown(with event: NSEvent) {
        let flags   = event.modifierFlags
        let shift   = flags.contains(.shift)
        let ctrl    = flags.contains(.control)
        let alt     = flags.contains(.option)
        let command = flags.contains(.command)
        let keyCode = event.keyCode
        
        // Nav shortcuts (Cmd+[ Cmd+Shift+H Cmd+Shift+R): handled here for reliability when first responder.
        if command {
            if keyCode == 33 && !shift { onNavBack?();    return }
            if keyCode == 4  &&  shift { onNavHome?();    return }
            if keyCode == 15 &&  shift { onNavRecents?(); return }
        }
        
        if let specialKey = kdeSpecialKey(for: keyCode) {
            onKeyDown?(nil, specialKey, shift, ctrl, alt, command)
        } else {
            // Vanilla Android Client: spoon-feed event.characters. Other targets: base key + modifiers.
            let key: String
            if isVanillaAndroid {
                key = event.characters ?? ""
            } else {
                key = rawBaseCharacter(for: event.keyCode) ?? event.charactersIgnoringModifiers ?? ""
            }
            if !key.isEmpty { onKeyDown?(key, nil, shift, ctrl, alt, command) }
        }
    }
    
    
    // MARK: Modifier flags
    
    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags
        onModifierFlagsChanged?(flags)
        if !flags.contains(.control) { controlLockAnchor = nil }
    }
}
