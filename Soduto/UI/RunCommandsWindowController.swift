//
//  RunCommandsWindowController.swift
//  Soduto
//
//  Created on 2025-04-19.
//  Copyright © 2025 Soduto. All rights reserved.
//

import Cocoa

// MARK: - RunCommandsWindowControllerDelegate

protocol RunCommandsWindowControllerDelegate: AnyObject {
    func getLocalCommands() -> [RunCommandService.Command]?
    func saveLocalCommands(_ commands: [RunCommandService.Command])
}

// MARK: - RunCommandsWindowController

class RunCommandsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    
    // Toolbar identifier
    private let toolbarIdentifier = NSToolbar.Identifier("RunCommandsToolbar")
    private let addToolbarItemIdentifier = NSToolbarItem.Identifier("AddCommand")
    
    weak var delegate: RunCommandsWindowControllerDelegate?
    private var commands: [RunCommandService.Command] = []
    private var selectedCommandIndex: Int? = nil
    private var isEditingNewCommand = false
    
    // UI Elements
    private var scrollView: NSScrollView!
    private var stackView: NSStackView!
    private var emptyStateView: NSView!
    private var nameField: NSTextField!
    private var commandField: NSTextField!
    private var formContainer: NSView!
    
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Run Commands"
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = false
        window.center()
        
        self.init(window: window)
        setupToolbar()
        setupUI()
        loadCommands()
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
        loadCommands()
    }
    
    override func showWindow(_ sender: Any?) {
        // Load commands explicitly before showing the window
        loadCommands()
        
        super.showWindow(sender)
        
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(sender)
    }
    
    // MARK: - Toolbar Setup
    
    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = true
        window?.toolbar = toolbar
    }
    
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == addToolbarItemIdentifier {
            let toolbarItem = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 32, height: 28))
            button.bezelStyle = .regularSquare
            button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.isBordered = true
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.masksToBounds = true
            button.target = self
            button.action = #selector(addCommand)
            
            // Set up the toolbar item
            toolbarItem.view = button
            toolbarItem.label = "Add"
            toolbarItem.toolTip = "Add a new command"
            
            return toolbarItem
        }
        return nil
    }
    
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [addToolbarItemIdentifier]
    }
    
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [addToolbarItemIdentifier]
    }
    
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return []
    }
    
    // MARK: - UI Setup
    
    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        
        // Main container
        let mainStackView = NSStackView()
        mainStackView.translatesAutoresizingMaskIntoConstraints = false
        mainStackView.orientation = .vertical
        mainStackView.spacing = 16
        mainStackView.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 0, right: 24) // Remove bottom padding to allow scrollview to extend
        mainStackView.detachesHiddenViews = true  // This ensures hidden views don't take up space
        contentView.addSubview(mainStackView)
        
        // Scroll view for commands list
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        
        // Important: Make the stack view a flipped view so items start from the top
        class FlippedStackView: NSStackView {
            override var isFlipped: Bool { return true }
        }
        
        // Create stackView with flipped coordinates
        stackView = FlippedStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.spacing = 8
        stackView.alignment = .width
        stackView.distribution = .gravityAreas
        
        // Set as document view for scrollView
        scrollView.documentView = stackView
        
        // Add fixed top spacing directly to scroll view
        let clipView = scrollView.contentView
        clipView.automaticallyAdjustsContentInsets = false
        clipView.contentInsets = NSEdgeInsets(top: 42, left: 0, bottom: 16, right: 0)
        
        // Set vertical constraints to ensure stackView fills the scroll view content
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
        
        // Empty state view
        emptyStateView = createEmptyStateView()
        emptyStateView.isHidden = true
        
        // Create a container for form entry - will be added to stackView dynamically
        formContainer = createFormContainer()
        
        // Add views to main stack
        mainStackView.addArrangedSubview(scrollView)
        mainStackView.addArrangedSubview(emptyStateView)
        
        // Setup constraints
        NSLayoutConstraint.activate([
            mainStackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            mainStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            mainStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            mainStackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            
            // Remove height constraint on scrollView to allow full extension
            scrollView.widthAnchor.constraint(equalTo: mainStackView.widthAnchor),
            
            // Make scrollView and emptyStateView fill the main stack view
            scrollView.bottomAnchor.constraint(equalTo: mainStackView.bottomAnchor)
        ])
    }
    
    private func createFormContainer() -> NSView {
        // Create a margin container to wrap the form
        let marginContainer = NSView()
        marginContainer.translatesAutoresizingMaskIntoConstraints = false
        
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        
        container.layer?.cornerRadius = 8
        container.layer?.borderWidth = 1
        
        // Add container to margin container with spacing
        marginContainer.addSubview(container)
        
        // Set margin constraints (8px on each side)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: marginContainer.topAnchor, constant: 2),
            container.leadingAnchor.constraint(equalTo: marginContainer.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(equalTo: marginContainer.trailingAnchor, constant: -16),
            container.bottomAnchor.constraint(equalTo: marginContainer.bottomAnchor, constant: -2)
        ])
        
        // Form fields container
        let formStackView = NSStackView()
        formStackView.translatesAutoresizingMaskIntoConstraints = false
        formStackView.orientation = .vertical
        formStackView.spacing = 8
        formStackView.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        
        // Name field
        let nameStackView = NSStackView()
        nameStackView.orientation = .vertical
        nameStackView.spacing = 4
        nameStackView.alignment = .leading
        nameStackView.translatesAutoresizingMaskIntoConstraints = false
        
        let nameLabel = NSTextField(labelWithString: "Name")
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        
        nameField = NSTextField()
        nameField.placeholderString = "Enter command name"
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.delegate = self
        nameField.heightAnchor.constraint(equalToConstant: 22).isActive = true  // Set fixed height
        
        nameStackView.addArrangedSubview(nameLabel)
        nameStackView.addArrangedSubview(nameField)
        
        // Command field
        let commandStackView = NSStackView()
        commandStackView.orientation = .vertical
        commandStackView.spacing = 4
        commandStackView.alignment = .leading
        commandStackView.translatesAutoresizingMaskIntoConstraints = false
        
        let commandLabel = NSTextField(labelWithString: "Command")
        commandLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        
        commandField = NSTextField()
        commandField.placeholderString = "Enter shell command"
        commandField.translatesAutoresizingMaskIntoConstraints = false
        commandField.delegate = self
        commandField.heightAnchor.constraint(equalToConstant: 22).isActive = true  // Set fixed height
        
        nameField.nextKeyView = commandField
        commandField.nextKeyView = nameField
        
        commandStackView.addArrangedSubview(commandLabel)
        commandStackView.addArrangedSubview(commandField)
        
        // Form buttons
        let formButtonsStack = NSStackView()
        formButtonsStack.orientation = .horizontal
        formButtonsStack.spacing = 8
        formButtonsStack.distribution = .equalSpacing
        formButtonsStack.translatesAutoresizingMaskIntoConstraints = false
        
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelEditing))
        cancelButton.bezelStyle = .rounded
        
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveCommand))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r" // Return key
        
        formButtonsStack.addView(NSView(), in: .leading)  // Spacer to push buttons right
        formButtonsStack.addArrangedSubview(cancelButton)
        formButtonsStack.addArrangedSubview(saveButton)
        
        // Add components to form stack
        formStackView.addArrangedSubview(nameStackView)
        formStackView.addArrangedSubview(commandStackView)

        let spacerView = NSView()
        spacerView.translatesAutoresizingMaskIntoConstraints = false
        spacerView.heightAnchor.constraint(equalToConstant: 2).isActive = true
        formStackView.addArrangedSubview(spacerView)

        formStackView.addArrangedSubview(formButtonsStack)
        
        container.addSubview(formStackView)
        
        // Setup constraints for form elements
        NSLayoutConstraint.activate([
            formStackView.topAnchor.constraint(equalTo: container.topAnchor),
            formStackView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            formStackView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            formStackView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            
            // Make form stack views expand to full width
            nameStackView.widthAnchor.constraint(equalTo: formStackView.widthAnchor, constant: -32),
            commandStackView.widthAnchor.constraint(equalTo: formStackView.widthAnchor, constant: -32),
            formButtonsStack.widthAnchor.constraint(equalTo: formStackView.widthAnchor, constant: -32),
            
            // Make text fields expand to full width of their stack views
            nameField.widthAnchor.constraint(equalTo: nameStackView.widthAnchor),
            commandField.widthAnchor.constraint(equalTo: commandStackView.widthAnchor),
            
            // Set height for the form container
            container.heightAnchor.constraint(equalToConstant: 162)
        ])
        
        return marginContainer
    }
    
    private func createEmptyStateView() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        
        // Icon view
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Terminal")
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .light)
        container.addSubview(iconView)
        
        // Text label
        let textLabel = NSTextField(labelWithString: "No commands configured yet")
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        textLabel.textColor = .secondaryLabelColor
        textLabel.alignment = .center
        container.addSubview(textLabel)
        
        // Description label
        let descLabel = NSTextField(labelWithString: "Add your first command to execute it remotely from other devices")
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.font = NSFont.systemFont(ofSize: 13)
        descLabel.textColor = .tertiaryLabelColor
        descLabel.alignment = .center
        descLabel.preferredMaxLayoutWidth = 300
        descLabel.cell?.wraps = true
        container.addSubview(descLabel)
        
        // Create a content container to group the elements
        let contentStack = NSStackView(views: [iconView, textLabel, descLabel])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.spacing = 12
        contentStack.alignment = .centerX
        contentStack.distribution = .fill
        container.addSubview(contentStack)
        
        // Constraints for content stack - centered both horizontally and vertically
        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            contentStack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
            
            // Set minimum height for container to ensure it takes reasonable space
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
        
        return container
    }
    
    // MARK: - Commands Management
    
    private func loadCommands() {
        commands = delegate?.getLocalCommands() ?? []
        updateUI()
    }
    
    private func updateUI() {
        // Clear existing command items
        stackView.subviews.forEach { $0.removeFromSuperview() }
        
        // Show/hide empty state
        emptyStateView.isHidden = !commands.isEmpty
        scrollView.isHidden = commands.isEmpty
        
        // Create command item views
        for (index, command) in commands.enumerated() {
            let itemView = createCommandItemView(command: command, index: index)
            stackView.addArrangedSubview(itemView)
            
            // Apply width constraint after adding to stack view hierarchy
            itemView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        }
        
        // Refresh layout
        stackView.needsLayout = true
        stackView.layoutSubtreeIfNeeded()
        
        // Ensure the scrollview shows content from the top
        if let documentView = scrollView.documentView {
            scrollView.contentView.scroll(NSPoint(x: 0, y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
    
    private func createCommandItemView(command: RunCommandService.Command, index: Int) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        
        // Add a border for better definition in light mode
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.cornerRadius = 6
        
        // Add margin by using an extra container
        let marginContainer = NSView()
        marginContainer.translatesAutoresizingMaskIntoConstraints = false
        marginContainer.addSubview(container)
        
        // Set margin constraints (8px on each side)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: marginContainer.topAnchor, constant: 2),
            container.leadingAnchor.constraint(equalTo: marginContainer.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(equalTo: marginContainer.trailingAnchor, constant: -16),
            container.bottomAnchor.constraint(equalTo: marginContainer.bottomAnchor, constant: -2)
        ])
        
        // Command info stack
        let infoStack = NSStackView()
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        infoStack.orientation = .vertical
        infoStack.spacing = 4
        infoStack.alignment = .leading
        container.addSubview(infoStack)
        
        // Command name
        let nameLabel = NSTextField(labelWithString: command.name)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        infoStack.addArrangedSubview(nameLabel)
        
        // Command string
        let commandLabel = NSTextField(labelWithString: command.command)
        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        commandLabel.font = NSFont.systemFont(ofSize: 12)
        commandLabel.textColor = .secondaryLabelColor
        commandLabel.lineBreakMode = .byTruncatingTail
        infoStack.addArrangedSubview(commandLabel)
        
        // Buttons container
        let buttonsStack = NSStackView()
        buttonsStack.translatesAutoresizingMaskIntoConstraints = false
        buttonsStack.orientation = .horizontal
        buttonsStack.spacing = 8
        container.addSubview(buttonsStack)
        
        // Edit button
        let editButton = NSButton()
        editButton.translatesAutoresizingMaskIntoConstraints = false
        editButton.bezelStyle = .inline
        editButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit")
        editButton.imagePosition = .imageOnly
        editButton.title = ""
        editButton.tag = index
        editButton.target = self
        editButton.action = #selector(editCommand(_:))
        editButton.toolTip = "Edit command"
        
        // Ensure buttons have consistent appearance in light mode
        if #available(macOS 10.14, *) {
            editButton.contentTintColor = .controlAccentColor
        }
        
        buttonsStack.addArrangedSubview(editButton)
        
        // Delete button
        let deleteButton = NSButton()
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.bezelStyle = .inline
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
        deleteButton.imagePosition = .imageOnly
        deleteButton.title = ""
        deleteButton.tag = index
        deleteButton.target = self
        deleteButton.action = #selector(removeCommand(_:))
        deleteButton.toolTip = "Delete command"
        
        // Consistent appearance in light mode
        if #available(macOS 10.14, *) {
            deleteButton.contentTintColor = .systemRed
        }
        
        buttonsStack.addArrangedSubview(deleteButton)
        
        // Set constraints
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            // Width constraint is now applied in updateUI after adding to hierarchy
            
            infoStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            infoStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            infoStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            infoStack.trailingAnchor.constraint(lessThanOrEqualTo: buttonsStack.leadingAnchor, constant: -12),
            
            // Expand name and command labels to fill available width
            nameLabel.widthAnchor.constraint(lessThanOrEqualTo: infoStack.widthAnchor),
            commandLabel.widthAnchor.constraint(lessThanOrEqualTo: infoStack.widthAnchor),
            
            buttonsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            buttonsStack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        
        return marginContainer
    }
    
    // MARK: - Actions
    
    @objc private func addCommand() {
        // If already editing a command, cancel the edit to restore all items
        if selectedCommandIndex != nil || isEditingNewCommand {
            cancelEditing()
        }
        
        // Reset form fields
        nameField.stringValue = ""
        commandField.stringValue = ""
        
        isEditingNewCommand = true
        selectedCommandIndex = nil
        
        // Make sure scrollView is visible, even if there are no commands yet
        scrollView.isHidden = false
        emptyStateView.isHidden = true
        
        // Remove any existing width constraint to prevent constraint conflicts
        formContainer.constraints.forEach { constraint in
            if constraint.firstAttribute == .width {
                formContainer.removeConstraint(constraint)
            }
        }
        
        // First remove form from any previous parent
        formContainer.removeFromSuperview()
        
        // Add the form to the end of the stack
        stackView.addArrangedSubview(formContainer)
        
        // Apply proper width constraint - make sure to not add duplicates
        let widthConstraint = formContainer.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        NSLayoutConstraint.activate([widthConstraint])
        
        // Update layout to ensure form is visible
        stackView.needsLayout = true
        stackView.layoutSubtreeIfNeeded()
        
        // Scroll to make form visible if needed
        let formRect = formContainer.frame
        scrollView.contentView.scrollToVisible(formRect)
        
        nameField.becomeFirstResponder()
    }
    
    @objc private func editCommand(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0 && index < commands.count else { return }
        
        // First, cancel any existing edit operation to restore items
        if selectedCommandIndex != nil {
            cancelEditing()
        }
        
        selectedCommandIndex = index
        isEditingNewCommand = false
        
        // Populate form fields
        nameField.stringValue = commands[index].name
        commandField.stringValue = commands[index].command
        
        // Show form
        formContainer.isHidden = false
        emptyStateView.isHidden = true
        scrollView.isHidden = false
        
        // Remove any existing width constraint to prevent constraint conflicts
        formContainer.constraints.forEach { constraint in
            if constraint.firstAttribute == .width {
                formContainer.removeConstraint(constraint)
            }
        }
        
        // First remove form from any previous parent
        formContainer.removeFromSuperview()
        
        // Remove the view of the command being edited
        if index < stackView.arrangedSubviews.count {
            stackView.arrangedSubviews[index].removeFromSuperview()
        }
        
        // Insert form at the position of the command being edited
        // Make sure we don't try to insert at an index that's out of bounds
        let safeIndex = min(index, stackView.arrangedSubviews.count)
        stackView.insertArrangedSubview(formContainer, at: safeIndex)
        
        // Apply width constraint - make sure to not add duplicates
        let widthConstraint = formContainer.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        NSLayoutConstraint.activate([widthConstraint])
        
        // Update layout to ensure form is visible
        stackView.needsLayout = true
        stackView.layoutSubtreeIfNeeded()
        
        // Scroll to make the form visible
        let formRect = formContainer.frame
        scrollView.contentView.scrollToVisible(formRect)
        
        nameField.becomeFirstResponder()
    }
    
    @objc private func removeCommand(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0 && index < commands.count else { return }
        
        commands.remove(at: index)
        updateUI()
        
        // Save changes
        delegate?.saveLocalCommands(commands)
    }
    
    @objc private func saveCommand() {
        // Validate input
        guard !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Show error
            let alert = NSAlert()
            alert.messageText = "Invalid Input"
            alert.informativeText = "Command name and command cannot be empty."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: self.window!) { _ in }
            return
        }
        
        // Remove form from stack view
        formContainer.removeFromSuperview()
        
        if isEditingNewCommand {
            // Add new command
            let newCommand = RunCommandService.Command(
                uuid: UUID().uuidString,
                name: nameField.stringValue,
                command: commandField.stringValue
            )
            commands.append(newCommand)
        } else if let index = selectedCommandIndex {
            // Update existing command
            commands[index].name = nameField.stringValue
            commands[index].command = commandField.stringValue
        }
        
        // Reset editing state
        isEditingNewCommand = false
        selectedCommandIndex = nil
        
        // Update UI and save changes
        updateUI()
        delegate?.saveLocalCommands(commands)
    }
    
    @objc private func cancelEditing() {
        // Remove form from stack view
        formContainer.removeFromSuperview()
        
        // If we were editing an existing command, restore its view
        if let index = selectedCommandIndex, !isEditingNewCommand, index < commands.count {
            let itemView = createCommandItemView(command: commands[index], index: index)
            
            if index < stackView.arrangedSubviews.count {
                stackView.insertArrangedSubview(itemView, at: index)
            } else {
                stackView.addArrangedSubview(itemView)
            }
            
            // Apply width constraint
            itemView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        }
        
        // Reset editing state
        isEditingNewCommand = false
        selectedCommandIndex = nil
        
        // Show empty state if there are no commands
        if commands.isEmpty {
            scrollView.isHidden = true
            emptyStateView.isHidden = false
        } else {
            emptyStateView.isHidden = true
            scrollView.isHidden = false
        }
        
        // Refresh the layout
        stackView.layoutSubtreeIfNeeded()
    }
}

// MARK: - NSTextFieldDelegate

extension RunCommandsWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        // This method can be used to implement real-time validation or UI updates
        // based on the text input changes
    }
}
