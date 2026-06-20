//
//  RunCommandsView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 11/05/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI
import os

// MARK: - Identifiable

extension RunCommandService.Command: Identifiable {
    public var id: String { uuid }
}

// MARK: - ShellRegistry

/// Discovers shells available on the system from three merged sources:
///   1. Hard-coded important macOS-bundled shells: always shipped with macOS, robust
///      against any App Sandbox restriction
///   2. `/etc/shells`: picks up shells the user has registered via `chsh`
///   3. Probes of common third-party install paths: catches Homebrew/MacPorts
///      shells (notably fish) that the user installed but never `chsh`'d into
///      `/etc/shells`
///
/// Duplicate paths are deduplicated; multiple distinct paths for the same
/// shell name (e.g. fish installed by both Homebrew and MacPorts) appear
/// as separate picker entries so the user can choose the exact binary
private enum ShellRegistry {
    
    /// Shells macOS always ships in `/bin`
    private static let bundled = [
        "/bin/sh",
        "/bin/bash",
        "/bin/zsh"
    ]
    
    /// Install-prefix directories where third-party package managers place shells
    private static let thirdPartyPrefixes = [
        "/opt/homebrew/bin",  // Homebrew on Apple Silicon
        "/usr/local/bin",     // Homebrew on Intel, also common manual installs
        "/opt/local/bin"      // MacPorts
    ]
    
    /// Popular third-party shells to probe inside `thirdPartyPrefixes`
    private static let thirdPartyShells = ["fish", "nu", "elvish", "xonsh"]
    
    static func discover() -> [String] {
        var paths = Set<String>()
        
        for path in bundled where FileManager.default.fileExists(atPath: path) {
            paths.insert(path)
        }
        
        do {
            let contents = try String(contentsOfFile: "/etc/shells", encoding: .utf8)
            var fromEtc: [String] = []
            for line in contents.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                guard FileManager.default.fileExists(atPath: trimmed) else {
                    Logger.ui.debug("ShellRegistry: /etc/shells lists \(trimmed, privacy: .public) but file does not exist")
                    continue
                }
                fromEtc.append(trimmed)
                paths.insert(trimmed)
            }
            Logger.ui.debug("ShellRegistry: /etc/shells read OK, added \(fromEtc.count, privacy: .public) entries: \(fromEtc, privacy: .public)")
        } catch {
            Logger.ui.error("ShellRegistry: failed to read /etc/shells: \(error, privacy: .public)")
        }
        
        for prefix in thirdPartyPrefixes {
            for shell in thirdPartyShells {
                let path = "\(prefix)/\(shell)"
                if FileManager.default.fileExists(atPath: path) {
                    paths.insert(path)
                }
            }
        }
        
        Logger.ui.debug("ShellRegistry: discovered \(paths.count, privacy: .public) total shells: \(paths.sorted(), privacy: .public)")
        return paths.sorted()
    }
}

// MARK: - RunCommandsViewModel

@MainActor
final class RunCommandsViewModel: ObservableObject {
    @Published var commands: [RunCommandService.Command] = []
    @Published var isSheet = false
    
    weak var delegate: RunCommandsWindowControllerDelegate?
    var dismissSheet: (() -> Void)?
    
    func reload() {
        commands = delegate?.getLocalCommands() ?? []
    }
    
    func add(_ command: RunCommandService.Command) {
        commands.append(command)
        save()
    }
    
    func update(_ command: RunCommandService.Command) {
        guard let index = commands.firstIndex(where: { $0.uuid == command.uuid }) else { return }
        commands[index] = command
        save()
    }
    
    func duplicate(_ command: RunCommandService.Command) {
        let copy = RunCommandService.Command(
            uuid: UUID().uuidString,
            name: "Copy of " + command.name,
            command: command.command,
            shell: command.shell,
            isEnabled: command.isEnabled
        )
        if let index = commands.firstIndex(where: { $0.uuid == command.uuid }) {
            commands.insert(copy, at: index + 1)
        } else {
            commands.append(copy)
        }
        save()
    }
    
    func setEnabled(_ enabled: Bool, for command: RunCommandService.Command) {
        guard let index = commands.firstIndex(where: { $0.uuid == command.uuid }) else { return }
        commands[index].isEnabled = enabled
        save()
    }
    
    func delete(_ command: RunCommandService.Command) {
        commands.removeAll { $0.uuid == command.uuid }
        save()
    }
    
    func delete(at offsets: IndexSet) {
        commands.remove(atOffsets: offsets)
        save()
    }
    
    private func save() {
        delegate?.saveLocalCommands(commands)
    }
}

// MARK: - RunCommandsView

struct RunCommandsView: View {
    @ObservedObject var viewModel: RunCommandsViewModel
    @State private var showingAddSheet = false
    @State private var editingCommand: RunCommandService.Command?
    @State private var commandPendingDelete: RunCommandService.Command?
    
    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            
            Group {
                if viewModel.commands.isEmpty {
                    emptyState
                } else {
                    commandList
                }
            }
            
            if viewModel.isSheet {
                Divider()
                footerBar
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .sheet(isPresented: $showingAddSheet) {
            CommandEditView(
                title: "New Command",
                name: "",
                command: "",
                shell: RunCommandService.Command.defaultShell,
                onSave: { name, command, shell in
                    viewModel.add(.init(uuid: UUID().uuidString, name: name, command: command, shell: shell))
                },
                onDelete: nil
            )
        }
        .sheet(item: $editingCommand) { command in
            CommandEditView(
                title: "Edit Command",
                name: command.name,
                command: command.command,
                shell: command.shell,
                onSave: { name, cmd, shell in
                    var updated = command
                    updated.name = name
                    updated.command = cmd
                    updated.shell = shell
                    viewModel.update(updated)
                },
                onDelete: {
                    viewModel.delete(command)
                }
            )
        }
        .confirmationDialog(
            commandPendingDelete.map { "Delete '\($0.name)'?" } ?? "",
            isPresented: Binding(
                get: { commandPendingDelete != nil },
                set: { if !$0 { commandPendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: commandPendingDelete
        ) { command in
            Button("Delete", role: .destructive) {
                viewModel.delete(command)
                commandPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                commandPendingDelete = nil
            }
        } message: { _ in
            Text("This action cannot be undone.")
        }
    }
    
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Commands", systemImage: "terminal")
        } description: {
            Text("Add shell commands to run them remotely from connected devices.")
        } actions: {
            Button("Add Command") { showingAddSheet = true }
                .buttonStyle(.borderedProminent)
        }
    }
    
    private var commandList: some View {
        List {
            ForEach(viewModel.commands) { command in
                CommandRow(
                    command: command,
                    onEdit: { editingCommand = command },
                    onDuplicate: { viewModel.duplicate(command) },
                    onDelete: { commandPendingDelete = command },
                    onToggleEnabled: { enabled in
                        viewModel.setEnabled(enabled, for: command)
                    }
                )
            }
            .onDelete { viewModel.delete(at: $0) }
        }
        .listStyle(.inset)
    }
    
    private var headerBar: some View {
        HStack {
            Text("Run Commands")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Button {
                showingAddSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help("Add Command")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
    
    private var footerBar: some View {
        HStack {
            Spacer()
            Button("Done") {
                viewModel.dismissSheet?()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - CommandRow

private struct CommandRow: View {
    let command: RunCommandService.Command
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onToggleEnabled: (Bool) -> Void
    
    private var enabledBinding: Binding<Bool> {
        Binding(get: { command.isEnabled }, set: { onToggleEnabled($0) })
    }
    
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                iconBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.name)
                        .fontWeight(.medium)
                    Text(command.command)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .opacity(command.isEnabled ? 1 : 0.55)
            
            Spacer()
            
            Toggle("", isOn: enabledBinding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(command.isEnabled ? "Disable command" : "Enable command")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            onEdit()
        }
        .contextMenu {
            Button("Edit") { onEdit() }
            Button("Duplicate") { onDuplicate() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }
    
    /// macOS Settings-style icon: a small rounded square with a subtle vertical
    /// gradient and the SF Symbol in white. When per-command custom icons are
    /// added later, the symbol name and tint will become Command properties
    private var iconBadge: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(LinearGradient(
                colors: [Color(white: 0.5), Color(white: 0.36)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .frame(width: 28, height: 28)
            .overlay {
                Image(systemName: "terminal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
            }
    }
}

// MARK: - CommandEditView

private struct CommandEditView: View {
    let title: String
    @State private var name: String
    @State private var command: String
    @State private var shell: String
    @State private var showingDeleteConfirmation = false
    let onSave: (String, String, String) -> Void
    let onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    
    private let availableShells: [String] = ShellRegistry.discover()
    
    init(
        title: String,
        name: String,
        command: String,
        shell: String,
        onSave: @escaping (String, String, String) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.title = title
        self._name = State(initialValue: name)
        self._command = State(initialValue: command)
        self._shell = State(initialValue: shell)
        self.onSave = onSave
        self.onDelete = onDelete
    }
    
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    /// Shells offered in the picker
    /// Ensure the command's current shell is always selectable even if it disappears from /etc/shells (e.g. fish uninstalled)
    private var shellOptions: [String] {
        availableShells.contains(shell) ? availableShells : (availableShells + [shell]).sorted()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Name")
                    TextField("e.g. Sleep", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Shell")
                    Picker("", selection: $shell) {
                        ForEach(shellOptions, id: \.self) { path in
                            Text(path).tag(path)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Command")
                    terminalField
                }
            }
            .padding(24)
            
            Divider()
            
            HStack {
                if onDelete != nil {
                    Button("Delete", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(
                        name.trimmingCharacters(in: .whitespacesAndNewlines),
                        command.trimmingCharacters(in: .whitespacesAndNewlines),
                        shell
                    )
                    dismiss()
                }
                .disabled(!isValid)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 460)
        .confirmationDialog(
            "Delete '\(name)'?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }
    
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
    }
    
    /// Dark terminal-style multiline editor.
    /// The `ShellEditorView` draws the `$` prompt gutter and handles text editing; this wrapper supplies the dark rounded background and border chrome
    private var terminalField: some View {
        ShellEditorView(text: $command, placeholder: "e.g. pmset sleepnow")
            .frame(minHeight: 90, maxHeight: 140)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

// MARK: - Preview

#Preview {
    let vm = RunCommandsViewModel()
    vm.commands = [
        .init(uuid: "1", name: "Update Homebrew", command: "brew update && brew upgrade"),
        .init(uuid: "2", name: "Sleep", command: "pmset sleepnow", isEnabled: false),
        .init(uuid: "3", name: "Lock Screen", command: "/System/Library/CoreServices/Menu\\ Extras/User.menu/Contents/Resources/CGSession -suspend"),
    ]
    return RunCommandsView(viewModel: vm)
}
