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
    case outgoingRequest      // We initiated pairing, waiting for response
    case incomingRequest      // Remote device requested pairing
    case success              // Pairing completed successfully
    case failed(String)       // Pairing failed with error message
    case timeout              // Pairing request timed out
}

// MARK: - Pairing View Model

@MainActor
class PairingViewModel: ObservableObject {
    @Published var state: PairingState
    @Published var deviceName: String
    @Published var deviceType: DeviceType
    @Published var verificationCode: String?
    
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
        self.state = state
    }
    
    /// Initialize without a Device (for previews/testing)
    init(deviceName: String, deviceType: DeviceType, verificationCode: String?, state: PairingState) {
        self.device = nil
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.verificationCode = verificationCode
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
                .frame(height: 24)
            
            // Soduto app icon
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .frame(width: 64, height: 64)
            
            Spacer()
                .frame(height: 16)
            
            // Device info row
            HStack(spacing: 8) {
                Image(systemName: viewModel.deviceType.sfSymbolName)
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                
                Text(titleText)
                    .font(.headline)
            }
            
            Spacer()
                .frame(height: 24)
            
            // Content based on state
            contentView
            
            Spacer()
                .frame(height: 24)
            
            // Action buttons
            actionButtons
            
            Spacer()
                .frame(height: 20)
        }
        .frame(width: 320)
        .padding(.horizontal, 24)
        .onChange(of: viewModel.state) { _, newState in
            handleStateChange(newState)
        }
    }
    
    // MARK: - Title Text
    
    private var titleText: String {
        switch viewModel.state {
        case .outgoingRequest:
            return "Pairing with \(viewModel.deviceName)"
        case .incomingRequest:
            return "\(viewModel.deviceName) wants to pair"
        case .success:
            return "Paired with \(viewModel.deviceName)"
        case .failed, .timeout:
            return "Pairing with \(viewModel.deviceName)"
        }
    }
    
    // MARK: - Content View
    
    @ViewBuilder
    private var contentView: some View {
        switch viewModel.state {
        case .outgoingRequest, .incomingRequest:
            verificationCodeView
        case .success:
            successView
        case .failed(let message):
            failedView(message: message)
        case .timeout:
            failedView(message: "Request timed out")
        }
    }
    
    // MARK: - Verification Code View
    
    @ViewBuilder
    private var verificationCodeView: some View {
        VStack(spacing: 12) {
            Text("Verification Code")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            if let code = viewModel.verificationCode {
                Text(code)
                    .font(.system(size: 28, weight: .medium, design: .monospaced))
                    .tracking(2)
            } else {
                Text("---")
                    .font(.system(size: 28, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            Text("Confirm this matches the other device")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    // MARK: - Success View
    
    @ViewBuilder
    private var successView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            
            Text("Paired successfully!")
                .font(.headline)
                .foregroundColor(.primary)
        }
    }
    
    // MARK: - Failed View
    
    @ViewBuilder
    private func failedView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.red)
            
            Text("Pairing failed")
                .font(.headline)
                .foregroundColor(.primary)
            
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    // MARK: - Action Buttons
    
    @ViewBuilder
    private var actionButtons: some View {
        switch viewModel.state {
        case .outgoingRequest:
            Button("Cancel Pairing") {
                viewModel.cancel()
            }
            .keyboardShortcut(.cancelAction)
            
        case .incomingRequest:
            HStack(spacing: 12) {
                Button("Decline") {
                    viewModel.decline()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Accept") {
                    viewModel.accept()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            
        case .success:
            Button("Done") {
                viewModel.dismiss()
            }
            .keyboardShortcut(.defaultAction)
            
        case .failed, .timeout:
            Button("Close") {
                viewModel.dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
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
        state: .outgoingRequest
    ))
}

#Preview("Incoming Request") {
    PairingView(viewModel: PairingViewModel(
        deviceName: "Galaxy S24",
        deviceType: .Phone,
        verificationCode: "A1B2 C3D4",
        state: .incomingRequest
    ))
}

#Preview("Success") {
    PairingView(viewModel: PairingViewModel(
        deviceName: "Galaxy S24",
        deviceType: .Phone,
        verificationCode: nil,
        state: .success
    ))
}

#Preview("Failed") {
    PairingView(viewModel: PairingViewModel(
        deviceName: "Galaxy S24",
        deviceType: .Phone,
        verificationCode: nil,
        state: .failed("Connection was rejected")
    ))
}
