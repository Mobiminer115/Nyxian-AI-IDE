/*
 SPDX-License-Identifier: AGPL-3.0-or-later
 Copyright (C) 2025 - 2026 emexlab
 This file is part of Nyxian.
*/

import Foundation
import UIKit
import AudioToolbox
import ObjectiveC.runtime

class SymbolButton: UIButton {
    private var actionHandler: (() -> Void)?
    private var longActionHandler: (() -> Void)?
    private var currentAnimator: UIViewPropertyAnimator?

    init(symbolName: String, width: CGFloat, actionHandler: @escaping () -> Void, longActionHandler: (() -> Void)? = nil) {
        self.actionHandler = actionHandler
        self.longActionHandler = longActionHandler
        super.init(frame: .zero)

        if let image = UIImage(systemName: symbolName) {
            setImage(image, for: .normal)
        } else {
            setTitle(symbolName, for: .normal)
            titleLabel?.font = .systemFont(ofSize: 16)
        }

        let theme = LDEThemeReader.shared.currentlySelectedTheme()
        tintColor = theme.textColor
        setTitleColor(theme.textColor, for: .normal)
        addTarget(self, action: #selector(didTap), for: .touchUpInside)

        if longActionHandler != nil {
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
            gesture.minimumPressDuration = 0.5
            addGestureRecognizer(gesture)
        }

        if #unavailable(iOS 26.0) {
            addTarget(self, action: #selector(touchDown), for: .touchDown)
            addTarget(self, action: #selector(touchUp), for: [.touchUpInside, .touchDragExit, .touchCancel])
            layer.cornerRadius = 5
            layer.borderWidth = 1
            layer.borderColor = theme.gutterHairlineColor.cgColor
            backgroundColor = theme.gutterBackgroundColor
        }

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 35)
        ])
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    @objc private func didTap() {
        actionHandler?()
        AudioServicesPlaySystemSound(1104)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func longPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        longActionHandler?()
        AudioServicesPlaySystemSound(1104)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func touchDown() {
        currentAnimator?.stopAnimation(true)
        currentAnimator = UIViewPropertyAnimator(duration: 0.1, curve: .easeInOut) {
            self.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        }
        currentAnimator?.startAnimation()
    }

    @objc private func touchUp() {
        currentAnimator?.stopAnimation(true)
        currentAnimator = UIViewPropertyAnimator(duration: 0.1, curve: .easeInOut) {
            self.transform = .identity
        }
        currentAnimator?.startAnimation()
    }
}

// MARK: - Editor integration

final class CodeEditorAIInstaller {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        guard let original = class_getInstanceMethod(CodeEditorViewController.self, #selector(CodeEditorViewController.viewDidLoad)),
              let replacement = class_getInstanceMethod(CodeEditorViewController.self, #selector(CodeEditorViewController.nyxianAI_viewDidLoad)) else {
            return
        }
        installed = true
        method_exchangeImplementations(original, replacement)
    }
}

extension CodeEditorViewController {
    @objc func nyxianAI_viewDidLoad() {
        // After swizzling, this selector invokes the original implementation.
        nyxianAI_viewDidLoad()
        DispatchQueue.main.async { [weak self] in
            self?.installNyxianAIButton()
        }
    }

    private func installNyxianAIButton() {
        var items = navigationItem.rightBarButtonItems ?? []
        guard !items.contains(where: { $0.accessibilityIdentifier == "nyxian.ai.coding" }) else { return }

        let item = UIBarButtonItem(image: UIImage(systemName: "wand.and.stars"), style: .plain, target: self, action: #selector(nyxianAI_present))
        item.accessibilityIdentifier = "nyxian.ai.coding"
        item.accessibilityLabel = "AI Coding"
        items.insert(item, at: 0)
        navigationItem.setRightBarButtonItems(items, animated: false)
    }

    @objc private func nyxianAI_present() {
        let aiVC = NyxianAICodingViewController(editor: self)
        let nav = UINavigationController(rootViewController: aiVC)
        nav.modalPresentationStyle = UIDevice.current.userInterfaceIdiom == .pad ? .formSheet : .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    private func aiValue<T>(_ name: String, as type: T.Type) -> T? {
        var mirror: Mirror? = Mirror(reflecting: self)
        while let current = mirror {
            if let child = current.children.first(where: { $0.label == name }) {
                let value = child.value
                let childMirror = Mirror(reflecting: value)
                if childMirror.displayStyle == .optional {
                    return childMirror.children.first?.value as? T
                }
                return value as? T
            }
            mirror = current.superclassMirror
        }
        return nil
    }

    fileprivate var nyxianAIText: String {
        aiValue("textView", as: UITextView.self)?.text ?? ""
    }

    fileprivate var nyxianAIFileURL: URL? {
        aiValue("file", as: MDKFile.self)?.fileURL
    }

    fileprivate var nyxianAIProject: NXProject? {
        aiValue("project", as: NXProject.self)
    }

    fileprivate var nyxianAIReadOnly: Bool {
        aiValue("isReadOnly", as: Bool.self) ?? true
    }

    fileprivate func nyxianAIApplyText(_ text: String) {
        guard !nyxianAIReadOnly,
              let textView = aiValue("textView", as: UITextView.self) else { return }
        textView.text = text
        perform(Selector("saveText"))
    }
}

// MARK: - Agent models

private struct NyxianAIReadFile: Codable {
    let path: String
}

private struct NyxianAIOperation: Codable {
    let type: String
    let path: String
    let content: String
}

private struct NyxianAIPlan: Codable {
    let message: String
    let readFiles: [NyxianAIReadFile]
    let operations: [NyxianAIOperation]

    enum CodingKeys: String, CodingKey {
        case message
        case readFiles = "read_files"
        case operations
    }
}

private struct NyxianAIChange {
    let operation: String
    let path: String
}

private final class NyxianAIAgent {
    private let client = NyxianGeminiClient()
    private let fm = FileManager.default

    private let responseSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "message": ["type": "string"],
            "read_files": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["path": ["type": "string"]],
                    "required": ["path"]
                ]
            ],
            "operations": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "type": ["type": "string", "enum": ["write_file", "create_file"]],
                        "path": ["type": "string"],
                        "content": ["type": "string"]
                    ],
                    "required": ["type", "path", "content"]
                ]
            ]
        ],
        "required": ["message", "read_files", "operations"]
    ]

    func run(prompt: String, editor: CodeEditorViewController) async throws -> (String, [NyxianAIChange]) {
        guard let project = editor.nyxianAIProject else {
            throw NSError(domain: "NyxianAIAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "The current editor is not attached to a project."])
        }

        let root = project.url.standardizedFileURL
        var inspected: [String: String] = [:]
        let activePath = editor.nyxianAIFileURL.map { relative($0, root: root) }
        if let activePath {
            if let url = safeURL(activePath, root: root), let diskText = try? String(contentsOf: url, encoding: .utf8) {
                inspected[activePath] = cap(diskText)
            } else {
                inspected[activePath] = cap(editor.nyxianAIText)
            }
        }

        let tree = makeTree(root)
        var lastMessage = ""

        for pass in 0..<6 {
            let promptText = makePrompt(userPrompt: prompt, tree: tree, activePath: activePath, activeText: editor.nyxianAIText, inspected: inspected, lastMessage: lastMessage)
            let raw = try await client.generateJSON(prompt: promptText, systemInstruction: systemInstruction, schema: responseSchema)
            guard let data = raw.data(using: .utf8) else {
                throw NSError(domain: "NyxianAIAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "Gemini returned invalid JSON text."])
            }
            let plan = try JSONDecoder().decode(NyxianAIPlan.self, from: data)
            lastMessage = plan.message

            if !plan.readFiles.isEmpty {
                for request in plan.readFiles.prefix(12) {
                    let path = normalize(request.path)
                    guard let url = safeURL(path, root: root), !isProtected(path), fm.fileExists(atPath: url.path) else { continue }
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    inspected[path] = cap(text, limit: 24000)
                }
                if pass < 5 { continue }
            }

            if plan.operations.isEmpty { return (plan.message, []) }
            return try apply(plan.operations, root: root, editor: editor)
        }

        throw NSError(domain: "NyxianAIAgent", code: 3, userInfo: [NSLocalizedDescriptionKey: "Gemini needed more project inspection than the agent limit allows."])
    }

    private let systemInstruction = """
    You are Nyxian AI Coding Agent inside a mobile IDE. Perform implementation work directly in the project.
    Inspect before editing. Use read_files when another existing file is required for correctness.
    Preserve the existing architecture, public APIs, naming, formatting and license headers.
    Return complete file contents in operations; never return patches or markdown fences.
    Paths are project-relative and must never escape the project root.
    Never request, expose, edit or create secrets, API keys, certificates, signing profiles, .env files, .git internals or build artifacts.
    Never delete files. If deletion is necessary, explain it instead.
    Prefer the smallest coherent change that fully satisfies the user's request.
    The active editor text is authoritative for the active file and may contain unsaved edits.
    """

    private func makePrompt(userPrompt: String, tree: String, activePath: String?, activeText: String, inspected: [String: String], lastMessage: String) -> String {
        var result = "USER TASK:\n\(userPrompt)\n\nPROJECT TREE:\n\(tree)\n\nACTIVE FILE: \(activePath ?? "unknown")\nACTIVE BUFFER:\n---\n\(cap(activeText, limit: 30000))\n---\n"
        if !inspected.isEmpty {
            result += "\nINSPECTED FILES:\n"
            for path in inspected.keys.sorted() {
                result += "\nFILE: \(path)\n---\n\(inspected[path] ?? "")\n---\n"
            }
        }
        if !lastMessage.isEmpty { result += "\nPREVIOUS AGENT MESSAGE: \(lastMessage)\n" }
        result += "\nReturn structured JSON. Request more files before editing when necessary."
        return result
    }

    private func makeTree(_ root: URL) -> String {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return "(unavailable)" }
        var paths: [String] = []
        for case let url as URL in e {
            let path = relative(url, root: root)
            if path.isEmpty || isProtected(path) { continue }
            if path.hasPrefix("build/") || path.hasPrefix("DerivedData/") || path.hasPrefix(".build/") { continue }
            paths.append(path)
            if paths.count >= 300 { break }
        }
        return paths.sorted().joined(separator: "\n")
    }

    private func apply(_ operations: [NyxianAIOperation], root: URL, editor: CodeEditorViewController) throws -> (String, [NyxianAIChange]) {
        var changes: [NyxianAIChange] = []
        let activePath = editor.nyxianAIFileURL.map { relative($0, root: root) }

        guard !editor.nyxianAIReadOnly else {
            throw NSError(domain: "NyxianAIAgent", code: 4, userInfo: [NSLocalizedDescriptionKey: "The active file is read-only, so Nyxian cannot apply AI edits."])
        }

        for operation in operations.prefix(20) {
            let path = normalize(operation.path)
            guard !path.isEmpty, !isProtected(path), let destination = safeURL(path, root: root) else { continue }
            guard operation.content.utf8.count <= 1_000_000 else {
                throw NSError(domain: "NyxianAIAgent", code: 5, userInfo: [NSLocalizedDescriptionKey: "AI tried to write a file larger than 1 MB: \(path)"])
            }

            if fm.fileExists(atPath: destination.path), let old = try? Data(contentsOf: destination) {
                try backup(old, root: root, path: path)
            }

            if path == activePath {
                editor.nyxianAIApplyText(operation.content)
            } else {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try operation.content.write(to: destination, atomically: true, encoding: .utf8)
            }
            changes.append(NyxianAIChange(operation: operation.type, path: path))
        }
        return ("Applied the requested code changes.", changes)
    }

    private func backup(_ data: Data, root: URL, path: String) throws {
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NyxianAIBackups", isDirectory: true)
            .appendingPathComponent(root.lastPathComponent, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = dir.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    private func normalize(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .filter { !$0.isEmpty && $0 != "." }
            .reduce(into: [String]()) { result, component in
                if component == ".." { if !result.isEmpty { result.removeLast() } } else { result.append(String(component)) }
            }
            .joined(separator: "/")
    }

    private func safeURL(_ path: String, root: URL) -> URL? {
        let normalized = normalize(path)
        guard !normalized.isEmpty, !normalized.hasPrefix("/") else { return nil }
        let rootURL = root.standardizedFileURL
        let candidate = rootURL.appendingPathComponent(normalized).standardizedFileURL
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard candidate.path == rootURL.path || candidate.path.hasPrefix(prefix) else { return nil }
        return candidate
    }

    private func relative(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return url.lastPathComponent }
        var result = String(filePath.dropFirst(rootPath.count))
        if result.hasPrefix("/") { result.removeFirst() }
        return result
    }

    private func isProtected(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower == ".git" || lower.hasPrefix(".git/") || lower.hasPrefix(".build/") || lower.hasPrefix("deriveddata/") || lower.hasPrefix("build/") { return true }
        if lower == ".env" || lower.hasPrefix(".env.") || lower.hasPrefix("project.xcworkspace/xcuserdata/") { return true }
        return [".p12", ".pfx", ".mobileprovision", ".cer", ".pem", ".key"].contains(where: { lower.hasSuffix($0) })
    }

    private func cap(_ value: String, limit: Int = 30000) -> String {
        value.count <= limit ? value : String(value.prefix(limit)) + "\n… truncated by Nyxian …"
    }
}

// MARK: - AI panel

@MainActor
final class NyxianAICodingViewController: UIViewController {
    private let editor: CodeEditorViewController
    private let transcript = UITextView()
    private let promptView = UITextView()
    private let sendButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var running = false

    init(editor: CodeEditorViewController) {
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
        title = "AI Coding"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = currentTheme?.backgroundColor ?? .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(closePanel))

        let model = UILabel()
        model.text = "Gemini · \(NyxianAIConfiguration.model)"
        model.textColor = .secondaryLabel
        model.font = .preferredFont(forTextStyle: .caption1)

        let state = UILabel()
        state.numberOfLines = 0
        state.font = .preferredFont(forTextStyle: .footnote)
        state.textColor = .secondaryLabel
        state.text = "AI can inspect project files and apply code directly. Existing files are backed up before overwrite."

        transcript.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.backgroundColor = currentTheme?.gutterBackgroundColor ?? .secondarySystemBackground
        transcript.textColor = currentTheme?.textColor ?? .label
        transcript.layer.cornerRadius = 14
        transcript.text = "Describe what you want Nyxian to implement."

        promptView.font = .preferredFont(forTextStyle: .body)
        promptView.backgroundColor = currentTheme?.gutterBackgroundColor ?? .secondarySystemBackground
        promptView.textColor = currentTheme?.textColor ?? .label
        promptView.layer.cornerRadius = 14
        promptView.layer.borderWidth = 1
        promptView.layer.borderColor = UIColor.separator.cgColor
        promptView.autocorrectionType = .no

        sendButton.configuration = .filled()
        sendButton.configuration?.title = "Send"
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        spinner.hidesWhenStopped = true

        [model, state, transcript, promptView, sendButton, spinner].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        let stack = UIStackView(arrangedSubviews: [model, state, transcript, promptView])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        view.addSubview(sendButton)
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            transcript.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            promptView.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
            sendButton.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 10),
            sendButton.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            sendButton.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            sendButton.heightAnchor.constraint(equalToConstant: 48),
            sendButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            spinner.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: sendButton.trailingAnchor, constant: -16)
        ])

        if NyxianAIConfiguration.apiKey == nil {
            sendButton.isEnabled = false
            append("\n⚠️ Configure Gemini API key in Settings → AI Coding first.")
        }
    }

    @objc private func closePanel() { dismiss(animated: true) }

    @objc private func send() {
        guard !running else { return }
        let text = promptView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        running = true
        sendButton.isEnabled = false
        spinner.startAnimating()
        promptView.text = ""
        promptView.resignFirstResponder()
        append("\n\n> \(text)\n\nThinking…")

        Task { [weak self] in
            do {
                let result = try await NyxianAIAgent().run(prompt: text, editor: editor)
                await MainActor.run {
                    self?.append("\n\n✓ \(result.0)")
                    if !result.1.isEmpty {
                        self?.append("\n\nChanged files:\n" + result.1.map { "• \($0.path)" }.joined(separator: "\n"))
                    }
                }
            } catch {
                await MainActor.run { self?.append("\n\n❌ \(error.localizedDescription)") }
            }
            await MainActor.run {
                self?.running = false
                self?.sendButton.isEnabled = NyxianAIConfiguration.apiKey != nil
                self?.spinner.stopAnimating()
            }
        }
    }

    private func append(_ text: String) {
        transcript.text += text
        transcript.scrollRangeToVisible(NSRange(location: transcript.text.utf16.count, length: 0))
    }
}
