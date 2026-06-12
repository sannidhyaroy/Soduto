//
//  MarqueeText.swift
//  Soduto
//
//  Created by Sannidhya Roy on 23/03/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

/// A text view that scrolls horizontally when its content overflows the container.
///
/// Overflowing text rests `fadeWidth` points from the left edge (keeping the first character
/// fully opaque inside the permanent fade zone), then scrolls left continuously. A second copy
/// trails at `gap` points so the container is never empty. Text that fits is center-aligned
/// and static with no fades. Foreground style is inherited from the environment.
struct MarqueeText: View {
    let text: String
    let font: Font
    
    private let speed: Double         = 40   // pt/sec
    private let pauseDuration: Double = 1.5
    private let gap: CGFloat          = 20   // spacing between the end of one pass and the start of the next
    private let fadeWidth: CGFloat    = 12   // permanent edge fade zone; also the resting inset from the left
    
    @State private var textWidth: CGFloat      = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat         = 0
    
    private var needsScrolling: Bool {
        containerWidth > 0 && textWidth > containerWidth
    }
    
    // One cycle moves the HStack by exactly (textWidth + gap), after which the second copy
    // lands at x = fadeWidth, the same resting position as the first copy, so the reset is seamless.
    private var cycleDuration: Double { Double(textWidth + gap) / speed }
    
    private struct ScrollID: Equatable {
        var text: String
        var textWidth: CGFloat
        var containerWidth: CGFloat
    }
    
    var body: some View {
        // Invisible base: establishes the layout frame (full offered width × one line height).
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { containerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in containerWidth = w }
            })
            // Permanent hidden measurement for the text's natural (unconstrained) width.
            .overlay {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { textWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, w in textWidth = w }
                    })
            }
            // Visible content layer.
            .overlay(alignment: .leading) {
                if needsScrolling {
                    // Two copies of the text separated by `gap`. Both scroll together so as the
                    // first exits left the second is already entering from the right.
                    HStack(spacing: gap) {
                        Text(text).font(font).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        Text(text).font(font).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    }
                    .offset(x: offset)
                } else {
                    Text(text)
                        .font(font)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .clipped()
            .mask(effectiveMask)
            .task(id: ScrollID(text: text, textWidth: textWidth, containerWidth: containerWidth)) {
                // Position instantly: scrolling text rests at fadeWidth, static text at 0.
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { offset = needsScrolling ? fadeWidth : 0 }
                guard needsScrolling else { return }
                await runScrollLoop()
            }
    }
    
    @ViewBuilder
    private var effectiveMask: some View {
        if needsScrolling, containerWidth >= fadeWidth * 2 {
            // Permanent symmetric fades. The resting inset (fadeWidth) keeps the first character
            // fully opaque at the left boundary.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: fadeWidth / containerWidth),
                    .init(color: .black, location: 1 - fadeWidth / containerWidth),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            Color.black  // static text: no fades
        }
    }
    
    private func runScrollLoop() async {
        // offset starts at fadeWidth (set by the task before calling this)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(pauseDuration))
            guard !Task.isCancelled else { break }
            
            // Scroll left by (textWidth + gap). At the end:
            //   first copy  → off-screen left
            //   second copy → lands at x = fadeWidth  (same as the first copy's rest position)
            withAnimation(.linear(duration: cycleDuration)) {
                offset = fadeWidth - (textWidth + gap)
            }
            try? await Task.sleep(for: .seconds(cycleDuration))
            guard !Task.isCancelled else { break }
            
            // Reset: second copy is now at fadeWidth, identical to where the first was at rest.
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { offset = fadeWidth }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        MarqueeText(text: "Short Title", font: .headline)
            .frame(width: 200)
        
        MarqueeText(text: "A Very Long Title That Definitely Needs To Scroll Nicely", font: .headline)
            .frame(width: 200)
        
        MarqueeText(text: "Artist Name • Very Long Album Name That Also Scrolls", font: .subheadline)
            .foregroundStyle(.secondary)
            .frame(width: 200)
    }
    .padding()
    .frame(width: 300)
}
