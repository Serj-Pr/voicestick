import AppKit

final class SettingsWindowController: NSWindowController {
    private let providerPopup = NSPopUpButton()
    private let apiKeyField = NSTextField()
    private let applyTrialAPIKeyButton = NSButton(title: "Apply Trial", target: nil, action: nil)
    private let resourcePopup = NSPopUpButton()
    private let appleSpeechLocalePopup = NSPopUpButton()
    private let hotwordsTextView = NSTextView()
    private let hotwordsScrollView = NSScrollView()
    private let correctionsTextView = NSTextView()
    private let correctionsScrollView = NSScrollView()
    private let llmBaseURLField = NSTextField()
    private let llmAPIKeyField = NSTextField()
    private let llmModelField = NSTextField()
    private let debugAudioButton = NSButton(checkboxWithTitle: "Save debug audio files", target: nil, action: nil)
    private let debugAudioDirectoryField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private var currentDisplayedProvider: ASRProvider = .volcengine
    private var isSyncingOpenAIAPIKeyFields = false
    private var resourceRow: NSStackView?
    private var appleSpeechLocaleRow: NSStackView?
    private var apiKeyRow: NSStackView?
    var onConfigChanged: ((AppConfig) -> Void)?

    private var config: AppConfig

    init(config: AppConfig = AppConfig.load()) {
        self.config = config
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceStick Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        loadConfigIntoFields()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(apiKeyFieldDidChange),
            name: NSControl.textDidChangeNotification,
            object: apiKeyField
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(llmAPIKeyFieldDidChange),
            name: NSControl.textDidChangeNotification,
            object: llmAPIKeyField
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show() {
        config = AppConfig.load()
        loadConfigIntoFields()
        showWindow(nil)
        window?.makeFirstResponder(providerPopup)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        stack.addArrangedSubview(sectionTitle("ASR"))
        configureProviderPopup()
        stack.addArrangedSubview(row(label: "Provider", control: providerPopup))
        configureApplyTrialAPIKeyButton()
        let apiKeyRow = row(label: "API Key", control: apiKeyControl())
        self.apiKeyRow = apiKeyRow
        stack.addArrangedSubview(apiKeyRow)
        configureResourcePopup()
        let resourceRow = row(label: "Resource ID", control: resourcePopup)
        self.resourceRow = resourceRow
        stack.addArrangedSubview(resourceRow)
        configureAppleSpeechLocalePopup()
        let appleSpeechLocaleRow = row(label: "Apple Language", control: appleSpeechLocalePopup)
        self.appleSpeechLocaleRow = appleSpeechLocaleRow
        stack.addArrangedSubview(appleSpeechLocaleRow)
        configureHotwordsTextView()
        stack.addArrangedSubview(row(label: "Hotwords", control: hotwordsScrollView))
        stack.addArrangedSubview(hintRow("Separate hotwords with commas or new lines."))
        configureCorrectionsTextView()
        stack.addArrangedSubview(row(label: "Corrections", control: correctionsScrollView))
        stack.addArrangedSubview(hintRow("Use mistake=>correction, one per line. Example: ноги=>логи"))

        stack.addArrangedSubview(sectionTitle("LLM"))
        stack.addArrangedSubview(row(label: "Base URL", control: llmBaseURLField))
        stack.addArrangedSubview(row(label: "API Key", control: llmAPIKeyField))
        stack.addArrangedSubview(row(label: "Model", control: llmModelField))

        stack.addArrangedSubview(sectionTitle("Debug"))
        stack.addArrangedSubview(row(label: "Audio Cache", control: debugAudioButton))
        let debugDirRow = NSStackView()
        debugDirRow.orientation = .horizontal
        debugDirRow.alignment = .centerY
        debugDirRow.spacing = 8
        debugAudioDirectoryField.isEditable = false
        debugAudioDirectoryField.lineBreakMode = .byTruncatingMiddle
        let chooseButton = NSButton(title: "Choose...", target: self, action: #selector(chooseDebugDirectory))
        debugDirRow.addArrangedSubview(debugAudioDirectoryField)
        debugDirRow.addArrangedSubview(chooseButton)
        debugAudioDirectoryField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        stack.addArrangedSubview(row(label: "Audio Folder", control: debugDirRow))

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        let openFolderButton = NSButton(title: "Open Config Folder", target: self, action: #selector(openConfigFolder))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        saveButton.keyEquivalent = "\r"
        buttonRow.addArrangedSubview(openFolderButton)
        buttonRow.addArrangedSubview(statusLabel)
        buttonRow.addArrangedSubview(spacer)
        buttonRow.addArrangedSubview(saveButton)
        stack.addArrangedSubview(buttonRow)
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        statusLabel.textColor = .secondaryLabelColor

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        ])
    }

    private func configureResourcePopup() {
        resourcePopup.addItems(withTitles: AppConfig.supportedResourceIDs)
    }

    private func configureProviderPopup() {
        providerPopup.addItems(withTitles: [
            ASRProvider.voiceStickCloud.displayName,
            ASRProvider.volcengine.displayName,
            ASRProvider.openai.displayName,
            ASRProvider.appleSpeech.displayName
        ])
        providerPopup.target = self
        providerPopup.action = #selector(providerSelectionChanged)
    }

    private func configureAppleSpeechLocalePopup() {
        appleSpeechLocalePopup.removeAllItems()
        for option in AppConfig.appleSpeechLocaleOptions {
            appleSpeechLocalePopup.addItem(withTitle: option.title)
            appleSpeechLocalePopup.lastItem?.representedObject = option.code
        }
    }

    private func configureApplyTrialAPIKeyButton() {
        applyTrialAPIKeyButton.target = self
        applyTrialAPIKeyButton.action = #selector(applyTrialAPIKey)
    }

    private func apiKeyControl() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        apiKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        applyTrialAPIKeyButton.widthAnchor.constraint(equalToConstant: 102).isActive = true
        stack.addArrangedSubview(apiKeyField)
        stack.addArrangedSubview(applyTrialAPIKeyButton)
        return stack
    }

    private func configureHotwordsTextView() {
        configureMultilineTextView(hotwordsTextView, in: hotwordsScrollView, height: 78)
    }

    private func configureCorrectionsTextView() {
        configureMultilineTextView(correctionsTextView, in: correctionsScrollView, height: 78)
    }

    private func configureMultilineTextView(_ textView: NSTextView, in scrollView: NSScrollView, height: CGFloat) {
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.heightAnchor.constraint(equalToConstant: height).isActive = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.frame = NSRect(origin: .zero, size: NSSize(width: 300, height: height))
        textView.textContainer?.containerSize = NSSize(
            width: textView.frame.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
    }

    private func loadConfigIntoFields() {
        currentDisplayedProvider = config.asrProvider
        providerPopup.selectItem(withTitle: config.asrProvider.displayName)
        apiKeyField.stringValue = apiKey(for: config.asrProvider)
        hotwordsTextView.string = config.asrHotwords.joined(separator: ",")
        correctionsTextView.string = config.correctionText
        llmBaseURLField.stringValue = config.llmBaseURL
        llmAPIKeyField.stringValue = config.llmAPIKey
        llmModelField.stringValue = config.llmModel
        selectAppleSpeechLocale(config.appleSpeechLocale)
        debugAudioButton.state = config.debugAudioCache ? .on : .off
        debugAudioDirectoryField.stringValue = config.debugAudioDirectory.path

        if resourcePopup.itemTitles.contains(config.resourceID) {
            resourcePopup.selectItem(withTitle: config.resourceID)
        }
        updateProviderRows()
        updateApplyTrialButton()
        statusLabel.stringValue = ""
    }

    @objc private func providerSelectionChanged() {
        saveDisplayedAPIKey()
        currentDisplayedProvider = selectedProvider()
        config.asrProvider = currentDisplayedProvider
        apiKeyField.stringValue = apiKey(for: currentDisplayedProvider)
        if currentDisplayedProvider == .openai {
            llmAPIKeyField.stringValue = apiKeyField.stringValue
        }
        updateProviderRows()
        updateApplyTrialButton()
    }

    @objc private func apiKeyFieldDidChange() {
        syncOpenAIApiKeys(from: apiKeyField)
        updateApplyTrialButton()
    }

    @objc private func llmAPIKeyFieldDidChange() {
        syncOpenAIApiKeys(from: llmAPIKeyField)
    }

    @objc private func applyTrialAPIKey() {
        saveDisplayedAPIKey()
        guard currentDisplayedProvider == .voiceStickCloud else { return }

        applyTrialAPIKeyButton.isEnabled = false
        statusLabel.stringValue = "Applying trial API key..."
        VoiceStickCloudAPI.applyTrialAPIKey(
            cloudURL: config.voiceStickCloudURL,
            deviceID: config.pairedDeviceIDs.first
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyTrialAPIKeyButton.isEnabled = true
                switch result {
                case .success(.apiKey(let apiKey)):
                    self.config.voiceStickAPIKey = apiKey
                    self.apiKeyField.stringValue = apiKey
                    self.statusLabel.stringValue = "Trial API key applied."
                    self.updateApplyTrialButton()
                case .success(.url(let url)):
                    self.statusLabel.stringValue = "Opened trial application page."
                    if !NSWorkspace.shared.open(url) {
                        self.showErrorAlert(
                            title: "Could Not Open Trial Page",
                            message: url.absoluteString
                        )
                    }
                case .failure(let error):
                    self.statusLabel.stringValue = ""
                    self.showErrorAlert(
                        title: "Could Not Apply Trial API Key",
                        message: error.localizedDescription
                    )
                    self.updateApplyTrialButton()
                }
            }
        }
    }

    @objc private func chooseDebugDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: debugAudioDirectoryField.stringValue)
        if panel.runModal() == .OK, let url = panel.url {
            debugAudioDirectoryField.stringValue = url.path
        }
    }

    @objc private func saveSettings() {
        saveDisplayedAPIKey()
        let provider = selectedProvider()
        let resourceID = resourcePopup.titleOfSelectedItem ?? config.resourceID

        config = AppConfig(
            asrProvider: provider,
            voiceStickAPIKey: config.voiceStickAPIKey,
            voiceStickCloudURL: config.voiceStickCloudURL,
            volcengineAPIKey: config.volcengineAPIKey,
            llmBaseURL: llmBaseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            llmAPIKey: llmAPIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            llmModel: llmModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            interactionMode: config.interactionMode,
            resourceID: resourceID,
            appleSpeechLocale: selectedAppleSpeechLocale(),
            asrHotwords: AppConfig.hotwordList(hotwordsTextView.string),
            asrCorrections: AppConfig.correctionMap(correctionsTextView.string),
            pairedDeviceIDs: config.pairedDeviceIDs,
            deviceThemeColors: config.deviceThemeColors,
            deviceOverlayPositions: config.deviceOverlayPositions,
            defaultOutputProfile: config.defaultOutputProfile,
            deviceOutputProfiles: config.deviceOutputProfiles,
            autoEnter: config.autoEnter,
            debugAudioCache: debugAudioButton.state == .on,
            debugAudioDirectory: URL(fileURLWithPath: debugAudioDirectoryField.stringValue, isDirectory: true)
        )

        do {
            try config.save()
            onConfigChanged?(config)
            statusLabel.stringValue = "Saved."
            window?.close()
        } catch {
            statusLabel.stringValue = ""
            showErrorAlert(title: "Could Not Save Settings", message: error.localizedDescription)
        }
    }

    @objc private func openConfigFolder() {
        AppConfig.openConfigDirectory()
    }

    private func selectedProvider() -> ASRProvider {
        switch providerPopup.titleOfSelectedItem {
        case ASRProvider.voiceStickCloud.displayName:
            return .voiceStickCloud
        case ASRProvider.volcengine.displayName:
            return .volcengine
        case ASRProvider.openai.displayName:
            return .openai
        case ASRProvider.appleSpeech.displayName:
            return .appleSpeech
        default:
            return config.asrProvider
        }
    }

    private func apiKey(for provider: ASRProvider) -> String {
        switch provider {
        case .voiceStickCloud:
            return config.voiceStickAPIKey
        case .volcengine:
            return config.volcengineAPIKey
        case .openai:
            return config.llmAPIKey
        case .appleSpeech:
            return ""
        }
    }

    private func selectedAppleSpeechLocale() -> String {
        (appleSpeechLocalePopup.selectedItem?.representedObject as? String) ?? AppConfig.defaults.appleSpeechLocale
    }

    private func selectAppleSpeechLocale(_ code: String) {
        if let item = appleSpeechLocalePopup.itemArray.first(where: { ($0.representedObject as? String) == code }) {
            appleSpeechLocalePopup.select(item)
            return
        }

        let title = Locale.current.localizedString(forIdentifier: code) ?? code
        appleSpeechLocalePopup.addItem(withTitle: "\(title) (\(code))")
        appleSpeechLocalePopup.lastItem?.representedObject = code
        appleSpeechLocalePopup.select(appleSpeechLocalePopup.lastItem)
    }

    private func saveDisplayedAPIKey() {
        let value = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch currentDisplayedProvider {
        case .voiceStickCloud:
            config.voiceStickAPIKey = value
        case .volcengine:
            config.volcengineAPIKey = value
        case .openai:
            config.llmAPIKey = value
        case .appleSpeech:
            break
        }
    }

    private func updateProviderRows() {
        resourceRow?.isHidden = currentDisplayedProvider != .volcengine
        appleSpeechLocaleRow?.isHidden = currentDisplayedProvider != .appleSpeech
        apiKeyRow?.isHidden = currentDisplayedProvider == .appleSpeech
        updateApplyTrialButton()
    }

    private func updateApplyTrialButton() {
        let isCloud = currentDisplayedProvider == .voiceStickCloud
        let isEmpty = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        applyTrialAPIKeyButton.isHidden = !(isCloud && isEmpty)
    }

    private func syncOpenAIApiKeys(from sourceField: NSTextField) {
        guard currentDisplayedProvider == .openai else { return }
        guard !isSyncingOpenAIAPIKeyFields else { return }
        isSyncingOpenAIAPIKeyFields = true
        let value = sourceField.stringValue
        if sourceField === apiKeyField {
            llmAPIKeyField.stringValue = value
            config.llmAPIKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            apiKeyField.stringValue = value
            config.llmAPIKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        isSyncingOpenAIAPIKeyFields = false
    }

    private func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func row(label: String, control: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.textColor = .secondaryLabelColor
        labelView.widthAnchor.constraint(equalToConstant: 120).isActive = true
        if control is NSTextField || control is NSPopUpButton || control is NSStackView || control is NSScrollView {
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        row.addArrangedSubview(labelView)
        row.addArrangedSubview(control)
        return row
    }

    private func hintRow(_ text: String) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12

        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        row.addArrangedSubview(spacer)
        row.addArrangedSubview(label)
        return row
    }
}
