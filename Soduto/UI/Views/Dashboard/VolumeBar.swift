//
//  VolumeBar.swift
//  Soduto
//
//  Created by Sannidhya Roy on 23/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

/// A sleek custom volume bar with hover callout and drag callout.
/// Replaces SwiftUI Slider in the media player transport row.
struct VolumeBar: View {
    /// Current (pending-aware) value in [0, 100].
    let value: Double
    /// Called continuously while the user drags with the live value.
    let onChanging: (Double) -> Void
    /// Called when the drag ends with the final value.
    let onCommit: (Double) -> Void
    
    @State private var isDragging = false
    @State private var dragValue: Double = 0
    @State private var isHovering = false
    @State private var barWidth: CGFloat = 0
    
    private var displayValue: Double { isDragging ? dragValue : value }
    private var fraction: Double { max(0, min(1, displayValue / 100.0)) }
    
    private let trackNormal: CGFloat  = 3
    private let trackActive: CGFloat  = 4
    private let thumbR:      CGFloat  = 5
    
    var body: some View {
        let active  = isHovering || isDragging
        let trackH  = active ? trackActive : trackNormal
        let thumbX  = fraction * barWidth
        // Keep callout horizontally within the bar (approx half-width of "100%" badge)
        let calloutX = max(20, min(barWidth - 20, thumbX))
        
        ZStack(alignment: .leading) {
            // Transparent hit area: keeps the ZStack at full height/width
            Color.clear
            
            // Track background
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: trackH)
                .frame(maxWidth: .infinity)
            
            // Filled portion
            if displayValue > 0 && barWidth > 0 {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: thumbX, height: trackH)
            }
            
            // Thumb: fades in on hover / drag
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                .frame(width: thumbR * 2, height: thumbR * 2)
                .offset(x: thumbX - thumbR)
                .opacity(active ? 1 : 0)
            
            // Callout: appears on hover (current value) or drag (live value)
            if active {
                VolumeCalloutView(value: Int(displayValue))
                    .fixedSize()
                    .position(x: calloutX, y: -10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(height: 20)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { barWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in barWidth = w }
            }
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let v = max(0, min(100, g.location.x / barWidth * 100))
                    dragValue = v
                    if !isDragging { isDragging = true }
                    onChanging(v)
                }
                .onEnded { g in
                    let v = max(0, min(100, g.location.x / barWidth * 100))
                    isDragging = false
                    onCommit(v)
                }
        )
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .animation(.easeInOut(duration: 0.1),  value: isDragging)
    }
}

// MARK: - Callout

private struct VolumeCalloutView: View {
    let value: Int
    
    var body: some View {
        VStack(spacing: 0) {
            Text("\(value)%")
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                )
            DownwardArrow()
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: 8, height: 4)
        }
    }
}

private struct DownwardArrow: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.closeSubpath()
        }
    }
}

#Preview {
    VStack(spacing: 32) {
        VolumeBar(value: 0,   onChanging: { _ in }, onCommit: { _ in })
        VolumeBar(value: 35,  onChanging: { _ in }, onCommit: { _ in })
        VolumeBar(value: 100, onChanging: { _ in }, onCommit: { _ in })
    }
    .frame(width: 120)
    .padding(40)
}
