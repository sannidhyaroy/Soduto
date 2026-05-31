//
//  MessageBubbleView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 17/05/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI
import AppKit

/// Single message bubble. Right-aligned blue for outgoing, left-aligned gray for
/// incoming. Group MMS threads show the sender name above the bubble. URLs, phone
/// numbers, and email addresses inside the body are auto-detected and rendered as
/// clickable links. A small timestamp sits under each bubble on the bubble's side.
struct MessageBubbleView: View {
    let message: SMSService.Message
    let model: SMSDataModel
    /// Whether the parent thread has multiple participants; drives sender name display on incoming bubbles.
    let isGroupThread: Bool
    /// Whether the previous message in the visual order is from the same sender (within the same minute).
    /// When true, the bubble is rendered tighter: no sender name, no extra spacing.
    let isContinuation: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.type.isFromMe {
                Spacer(minLength: 60)
                bubble
            } else {
                bubble
                Spacer(minLength: 60)
            }
        }
        .padding(.top, isContinuation ? 1 : 6)
    }
    
    @ViewBuilder
    private var bubble: some View {
        VStack(alignment: message.type.isFromMe ? .trailing : .leading, spacing: 2) {
            if !message.type.isFromMe && isGroupThread && !isContinuation {
                Text(model.displayName(for: message.addresses.first ?? ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
            }
            
            // Inline attachment thumbnails
            // Tapping an image thumbnail requests the full file via `SMSService` and swaps in the downloaded image inline once it lands; there's no external viewer or default-app open yet
            // Non-image attachments render as a static chip with no download action yet
            if !message.attachments.isEmpty {
                ForEach(message.attachments) { att in
                    AttachmentThumbnailView(attachment: att, model: model)
                }
            }
            
            // Body: suppress entirely when empty AND we rendered an attachment above (no empty pill under the thumbnail)
            // Wrapped in `NSTextView` so links get pointing-hand cursor + native right-click "Open Link / Copy Link" menu; SwiftUI's Text doesn't expose either of those affordances on macOS
            // The bubble hugs short text because `LinkifiedTextView`'s sizeThatFits returns the actual used text width; the HStack's `Spacer(minLength: 60)` provides the implicit max width for wrapping long messages
            if !message.body.isEmpty {
                LinkifiedTextView(
                    attributedString: Self.attributedBody(
                        message.body,
                        isOutgoing: message.type.isFromMe
                    ),
                    isOutgoing: message.type.isFromMe
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(bubbleFill)
                )
            }

            // Inline timestamp under the bubble on the bubble's side. Subtle so it
            // doesn't compete with the message content; chat-app standard.
            Text(Self.timeFormatter.string(from: message.date))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)

            if message.type == .failed {
                Text("Not delivered")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
            }
        }
    }

    private var bubbleFill: AnyShapeStyle {
        if message.type.isFromMe {
            return AnyShapeStyle(Color.accentColor)
        } else {
            return AnyShapeStyle(Color.secondary.opacity(0.18))
        }
    }
    
    /// Build an `NSAttributedString` for the message body with detectable URLs, phone numbers, and email addresses turned into clickable links.
    /// Used by the `LinkifiedTextView` (`NSTextView` wrapper) which renders links with the proper macOS affordances (pointer cursor, right-click context menu).
    static func attributedBody(_ string: String, isOutgoing: Bool) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 13)
        let baseColor: NSColor = isOutgoing ? .white : .controlTextColor
        let linkColor: NSColor = isOutgoing ? .white : .controlAccentColor
        
        let ns = NSMutableAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: baseColor
        ])
        let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return ns }
        let range = NSRange(location: 0, length: ns.length)
        for match in detector.matches(in: string, options: [], range: range) {
            var url: URL?
            if match.resultType == .link {
                url = match.url
            } else if match.resultType == .phoneNumber, let phone = match.phoneNumber {
                let stripped = phone.unicodeScalars
                    .filter { CharacterSet(charactersIn: "+0123456789").contains($0) }
                    .map { String($0) }.joined()
                if !stripped.isEmpty {
                    url = URL(string: "tel:\(stripped)")
                }
            }
            if let url {
                ns.addAttribute(.link, value: url, range: match.range)
                ns.addAttribute(.foregroundColor, value: linkColor, range: match.range)
                ns.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            }
        }
        return ns
    }
    
    /// Compact time-of-day format (24-hour by locale convention).
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}

/// Renders the inline thumbnail for a single MMS attachment with a four-state UX:
/// - **Idle**: blurred preview + circular download-arrow overlay (tap to download)
/// - **Downloading**: blurred preview + spinner overlay
/// - **Downloaded**: crisp preview, no blur, no overlay, no further interaction (the in-app viewer was scrapped, this is the final view)
/// - **Failed**: blurred preview + retry-arrow overlay (tap to retry)
///
/// Non-image attachments (audio/video/unknown MIME) skip the blur since we don't have a raster preview for them; they render as a small static chip with no download action yet.
///
/// Decoded thumbnails are cached in a process-wide `NSCache` keyed by attachment identifier so scrolling doesn't re-decode the same images repeatedly.
private struct AttachmentThumbnailView: View {
    let attachment: SMSService.MessageAttachment
    @ObservedObject var model: SMSDataModel
    
    var body: some View {
        if isImageAttachment {
            imageContent
        } else {
            nonImageChip
        }
    }
    
    // MARK: State
    
    private var downloadState: SMSService.AttachmentDownloadState? {
        model.attachmentStates[attachment.uniqueIdentifier]
    }
    
    private var isDownloading: Bool {
        if case .downloading = downloadState { return true }
        return false
    }
    
    private var downloadedURL: URL? {
        if case .downloaded(let url) = downloadState { return url }
        return nil
    }
    
    private var didFail: Bool {
        if case .failed = downloadState { return true }
        return false
    }
    
    private var isImageAttachment: Bool {
        attachment.mimeType.hasPrefix("image/")
    }
    
    // MARK: Image content
    //
    // Idle       → blurred base64 preview + download button (tap to download)
    // Downloading→ blurred base64 preview + spinner
    // Downloaded → full-resolution image loaded from the cached file (no interaction yet but an the in-app viewer is desirable)
    // Failed     → blurred base64 preview + retry button (tap to retry)
    
    @ViewBuilder
    private var imageContent: some View {
        if let url = downloadedURL, let fullImage = Self.loadFullImage(url) {
            // Final crisp render; purely display, no interactive overlay
            Image(nsImage: fullImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 280, maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        } else if let preview = decodedImage {
            // Blurred base64 thumbnail with download / spinner / retry overlay
            Image(nsImage: preview)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 220, maxHeight: 220)
                .blur(radius: 10)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .overlay(badgeOverlay)
                .overlay(
                    // Disabled while downloading so a double-tap doesn't queue duplicates
                    // Tap action covers both first-download AND retry-after-failure
                    ClickCatcher(isEnabled: !isDownloading, action: requestDownloadIfNeeded)
                )
                .animation(.easeInOut(duration: 0.2), value: downloadState)
        } else {
            // No base64 thumbnail at all (rare); fall back to the chip representation
            nonImageChip
        }
    }
    
    @ViewBuilder
    private var badgeOverlay: some View {
        if isDownloading {
            badgeBackground { SoftSpinner(diameter: 22, lineWidth: 2.5, color: .white) }
        } else if didFail {
            // Distinguishing retry-after-failure from first-download: red tint + a refresh-arrow glyph instead of the plain down arrow
            badgeBackground(tint: Color.red.opacity(0.65)) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }
        } else {
            badgeBackground {
                Image(systemName: "arrow.down")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }
    
    @ViewBuilder
    private func badgeBackground<Content: View>(
        tint: Color = Color.black.opacity(0.55),
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            Circle().fill(tint)
            content()
        }
        .frame(width: 48, height: 48)
        .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1)
    }
    
    @ViewBuilder
    private var nonImageChip: some View {
        HStack(spacing: 6) {
            if isDownloading {
                SoftSpinner(diameter: 12, lineWidth: 1.6, color: .secondary)
            } else {
                Image(systemName: attachmentSymbol)
            }
            Text(attachment.mimeType)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.18))
        )
    }
    
    /// Fires `requestAttachment` for first-download AND retry-after-failure.
    /// Already-downloaded files don't re-trigger (we just show the crisp image).
    private func requestDownloadIfNeeded() {
        guard !isDownloading else { return }
        guard downloadedURL == nil else { return }
        model.smsService.requestAttachment(
            partId: attachment.partId,
            uniqueIdentifier: attachment.uniqueIdentifier,
            mimeType: attachment.mimeType,
            device: model.device
        )
    }
    
    /// Lazily decode the full-resolution image from the cache file.
    /// Process-wide `NSCache` keyed by URL string keeps repeated reads (scroll, re-render) cheap.
    private static let fullImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 100 * 1024 * 1024
        cache.countLimit = 64
        return cache
    }()
    
    private static func loadFullImage(_ url: URL) -> NSImage? {
        let key = url.path as NSString
        if let cached = fullImageCache.object(forKey: key) { return cached }
        guard let img = NSImage(contentsOf: url) else { return nil }
        // Use 1 MB as a coarse "cost" since `NSImage.size` isn't a great memory proxy
        fullImageCache.setObject(img, forKey: key, cost: 1024 * 1024)
        return img
    }
    
    private var decodedImage: NSImage? {
        let key = "\(attachment.partId)|\(attachment.uniqueIdentifier)" as NSString
        if let cached = Self.thumbnailCache.object(forKey: key) {
            return cached
        }
        guard let b64 = attachment.encodedThumbnail else { return nil }
        guard attachment.mimeType.hasPrefix("image/") else { return nil }
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
        guard let img = NSImage(data: data) else { return nil }
        Self.thumbnailCache.setObject(img, forKey: key, cost: data.count)
        return img
    }
    
    private var attachmentSymbol: String {
        if attachment.mimeType.hasPrefix("audio/") { return "waveform" }
        if attachment.mimeType.hasPrefix("video/") { return "play.rectangle" }
        if attachment.mimeType.hasPrefix("image/") { return "photo" }
        return "paperclip"
    }
    
    /// Bounded by total byte cost; eviction kicks in around 50 MB across the process.
    /// Re-decoded thumbnails are cheap, so missing the cache isn't catastrophic.
    private static let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 50 * 1024 * 1024
        cache.countLimit = 256
        return cache
    }()
}

// MARK: - LinkifiedTextView

/// A thin `NSTextView` wrapper that renders an `NSAttributedString` with proper macOS link affordances: pointing-hand cursor over `.link` spans, native right-click context menu ("Open Link", "Copy Link"), single-click opens the URL.
/// Text outside links is selectable for normal copy/paste.
/// SwiftUI's `Text` doesn't expose any of these, so we delegate body rendering to AppKit for message bubbles that may contain URLs / phone numbers / emails.
private struct LinkifiedTextView: NSViewRepresentable {
    let attributedString: NSAttributedString
    let isOutgoing: Bool

    func makeNSView(context: Context) -> AutoSizingTextView {
        let textView = AutoSizingTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // `widthTracksTextView = false` so the container size we set inside `sizeThatFits`
        // (based on SwiftUI's proposed width) actually sticks during layout instead of
        // being overwritten by the view's frame width.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        // NSTextView already routes link clicks through NSWorkspace.open and shows the
        // native right-click context menu for link ranges — no extra wiring needed.
        return textView
    }
    
    func updateNSView(_ nsView: AutoSizingTextView, context: Context) {
        // Override NSTextView's default link styling per-bubble
        // Without this, links render in the system accent (blue) regardless of the colour we baked into the NSAttributedString; that produced blue-on-blue links inside outgoing (accent-coloured) bubbles, killing contrast
        nsView.linkTextAttributes = [
            .foregroundColor: isOutgoing ? NSColor.white : NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        // Cheap guard against re-replacing identical text (would clear any in-progress
        // mouse selection mid-drag).
        if nsView.textStorage?.string != attributedString.string {
            nsView.textStorage?.setAttributedString(attributedString)
        }
        nsView.invalidateIntrinsicContentSize()
    }

    /// Tell SwiftUI the bubble's actual text size given the proposed max width.
    /// Without this, NSTextView greedily fills the proposed width — so even a single
    /// "Hello" produces a full-width bubble. With this, the bubble hugs short text
    /// and only wraps when content actually exceeds the proposed width.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: AutoSizingTextView,
                      context: Context) -> CGSize? {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        nsView.textContainer?.containerSize = NSSize(width: maxWidth,
                                                     height: .greatestFiniteMagnitude)
        guard let container = nsView.textContainer,
              let layoutManager = nsView.layoutManager else { return nil }
        _ = layoutManager.glyphRange(for: container)
        let used = layoutManager.usedRect(for: container)
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }
}

/// NSTextView subclass that reports the laid-out text bounds as its intrinsic content
/// height so SwiftUI's auto-sizing produces a bubble that hugs the text vertically.
/// Width comes from SwiftUI's proposed size (the bubble's HStack constraint).
private final class AutoSizingTextView: NSTextView {

    override var intrinsicContentSize: NSSize {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(used.height))
    }
    
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Width changed → text rewraps → height may change → tell AutoLayout
        invalidateIntrinsicContentSize()
    }

    /// Keep the bubble from stealing keyboard focus when the user clicks it for selection.
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }
}

// MARK: - ClickCatcher

/// Thin overlay NSView that handles `mouseDown` directly in AppKit.
/// Used to bypass SwiftUI's lazy hit-test machinery for clickable images inside a `LazyVStack`: those hit-test regions go stale after a `NavigationSplitView` sidebar toggle and don't recover until the user scrolls.
/// The `NSView`'s hit testing always works because it's part of AppKit's regular view hierarchy.
private struct ClickCatcher: NSViewRepresentable {
    var isEnabled: Bool = true
    let action: () -> Void
    
    func makeNSView(context: Context) -> ClickCatcherNSView {
        let view = ClickCatcherNSView()
        view.action = action
        view.isEnabled = isEnabled
        return view
    }
    
    func updateNSView(_ view: ClickCatcherNSView, context: Context) {
        view.action = action
        view.isEnabled = isEnabled
    }
    
    final class ClickCatcherNSView: NSView {
        var action: (() -> Void)?
        var isEnabled: Bool = true
        
        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        
        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            action?()
        }
    }
}

