//
//  RunCommandsView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 11/05/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

// MARK: - Identifiable

extension RunCommandService.Command: Identifiable {
    public var id: String { uuid }
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
    
    var body: some View {
        Group {
            if viewModel.commands.isEmpty {
                emptyState
            } else {
                commandList
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .toolbar {
            if viewModel.isSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { viewModel.dismissSheet?() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showingAddSheet = true } label: {
                    Image(systemName: "plus")
                }
                .help("Add Command")
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            CommandEditView(title: "New Command", name: "", command: "") { name, command in
                viewModel.add(.init(uuid: UUID().uuidString, name: name, command: command))
            }
        }
        .sheet(item: $editingCommand) { command in
            CommandEditView(title: "Edit Command", name: command.name, command: command.command) { name, cmd in
                var updated = command
                updated.name = name
                updated.command = cmd
                viewModel.update(updated)
            }
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
                CommandRow(command: command) {
                    editingCommand = command
                } onDelete: {
                    viewModel.delete(command)
                }
            }
            .onDelete { viewModel.delete(at: $0) }
        }
        .listStyle(.inset)
    }
}

// MARK: - CommandRow

private struct CommandRow: View {
    let command: RunCommandService.Command
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name)
                    .fontWeight(.medium)
                Text(command.command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            
            Spacer()
            
            HStack(spacing: 4) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Edit")
                
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.vertical, 4)
        .onHover { isHovered = $0 }
    }
}

// MARK: - CommandEditView

private struct CommandEditView: View {
    let title: String
    @State private var name: String
    @State private var command: String
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    
    init(title: String, name: String, command: String, onSave: @escaping (String, String) -> Void) {
        self.title = title
        self._name = State(initialValue: name)
        self._command = State(initialValue: command)
        self.onSave = onSave
    }
    
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Name")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    TextField("e.g. Update packages", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .leading, spacing: 5) {
                    Text("Shell Command")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    TextField("e.g. brew upgrade", text: $command)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .padding(24)
            
            Divider()
            
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(
                        name.trimmingCharacters(in: .whitespacesAndNewlines),
                        command.trimmingCharacters(in: .whitespacesAndNewlines)
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
        .frame(width: 420)
    }
}

// MARK: - Preview

#Preview {
    let vm = RunCommandsViewModel()
    vm.commands = [
        .init(uuid: "1", name: "Update Homebrew", command: "brew update && brew upgrade"),
        .init(uuid: "2", name: "Sleep", command: "pmset sleepnow"),
        .init(uuid: "3", name: "Lock Screen", command: "/System/Library/CoreServices/Menu\\ Extras/User.menu/Contents/Resources/CGSession -suspend"),
    ]
    return RunCommandsView(viewModel: vm)
}
