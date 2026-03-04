//
//  PairingView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 22/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

// MARK: - Pairing State

enum PairingState: Equatable {
    case outgoingRequest      // Initiated pairing, waiting for response
    case incomingRequest      // Remote device requested pairing
    case success              // Pairing completed successfully
    case failed               // Pairing failed
    case timeout              // Pairing request timed out
}

// MARK: - Pairing View Model

@MainActor
class PairingViewModel: ObservableObject {
    @Published var state: PairingState
    @Published var deviceName: String
    @Published var deviceType: DeviceType
    @Published var verificationCode: String?
    @Published var peerProtocolVersion: UInt?
    
    weak var device: Device?
    var onAccept: (() -> Void)?
    var onDecline: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDismiss: (() -> Void)?
    
    /// Initialize with a Device
    init(device: Device, state: PairingState) {
        self.device = device
        self.deviceName = device.name
        self.deviceType = device.type
        self.verificationCode = device.verificationCode
        self.peerProtocolVersion = device.protocolVersion
        self.state = state
    }
    
    /// Initialize without a Device (for previews/testing)
    init(deviceName: String, deviceType: DeviceType, verificationCode: String?, peerProtocolVersion: UInt? = nil, state: PairingState) {
        self.device = nil
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.verificationCode = verificationCode
        self.peerProtocolVersion = peerProtocolVersion
        self.state = state
    }
    
    func accept() {
        onAccept?()
    }
    
    func decline() {
        onDecline?()
    }
    
    func cancel() {
        onCancel?()
    }
    
    func dismiss() {
        onDismiss?()
    }
}

// MARK: - Pairing View

struct PairingView: View {
    @ObservedObject var viewModel: PairingViewModel
    @State private var autoCloseTask: Task<Void, Never>?
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: 10)

            // Status icon or device info based on state
            statusSection

            Spacer()
                .frame(height: 22)

            // Content based on state
            contentView

            Spacer()
                .frame(height: spacingBeforeButtons)

            // Action buttons
            actionButtons
                .frame(maxWidth: .infinity)

            Spacer()
                .frame(height: spacingAfterButtons)
        }
        .frame(maxWidth: 280)
        .padding(.horizontal, 24)
        .onChange(of: viewModel.state) { _, newState in
            handleStateChange(newState)
        }
        .onDisappear {
            autoCloseTask?.cancel()
            autoCloseTask = nil
        }
    }
    
    private var spacingBeforeButtons: CGFloat {
        viewModel.state == .incomingRequest ? 20 : 24
    }
    
    private var spacingAfterButtons: CGFloat {
        viewModel.state == .incomingRequest ? 32 : 24
    }
    
    // MARK: - Status Section
    
    @ViewBuilder
    private var statusSection: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                // Soduto app icon
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .frame(width: 56, height: 56)
                
                // Status badge
                if viewModel.state == .success {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.green)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 24, height: 24))
                } else if case .failed = viewModel.state {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.red)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 24, height: 24))
                } else if case .timeout = viewModel.state {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.red)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 24, height: 24))
                }
            }
            
            HStack(spacing: 6) {
                Image(systemName: viewModel.deviceType.sfSymbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)

                Text(titleText)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
    
    // MARK: - Title Text
    
    private var titleText: String {
        switch viewModel.state {
        case .outgoingRequest:
            return "Waiting for \(viewModel.deviceName)"
        case .incomingRequest:
            return "\(viewModel.deviceName) wants to pair"
        case .success:
            return viewModel.deviceName
        case .failed:
            return viewModel.deviceName
        case .timeout:
            return viewModel.deviceName
        }
    }
    
    // MARK: - Content View
    
    @ViewBuilder
    private var contentView: some View {
        switch viewModel.state {
        case .outgoingRequest, .incomingRequest:
            verificationCodeView
        case .success:
            successMessageView
        case .failed, .timeout:
            errorMessageView
        }
    }
    
    // MARK: - Verification Code View
    
    @ViewBuilder
    private var verificationCodeView: some View {
        VStack(spacing: 16) {
            // Show verification code if available
            if let code = viewModel.verificationCode {
                VStack(spacing: 12) {
                    Text("Verification Code")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)

                    Text(code)
                        .font(.system(size: 36, weight: .semibold, design: .monospaced))
                        .tracking(3)
                        .lineLimit(1)

                    Text("Confirm this matches the other device")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Color.green.opacity(0.08))
                .cornerRadius(10)
            } else {
                // Generation failed
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)

                        Text("Manual Verification")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }

                    Text("Verification code generation failed. Accept only if you trust this device")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(10)
            }

            // Protocol version warnings (show regardless of code generation)
            if isOlderProtocol {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundColor(.red)
                        .font(.caption2)

                    Text("This device uses an older protocol version which may be less secure")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color.red.opacity(0.1))
                .cornerRadius(6)
            }

            if isFutureProtocol {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundColor(.blue)
                        .font(.caption2)

                    Text("This device uses a newer protocol version that may not be compatible with Soduto")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(6)
            }
        }
    }
    
    // MARK: - Success Message View
    
    @ViewBuilder
    private var successMessageView: some View {
        VStack(spacing: 8) {
            Text("Secure pairing completed successfully")
                .font(.subheadline)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
            
            Text("You can now send and receive data with this device")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Error Message View
    
    @ViewBuilder
    private var errorMessageView: some View {
        if case .failed = viewModel.state {
            VStack(spacing: 8) {
                Text("The peer device rejected this pairing request")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
            }
        } else if case .timeout = viewModel.state {
            VStack(spacing: 8) {
                Text("The pairing request timed out. Make sure the other device is online and accepting connections")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
            }
        }
    }
    
    // MARK: - Action Buttons
    
    @ViewBuilder
    private var actionButtons: some View {
        switch viewModel.state {
        case .outgoingRequest:
            Button(role: .cancel) {
                viewModel.cancel()
            } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 42)
            .controlSize(.large)
            
        case .incomingRequest:
            VStack(spacing: 10) {
                Button {
                    viewModel.accept()
                } label: {
                    Text("Accept")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .controlSize(.large)
                
                Button(role: .cancel) {
                    viewModel.decline()
                } label: {
                    Text("Decline")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity)
            
        case .success:
            Button {
                viewModel.dismiss()
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, minHeight: 42)
            .controlSize(.large)
            
        case .failed, .timeout:
            Button(role: .destructive) {
                viewModel.dismiss()
            } label: {
                Text("Close")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .frame(maxWidth: .infinity, minHeight: 42)
            .controlSize(.large)
        }
    }
    
    // MARK: - Protocol Version Helpers

    private var isOlderProtocol: Bool {
        guard let version = viewModel.peerProtocolVersion else { return false }
        return version < DataPacket.protocolVersion
    }

    private var isFutureProtocol: Bool {
        guard let version = viewModel.peerProtocolVersion else { return false }
        return version > DataPacket.protocolVersion
    }
    
    // MARK: - State Change Handler
    
    private func handleStateChange(_ newState: PairingState) {
        autoCloseTask?.cancel()
        
        if case .success = newState {
            // Auto-close after 2 seconds on success
            autoCloseTask = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled {
                    viewModel.dismiss()
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Outgoing Request") {
    PairingView(viewModel: PairingViewModel(
        deviceName: "Galaxy S24",
        deviceType: .Phone,
        verificationCode: "A1B2 C3D4",
        peerProtocolVersion: 8,
        state: .outgoingRequest
    ))
}

#Preview("Incoming Request") {
    PairingView(viewModel: PairingViewModel(
        deviceName: "ThinkStation",
        deviceType: .Desktop,
        verificationCode: "X1Y2 Z3W4",
        peerProtocolVersion: 8,
        state: .incomingRequest
    ))
}

#Preview("Incoming Request (Future Protocol)") {
    PairingView(viewModel: PairingViewModel(
        deviceName: "Shiny PC",
        deviceType: .Desktop,
        verificationCode: "X1Y1 Z3W4",
        peerProtocolVersion: 9,
        state: .incomingRequest
    ))
}

#Preview("Incoming Request (Older Protocol)") {
    PairingView(viewModel: PairingViewModel(
        deviceName: "Potato PC",
        deviceType: .Unknown,
        verificationCode: "X1Y2 Z3W4",
        peerProtocolVersion: 7,
        state: .incomingRequest
    ))
}

#Preview("Success") {
    PairingView(viewModel: PairingViewModel(
        deviceName: "ThinkPad T14",
        deviceType: .Laptop,
        verificationCode: nil,
        peerProtocolVersion: 8,
        state: .success
    ))
}

#Preview("Failed") {
    PairingView(viewModel: PairingViewModel(
        deviceName: "Sony Bravia",
        deviceType: .TV,
        verificationCode: nil,
        peerProtocolVersion: 8,
        state: .failed
    ))
}

#Preview("Timeout") {
    PairingView(viewModel: PairingViewModel(
        deviceName: "Pixel 9",
        deviceType: .Phone,
        verificationCode: nil,
        peerProtocolVersion: 8,
        state: .timeout
    ))
}

#Preview("Manual Verification") {
    PairingView(viewModel: PairingViewModel(
        deviceName: "iPad",
        deviceType: .Tablet,
        verificationCode: nil,
        peerProtocolVersion: 8,
        state: .incomingRequest
    ))
}
