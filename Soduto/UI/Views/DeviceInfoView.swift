//
//  DeviceInfoView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 22/02/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

// MARK: - Device Info View

struct DeviceInfoView: View {
    let device: Device
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)
            
            Divider()
            
            // Content
            ScrollView {
                VStack(spacing: 24) {
                    generalSection
                    certificatesSection
                }
                .padding(20)
            }
            
            Divider()
            
            // Footer
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 500, height: 350)
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: device.type.sfSymbolName)
                .font(.system(size: 32))
                .foregroundColor(.primary)
                .frame(width: 40, height: 40)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                HStack(spacing: 4) {
                    Text(deviceTypeString(device.type))
                    Text("•")
                        .foregroundColor(.secondary)
                    Text(device.isReachable ? "reachable" : "unreachable")
                        .foregroundColor(device.isReachable ? .green : .secondary)
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
    
    // MARK: - General Section
    
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "General")
            
            infoRow(label: "Device ID", value: device.id, monospaced: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // MARK: - Certificates Section
    
    private var certificatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Certificate Fingerprints")
            
            if let remoteCert = device.peerCertificate {
                let remoteFingerprint = CertificateUtils.sha256FormattedDigestString(for: remoteCert)
                infoRow(label: "Remote - SHA256", value: remoteFingerprint, monospaced: true)
            } else {
                infoRow(label: "Remote - SHA256", value: "Not available", monospaced: true)
            }
            
            if let localCert = device.hostCertificate {
                let localFingerprint = CertificateUtils.sha256FormattedDigestString(for: localCert)
                infoRow(label: "Local - SHA256", value: localFingerprint, monospaced: true)
            } else {
                infoRow(label: "Local - SHA256", value: "Not available", monospaced: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // MARK: - Helper Views
    
    private func sectionHeader(title: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            
            Divider()
        }
    }
    
    private func infoRow(label: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    private func deviceTypeString(_ type: DeviceType) -> String {
        switch type {
        case .Desktop: return "Desktop"
        case .Laptop: return "Laptop"
        case .Phone: return "Phone"
        case .Tablet: return "Tablet"
        case .TV: return "TV"
        case .Unknown: return "Unknown"
        }
    }
}

// MARK: - Preview

#Preview {
    // Can't create Device without complex dependencies, so preview won't work
    // This is fine - we'll test in the actual app
    Text("Preview not available - needs Device instance")
        .frame(width: 500, height: 350)
}
