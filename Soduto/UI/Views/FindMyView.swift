//
//  FindMyView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 08/05/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

// MARK: - Alert View

struct FindMyAlertView: View {
    let initiatorName: String
    let onStop: () -> Void

    @State private var ring1 = false
    @State private var ring2 = false
    @State private var ring3 = false
    @State private var buttonHovered = false

    // Mirror the int→DeviceType mapping from Configuration.swift
    private var hostDeviceSymbol: String {
        switch AppDefaultsStore.Preferences.deviceType {
        case 0: return "desktopcomputer"
        case 1: return "laptopcomputer"
        case 2: return "iphone"
        case 3: return "ipad"
        case 4: return "tv"
        default: return "laptopcomputer"
        }
    }

    // os() guards are for correctness and future cross-platform compatibility.
    // Currently only macOS ships; other branches are unreachable but kept accurate
    // so porting to iOS/tvOS/watchOS requires no changes here.
    private var alertTitle: String {
        #if os(macOS)
        return "Find My Mac"
        #elseif os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return "Find My iPad"
        } else {
            return "Find My iPhone"
        }
        #elseif os(tvOS)
        return "Find My TV"
        #elseif os(watchOS)
        return "Find My Watch"
        #elseif os(visionOS)
        return "Find My Vision Pro"
        #else
        return "Find My Device"
        #endif
    }

    var body: some View {
        ZStack {
            FindMyMaterialView()
                .ignoresSafeArea()
                .clipShape(RoundedRectangle(cornerRadius: 20))

            VStack(spacing: 22) {
                ringIcon
                textBlock
                stopButton
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
        }
        .onAppear {
            ring1 = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) { ring2 = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.00) { ring3 = true }
        }
    }

    // MARK: Sub-views

    private var ringIcon: some View {
        ZStack {
            expandingRing(animating: ring1)
            expandingRing(animating: ring2)
            expandingRing(animating: ring3)

            Circle()
                .fill(.primary.opacity(0.12))
                .frame(width: 76, height: 76)
                .overlay {
                    Circle()
                        .strokeBorder(.primary.opacity(0.18), lineWidth: 1)
                }

            Image(systemName: hostDeviceSymbol)
                .font(.system(size: 32))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)
        }
        // Rings scale to 2.8× the 76 pt base = ~213 pt diameter; give a little extra buffer
        .frame(width: 230, height: 230)
    }

    private func expandingRing(animating: Bool) -> some View {
        Circle()
            .strokeBorder(.primary.opacity(0.32), lineWidth: 1.5)
            .frame(width: 76, height: 76)
            .scaleEffect(animating ? 2.8 : 1.0)
            .opacity(animating ? 0 : 0.85)
            .animation(
                .easeOut(duration: 2.0).repeatForever(autoreverses: false),
                value: animating
            )
    }

    private var textBlock: some View {
        VStack(spacing: 6) {
            Text(alertTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
            Text("\(initiatorName) is looking for this device")
                .font(.system(size: 13))
                .foregroundStyle(.secondary.opacity(0.65))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            HStack(spacing: 7) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .bold))
                Text("Stop Ringing")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .frame(minWidth: 160, minHeight: 42)
            .background {
                Capsule()
                    .fill(.primary.opacity(buttonHovered ? 0.22 : 0.13))
                    .overlay {
                        Capsule()
                            .strokeBorder(.primary.opacity(0.28), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [])
        .onHover { hovered in
            withAnimation(.easeInOut(duration: 0.15)) { buttonHovered = hovered }
        }
    }
}

// MARK: - Blur Background

struct FindMyMaterialView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 20
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Preview

#Preview {
    FindMyAlertView(initiatorName: "Pixel 9 Pro", onStop: {})
        .frame(width: 340, height: 450)
}
