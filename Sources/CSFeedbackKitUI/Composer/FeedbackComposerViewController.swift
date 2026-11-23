import UIKit
import CSFeedbackKit

/// The note sheet. Port of Shizen's QA note composer: collapsible context, growing note
/// field, tag chips (+ screenshot/logs toggles), copy-for-agent, send.
final class FeedbackComposerViewController: UIViewController, UITextViewDelegate, UIGestureRecognizerDelegate {

    private let capture: FeedbackCapture
    private let configuration: FeedbackConfig
    private let appearance: FeedbackAppearance
    private let screenshotJPEG: Data?
    /// Opened from the screenshot trigger: the screenshot chip starts on regardless of the last choice.
    private let forcesScreenshot: Bool

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let noteTextView = UITextView()
    private let notePlaceholder = UILabel()
    private let destinationButton = UIButton(type: .system)
    private let sendButton: FeedbackPrimaryButton
    private var selectedDestinationID: String?
    private let contextDisclosureButton = UIButton(type: .system)
    private let contextChevron = UIImageView()
    private let contextBodyLabel = UILabel()
    private var tagControls: [(id: String, control: FeedbackTagControl)] = []
    private var screenshotToggle: FeedbackTagControl?
    private var logsToggle: FeedbackTagControl?
    private var inputs: [FieldInput] = []
    private var testerInput: UITextField?
    private var isSending = false
    private var contextExpanded = false

    init(
        capture: FeedbackCapture,
        configuration: FeedbackConfig,
        appearance: FeedbackAppearance,
        screenshotJPEG: Data?,
        forcesScreenshot: Bool
    ) {
        self.capture = capture
        self.configuration = configuration
        self.appearance = appearance
        self.screenshotJPEG = screenshotJPEG
        self.forcesScreenshot = forcesScreenshot
        var sendColors = FeedbackAppearance.ButtonColors.blue
        sendColors.background = .systemBlue
        sendColors.highlightedBackground = UIColor.systemBlue.withAlphaComponent(0.8)
        sendColors.cornerRadius = appearance.sendButton.cornerRadius
        sendButton = FeedbackPrimaryButton(colors: sendColors)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = appearance.pageBackground
        navigationItem.title = capture.source?.title ?? configuration.copy.composerTitle
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            style: .plain,
            target: self,
            action: #selector(closeTapped)
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Close"
        let copyItem = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            style: .plain,
            target: self,
            action: #selector(copyTapped)
        )
        copyItem.accessibilityLabel = "Copy for agent"
        navigationItem.leftBarButtonItem = copyItem

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .onDrag
        scrollView.alwaysBounceVertical = true
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)

        stack.addArrangedSubview(makeContextBlock())
        if let details = makeDetailsSection() {
            stack.addArrangedSubview(details)
        }
        stack.addArrangedSubview(makeNoteSection())

        let actions = UIStackView(arrangedSubviews: [destinationButton, sendButton])
        actions.spacing = 10
        actions.translatesAutoresizingMaskIntoConstraints = false
        destinationButton.showsMenuAsPrimaryAction = true
        destinationButton.accessibilityLabel = "Destination"
        destinationButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sendButton.accessibilityLabel = configuration.copy.sendButton
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        view.addSubview(actions)
        updateDestinations()

        let scrollBottomToActions = scrollView.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -16)
        scrollBottomToActions.priority = .defaultHigh
        NSLayoutConstraint.activate([
            actions.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: FeedbackPrimaryButton.horizontalInset),
            actions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -FeedbackPrimaryButton.horizontalInset),
            // Pinned to the safe area, not the keyboard: the keyboard covers it while typing.
            actions.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            actions.heightAnchor.constraint(equalToConstant: FeedbackPrimaryButton.preferredHeight),

            sendButton.widthAnchor.constraint(equalTo: actions.widthAnchor, multiplier: 1.0 / 3.0),

            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Stops above the actions, or above the keyboard when it is up.
            scrollView.bottomAnchor.constraint(lessThanOrEqualTo: actions.topAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor),
            scrollBottomToActions,

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40),
            stack.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor, constant: -32),
        ])

        installKeyboardScrollObservers()

        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        dismissTap.cancelsTouchesInView = false
        dismissTap.delegate = self
        view.addGestureRecognizer(dismissTap)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scrollCaretIntoView(animated: true)
    }

    // MARK: Keyboard

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    /// Taps on any text input keep (or move) focus; taps anywhere else dismiss the keyboard.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var hit = touch.view
        while let current = hit {
            if current is UITextView || current is UITextField { return false }
            hit = current.superview
        }
        return true
    }

    /// Selector-based, so it unregisters itself when the sheet goes away.
    private func installKeyboardScrollObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curveRaw = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
        UIView.animate(withDuration: duration, delay: 0, options: UIView.AnimationOptions(rawValue: curveRaw << 16)) {
            self.view.layoutIfNeeded()
            self.scrollCaretIntoView(animated: false)
        }
    }

    /// The note field grows instead of scrolling, so the outer scroll view follows the caret.
    private func scrollCaretIntoView(animated: Bool) {
        guard noteTextView.isFirstResponder, let selection = noteTextView.selectedTextRange else { return }
        view.layoutIfNeeded()
        let caret = noteTextView.caretRect(for: selection.end)
        guard !caret.isNull, !caret.isInfinite else { return }
        let target = noteTextView.convert(caret, to: scrollView)
        scrollView.scrollRectToVisible(target.insetBy(dx: 0, dy: -24), animated: animated)
    }

    func textViewDidChange(_ textView: UITextView) {
        notePlaceholder.isHidden = !textView.text.isEmpty
        scrollCaretIntoView(animated: false)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        scrollCaretIntoView(animated: false)
    }

    // MARK: Context

    private func makeContextBlock() -> UIView {
        contextChevron.image = UIImage(systemName: "chevron.right")
        contextChevron.tintColor = .secondaryLabel
        contextChevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .small)
        contextChevron.setContentHuggingPriority(.required, for: .horizontal)
        contextChevron.setContentCompressionResistancePriority(.required, for: .horizontal)

        let title = UILabel()
        title.text = "Context"
        title.font = .preferredFont(forTextStyle: .subheadline)
        title.textColor = .secondaryLabel

        let row = UIStackView(arrangedSubviews: [contextChevron, title])
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false

        contextDisclosureButton.accessibilityLabel = "Context"
        contextDisclosureButton.accessibilityValue = "Collapsed"
        contextDisclosureButton.addTarget(self, action: #selector(toggleContextExpanded), for: .touchUpInside)
        contextDisclosureButton.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contextDisclosureButton.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: contextDisclosureButton.bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: contextDisclosureButton.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: contextDisclosureButton.trailingAnchor),
        ])

        contextBodyLabel.numberOfLines = 0
        contextBodyLabel.font = .preferredFont(forTextStyle: .subheadline)
        contextBodyLabel.textColor = .secondaryLabel
        contextBodyLabel.text = contextLines(masked: true).joined(separator: "\n")
        contextBodyLabel.isHidden = true

        let wrap = UIStackView(arrangedSubviews: [contextDisclosureButton, contextBodyLabel])
        wrap.axis = .vertical
        wrap.spacing = 8
        wrap.alignment = .fill
        return wrap
    }

    @objc private func toggleContextExpanded() {
        contextExpanded.toggle()
        contextChevron.image = UIImage(systemName: contextExpanded ? "chevron.down" : "chevron.right")
        contextDisclosureButton.accessibilityValue = contextExpanded ? "Expanded" : "Collapsed"
        UIView.animate(withDuration: 0.2) {
            self.contextBodyLabel.isHidden = !self.contextExpanded
            self.view.layoutIfNeeded()
        }
    }

    /// What the tester sees (masked) and what Copy for agent copies (unmasked).
    private func contextLines(masked: Bool) -> [String] {
        var lines: [String] = []
        if let source = capture.source {
            if let title = source.title, title != source.screen {
                lines.append("Screen: \(title) (\(source.screen))")
            } else {
                lines.append("Screen: \(source.screen)")
            }
        }
        for field in configuration.fields where field.visible {
            guard let value = capture.fields.values[field.key] else { continue }
            let text = masked && field.sensitive ? mask(value.displayText) : value.displayText
            lines.append("\(field.label): \(text)")
        }
        if let tester = capture.testerIdentity, configuration.tester.source == .prompt {
            lines.append("Tester: \(tester)")
        }
        lines.append("Build: \(Bundle.main.shortVersion) (\(Bundle.main.buildNumber)), \(capture.environment.rawValue)")
        return lines
    }

    private func mask(_ text: String) -> String {
        guard text.count > 4 else { return String(repeating: "•", count: max(text.count, 4)) }
        return String(text.prefix(2)) + String(repeating: "•", count: min(text.count - 4, 8)) + String(text.suffix(2))
    }

    // MARK: Details (required fields nobody supplied, tester prompt)

    private struct FieldInput {
        let field: FieldConfig
        let textField: UITextField?
        let toggle: UISwitch?

        @MainActor
        var value: FeedbackValue? {
            switch field.type {
            case .bool:
                return toggle.map { .bool($0.isOn) }
            case .string:
                let text = textField?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return text.isEmpty ? nil : .string(text)
            case .number:
                let text = textField?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return Double(text.replacingOccurrences(of: ",", with: ".")).map { .number($0) }
            case .stringArray:
                let items = (textField?.text ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                return items.isEmpty ? nil : .strings(items)
            }
        }
    }

    private func makeDetailsSection() -> UIView? {
        var rows: [UIView] = []

        if configuration.tester.source == .prompt, capture.testerIdentity == nil {
            let field = makeTextField(placeholder: configuration.tester.prompt)
            field.textContentType = .emailAddress
            field.keyboardType = .emailAddress
            field.autocapitalizationType = .none
            testerInput = field
            rows.append(labeled(configuration.tester.prompt, field))
        }

        for field in capture.fields.missingRequired {
            switch field.type {
            case .bool:
                let toggle = UISwitch()
                toggle.addTarget(self, action: #selector(updateDestinations), for: .valueChanged)
                inputs.append(FieldInput(field: field, textField: nil, toggle: toggle))
                let label = UILabel()
                label.text = field.label
                label.font = .preferredFont(forTextStyle: .body)
                let row = UIStackView(arrangedSubviews: [label, toggle])
                row.axis = .horizontal
                row.alignment = .center
                rows.append(row)
            case .string, .number, .stringArray:
                let placeholder = field.type == .stringArray ? "Comma separated" : field.label
                let textField = makeTextField(placeholder: placeholder)
                textField.addTarget(self, action: #selector(updateDestinations), for: .editingChanged)
                if field.type == .number { textField.keyboardType = .decimalPad }
                inputs.append(FieldInput(field: field, textField: textField, toggle: nil))
                rows.append(labeled(field.label, textField))
            }
        }

        guard !rows.isEmpty else { return nil }
        let heading = UILabel()
        heading.text = "Details"
        heading.font = .preferredFont(forTextStyle: .headline)
        let section = UIStackView(arrangedSubviews: [heading] + rows)
        section.axis = .vertical
        section.spacing = 10
        return section
    }

    private func makeTextField(placeholder: String) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.font = .preferredFont(forTextStyle: .body)
        field.backgroundColor = .secondarySystemGroupedBackground
        field.layer.cornerRadius = 12
        field.layer.borderWidth = 1
        field.layer.borderColor = UIColor.separator.cgColor
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        field.leftViewMode = .always
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return field
    }

    private func labeled(_ text: String, _ control: UIView) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [label, control])
        stack.axis = .vertical
        stack.spacing = 6
        return stack
    }

    // MARK: Note + tags

    private func makeNoteSection() -> UIView {
        let heading = UILabel()
        heading.text = "Note"
        heading.font = .preferredFont(forTextStyle: .headline)

        noteTextView.font = .preferredFont(forTextStyle: .body)
        noteTextView.layer.cornerRadius = 12
        noteTextView.layer.borderWidth = 1
        noteTextView.layer.borderColor = UIColor.separator.cgColor
        noteTextView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        noteTextView.isScrollEnabled = false
        noteTextView.delegate = self
        noteTextView.translatesAutoresizingMaskIntoConstraints = false
        noteTextView.setContentHuggingPriority(UILayoutPriority(1), for: .vertical)
        noteTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        notePlaceholder.text = configuration.copy.notePlaceholder
        notePlaceholder.font = .preferredFont(forTextStyle: .body)
        notePlaceholder.textColor = .placeholderText
        notePlaceholder.translatesAutoresizingMaskIntoConstraints = false
        notePlaceholder.isAccessibilityElement = false
        noteTextView.addSubview(notePlaceholder)
        NSLayoutConstraint.activate([
            notePlaceholder.topAnchor.constraint(equalTo: noteTextView.topAnchor, constant: 12),
            notePlaceholder.leadingAnchor.constraint(equalTo: noteTextView.leadingAnchor, constant: 15),
        ])
        noteTextView.accessibilityHint = configuration.copy.notePlaceholder

        var sectionViews: [UIView] = [heading, noteTextView]
        if let flow = makeTagFlow() { sectionViews.append(flow) }

        let wrap = UIStackView(arrangedSubviews: sectionViews)
        wrap.axis = .vertical
        wrap.spacing = 8
        wrap.setCustomSpacing(14, after: noteTextView)
        return wrap
    }

    private func makeTagFlow() -> UIView? {
        let tint = appearance.selectedTagTint
        tagControls = configuration.tags.map { tag in
            let control = FeedbackTagControl(title: tag.label, tint: tint)
            control.setSelectedWithoutAnimation(tag.selected)
            control.addTarget(self, action: #selector(updateDestinations), for: .valueChanged)
            return (tag.id, control)
        }

        var toggles: [FeedbackTagControl] = []
        if screenshotJPEG != nil, let config = configuration.attachments.screenshot {
            let toggle = FeedbackTagControl(title: "#screenshot", tint: tint)
            toggle.setSelectedWithoutAnimation(forcesScreenshot || Self.rememberedScreenshotChoice(default: config.defaultOn))
            toggle.addTarget(self, action: #selector(screenshotToggleChanged), for: .valueChanged)
            screenshotToggle = toggle
            toggles.append(toggle)
        }
        if let logs = configuration.attachments.logs, logs.enabled, logs.environments.allowsEnvironment(capture.environment) {
            let toggle = FeedbackTagControl(title: "#logs", tint: tint)
            toggle.setSelectedWithoutAnimation(true)
            logsToggle = toggle
            toggles.append(toggle)
        }

        let all = tagControls.map(\.control) + toggles
        guard !all.isEmpty else { return nil }
        let flow = FeedbackTagFlowView()
        flow.setTags(all)
        flow.setContentCompressionResistancePriority(.required, for: .vertical)
        return flow
    }

    private static let screenshotChoiceKey = "CSFeedbackKit.includeScreenshot"

    /// Last choice on this sheet, so turning it off sticks. Starts at the config default.
    private static func rememberedScreenshotChoice(default defaultOn: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: screenshotChoiceKey) != nil else { return defaultOn }
        return UserDefaults.standard.bool(forKey: screenshotChoiceKey)
    }

    @objc private func screenshotToggleChanged() {
        UserDefaults.standard.set(screenshotToggle?.isSelected ?? false, forKey: Self.screenshotChoiceKey)
    }

    // MARK: Values

    private var typedNote: String {
        noteTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedTagIDs: Set<String> {
        Set(tagControls.filter { $0.control.isSelected }.map(\.id))
    }

    private func agentPasteboardText() -> String {
        var lines: [String] = []
        let tags = tagControls.filter { $0.control.isSelected }.map(\.control.title)
        if !tags.isEmpty {
            lines.append("Tags: " + tags.joined(separator: " "))
            lines.append("")
        }
        lines += contextLines(masked: false)
        for input in inputs {
            if let value = input.value { lines.append("\(input.field.label): \(value.displayText)") }
        }
        lines.append("")
        lines.append("Note:")
        lines.append(typedNote)
        return lines.joined(separator: "\n")
    }

    // MARK: Actions

    @objc private func copyTapped() {
        view.endEditing(true)
        UIPasteboard.general.string = agentPasteboardText()
        appearance.showToast(self, FeedbackToast(text: "Copied", kind: .success))
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func sendTapped() {
        guard !isSending else { return }
        guard !typedNote.isEmpty else {
            appearance.showToast(self, FeedbackToast(text: FeedbackError.emptyNote.localizedDescription, kind: .error))
            return
        }
        view.endEditing(true)

        guard let selectedDestinationID else { return }
        var draft = currentDraft()
        draft.destinationID = selectedDestinationID
        send(draft)
    }

    private func currentDraft() -> FeedbackDraft {
        var filled: FeedbackValues = [:]
        for input in inputs {
            if let value = input.value { filled[input.field.key] = value }
        }
        return FeedbackDraft(
            note: typedNote,
            tagIDs: selectedTagIDs,
            filledFields: filled,
            screenshotJPEG: screenshotToggle?.isSelected == true ? screenshotJPEG : nil,
            includeLogs: logsToggle?.isSelected ?? false,
            testerIdentity: testerInput?.text
        )
    }

    @objc private func updateDestinations() {
        let destinations = Feedback.availableDestinations(for: capture, draft: currentDraft())
        let selected = destinations.count == 1
            ? destinations.first
            : destinations.first { $0.id == selectedDestinationID }
        selectedDestinationID = selected?.id

        var config = UIButton.Configuration.filled()
        config.cornerStyle = .fixed
        config.background.cornerRadius = appearance.sendButton.cornerRadius
        config.baseForegroundColor = appearance.sendButton.title
        config.background.backgroundColor = appearance.sendButton.background
        config.title = selected?.displayName ?? (destinations.isEmpty ? "No destinations" : "Choose destination")
        config.image = UIImage(systemName: "chevron.up.chevron.down")
        config.imagePlacement = .trailing
        config.imagePadding = 8
        config.titleLineBreakMode = .byTruncatingTail
        destinationButton.configuration = config
        destinationButton.accessibilityValue = config.title

        destinationButton.menu = UIMenu(children: destinations.map { destination in
            UIAction(title: destination.displayName, state: destination.id == selectedDestinationID ? .on : .off) { [weak self] _ in
                self?.selectedDestinationID = destination.id
                self?.updateDestinations()
            }
        })
        destinationButton.isEnabled = !isSending && !destinations.isEmpty
        sendButton.isEnabled = !isSending && selectedDestinationID != nil
    }

    private func send(_ draft: FeedbackDraft) {
        setSending(true)
        let capture = capture
        Task { [weak self] in
            let saved: SavedFeedback
            do {
                saved = try await Feedback.save(capture, draft: draft)
            } catch {
                self?.fail(error)
                return
            }
            // Saved, so it can't be lost: close the sheet and deliver in the background.
            guard let self else { return }
            let presenter = self.presentingViewController ?? self
            let appearance = self.appearance
            let copy = self.configuration.copy
            self.setSending(false)
            self.dismiss(animated: true)

            let toast: FeedbackToast
            do {
                switch try await Feedback.deliver(saved) {
                case .delivered:
                    toast = FeedbackToast(text: copy.sentToast, kind: .success)
                case .queued:
                    toast = FeedbackToast(text: copy.queuedToast, kind: .info)
                }
            } catch {
                toast = FeedbackToast(text: "\(copy.failedTitle): \(error.localizedDescription)", kind: .error)
            }
            appearance.showToast(presenter, toast)
        }
    }

    private func fail(_ error: Error) {
        setSending(false)
        if let error = error as? FeedbackError {
            switch error {
            case .emptyNote, .missingRequiredFields:
                appearance.showToast(self, FeedbackToast(text: error.localizedDescription, kind: .error))
                return
            default:
                break
            }
        }
        let alert = UIAlertController(
            title: configuration.copy.failedTitle,
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Copy note", style: .default) { [weak self] _ in
            guard let self else { return }
            UIPasteboard.general.string = self.agentPasteboardText()
        })
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    private func setSending(_ sending: Bool) {
        isSending = sending
        updateDestinations()
        screenshotToggle?.isEnabled = !sending
        logsToggle?.isEnabled = !sending
        sendButton.accessibilityLabel = sending ? "Sending…" : configuration.copy.sendButton
        isModalInPresentation = sending
    }
}

private extension Bundle {
    var shortVersion: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    var buildNumber: String { object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
}

extension Optional where Wrapped == [FeedbackEnvironment] {
    /// `nil` means every environment. (Core's `allows` is internal to that module.)
    func allowsEnvironment(_ environment: FeedbackEnvironment) -> Bool {
        self?.contains(environment) ?? true
    }
}
