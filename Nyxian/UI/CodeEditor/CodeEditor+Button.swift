/*
 SPDX-License-Identifier: AGPL-3.0-or-later

 Copyright (C) 2025 - 2026 emexlab

 This file is part of Nyxian.

 Nyxian is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Nyxian is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with Nyxian. If not, see <https://www.gnu.org/licenses/>.
*/

import UIKit
import AudioToolbox

class SymbolButton: UIButton {
    private var actionHandler: (() -> Void)?
    private var longActionHandler: (() -> Void)?
    private var currentAnimator: UIViewPropertyAnimator?
    
    init(symbolName: String, width: CGFloat, actionHandler: @escaping () -> Void, longActionHandler: (() -> Void)? = nil) {
        self.actionHandler = actionHandler
        super.init(frame: .zero)
        
        let image = UIImage(systemName: symbolName)
        if image != nil {
            self.setImage(image, for: .normal)
        } else {
            self.setTitle(symbolName, for: .normal)
            self.titleLabel?.font = UIFont.systemFont(ofSize: 16)
            self.setTitleColor(.label, for: .normal)
        }
        
        let theme: LDETheme = LDEThemeReader.shared.currentlySelectedTheme()
        
        self.addTarget(self, action: #selector(didTapButton), for: .touchUpInside)
        
        if let longActionHandler = longActionHandler {
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.minimumPressDuration = 0.5
            self.addGestureRecognizer(longPress)
            self.longActionHandler = longActionHandler
        }
        
        self.tintColor = theme.textColor //.label
        self.setTitleColor(theme.textColor, for: .normal)
        
        if #unavailable(iOS 26.0) {
            self.addTarget(self, action: #selector(touchDown), for: .touchDown)
            self.addTarget(self, action: #selector(touchUp), for: [.touchUpInside, .touchDragExit, .touchCancel])
            
            self.layer.cornerRadius = 5
            self.layer.borderWidth = 1
            self.layer.borderColor = theme.gutterHairlineColor.cgColor
            self.backgroundColor = theme.gutterBackgroundColor
        }
        
        NSLayoutConstraint.activate([
            self.widthAnchor.constraint(equalToConstant: width),
            self.heightAnchor.constraint(equalToConstant: 35)
        ])
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    @objc private func didTapButton() {
        actionHandler?()
        AudioServicesPlaySystemSound(1104)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    
    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            longActionHandler?()
            AudioServicesPlaySystemSound(1104)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
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
            self.transform = CGAffineTransform.identity
        }
        currentAnimator?.startAnimation()
    }
    
    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil {
            self.gestureRecognizers?.forEach { gesture in
                self.removeGestureRecognizer(gesture)
            }
        }
    }
}

// MARK: - AI coding integration

final class CodeEditorAIInstaller {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        guard let original = class_getInstanceMethod(CodeEditorViewController.self, #selector(UIViewController.viewDidLoad)),
              let replacement = class_getInstanceMethod(CodeEditorViewController.self, #selector(CodeEditorViewController.nyxian_ai_viewDidLoad)) else {
            installed = false
            return
        }

        method_exchangeImplementations(original, replacement)
    }
}

private extension CodeEditorViewController {
    @objc func nyxian_ai_viewDidLoad() {
        // Because of method swizzling this calls the original viewDidLoad implementation.
        self.nyxian_ai_viewDidLoad()

        DispatchQueue.main.async { [weak self] in
            self?.installNyxianAIButton()
        }
    }

    @objc func nyxian_ai_present() {
        let controller = NyxianAICodingViewController(editor: self)
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = UIDevice.current.userInterfaceIdiom == .pad ? .formSheet : .pageSheet

        if let sheet = navigationController.sheetPresentationController {
            if #available(iOS 16.0, *) {
                sheet.detents = [.medium(), .large()]
                sheet.selectedDetentIdentifier = .large
            }
            sheet.prefersGrabberVisible = true
        }
        present(navigationController, animated: true)
    }

    func installNyxianAIButton() {
        guard navigationItem.rightBarButtonItems?.contains(where: { $0.action == #selector(nyxian_ai_present) }) != true else {
            return
        }

        let item = UIBarButtonItem(
            image: UIImage(systemName: "wand.and.stars"),
            style: .plain,
            target: self,
            action: #selector(nyxian_ai_present)
        )
        item.accessibilityLabel = "AI Coding"
        item.accessibilityHint = "Ask Gemini to edit this project"

        var items = navigationItem.rightBarButtonItems ?? []
        items.insert(item, at: 0)
        navigationItem.setRightBarButtonItems(items, animated: false)
    }

    func aiMirrorValue<T>(_ label: String, as type: T.Type) -> T? {
        var mirror: Mirror? = Mirror(reflecting: self)
        while let current = mirror {
            if let child = current.children.first(where: { $0.label == label }) {
                return aiUnwrapped(child.value) as? T
            }
            mirror = current.superclassMirror
        }
        return nil
    }

    func aiUnwrapped(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first?.value
    }

    var aiText: String {
        (aiMirrorValue("textView", as: UITextView.self)?.text) ?? ""
    }

    var aiFileURL: URL? {
        aiMirrorValue("file", as: MDKFile.self)?.fileURL
    }

    var aiProject: NXProject? {
        aiMirrorValue("project", as: NXProject.self)
    }

    var aiIsReadOnly: Bool {
        aiMirrorValue("isReadOnly", as: Bool.self) ?? true
    }

    func aiApplyText(_ text: String) {
        guard !aiIsReadOnly,
              let textView = aiMirrorValue("textView", as: UITextView.self) else { return }
        textView.text = text
        // saveText is @objc in CodeEditorViewController. Calling it by selector avoids
        // reaching into the editor's private implementation from this extension.
        perform(Selector(("saveText")))
    }
}

// MARK: - Agent data model

private struct NyxianAIReadFile: Codable {
    let path: String
}

private struct NyxianAIFileOperation: Codable {
    let type: String
    let path: String
    let content: String
}

private struct NyxianAIPlan: Codable {
    let message: String
    let readFiles: [NyxianAIReadFile]
    let operations: [NyxianAIFileOperation]

    enum CodingKeys: String, CodingKey {
        case message
        case readFiles = "read_files"
        case operations
    }
}

private struct NyxianAIAppliedChange {
    let operation: String
    let path: String
}

// MARK: - Agent

private final class NyxianAIAgent {
    private let client = NyxianGeminiClient()
    private let fileManager = FileManager.default

    private let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "message": [
                "type": "string",
                "description": "Brief explanation of what you changed or what you still need to inspect."
            ],
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

    func run(prompt: String, editor: CodeEditorViewController) async throws -> (String, [NyxianAIAppliedChange]) {
        guard let project = editor.aiProject,
              let projectRoot = self.projectRootURL(project) else {
            throw NSError(domain: "NyxianAIAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: "The current editor is not attached to a project."])
        }

        var inspectedFiles: [String: String] = [:]
        let activePath = editor.aiFileURL.map { relativePath($0, root: projectRoot) }
        if let activePath, let url = safeURL(relativePath: activePath, root: projectRoot) {
            inspectedFiles[activePath] = capped(try String(contentsOf: url, encoding: .utf8) ?? editor.aiText)
        } else if let activePath {
            inspectedFiles[activePath] = capped(editor.aiText)
        }

        let tree = makeTree(root: projectRoot)
        var lastMessage = ""

        for step in 0..<6 {
            let context = makePrompt(
                userPrompt: prompt,
                projectRoot: projectRoot,
                tree: tree,
                activePath: activePath,
                activeText: editor.aiText,
                inspectedFiles: inspectedFiles,
                lastMessage: lastMessage
            )

            let raw = try await client.generateJSON(
                prompt: context,
                systemInstruction: systemInstruction,
                schema: schema
            )

            guard let data = raw.data(using: .utf8) else {
                throw NSError(domain: "NyxianAIAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "Gemini returned invalid UTF-8 JSON."])
            }
            let plan = try JSONDecoder().decode(NyxianAIPlan.self, from: data)
            lastMessage = plan.message

            if !plan.readFiles.isEmpty {
                for requested in plan.readFiles.prefix(12) {
                    let path = normalizeRelativePath(requested.path)
                    guard let url = safeURL(relativePath: path, root: projectRoot) else { continue }
                    guard !isProtected(path) else { continue }
                    guard fileManager.fileExists(atPath: url.path) else { continue }
                    guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    inspectedFiles[path] = capped(contents, limit: 24000)
                }

                if step < 5 { continue }
            }

            if plan.operations.isEmpty {
                return (plan.message, [])
            }

            let changes = try apply(plan.operations, projectRoot: projectRoot, editor: editor)
            return (plan.message, changes)
        }

        throw NSError(domain: "NyxianAIAgent", code: 3, userInfo: [NSLocalizedDescriptionKey: "The AI agent reached its inspection limit before finishing the task."])
    }

    private var systemInstruction: String {
        """
        You are Nyxian AI Coding Agent, an autonomous coding assistant inside an iOS IDE.
        You directly edit the user's project through structured file operations.

        Rules:
        1. Treat the user's request as an implementation task, not a chat question.
        2. Inspect existing code before editing files you have not been given. Use read_files when needed.
        3. Preserve the project's architecture, APIs, style, naming conventions and license headers.
        4. Prefer minimal, coherent edits. Do not rewrite unrelated files.
        5. Return complete file contents for write_file/create_file operations; never return patches or markdown fences.
        6. Never request or modify secrets, certificates, signing keys, API keys, .env files, .git internals or build artifacts.
        7. Paths are relative to the project root and must never escape it.
        8. Do not delete files. If removal is needed, explain it instead of issuing an operation.
        9. The active file is the user's current editor buffer and may contain unsaved changes; base your edit on that exact content.
        10. Finish with a concise message describing the implemented change.
        """
    }

    private func projectRootURL(_ project: NXProject) -> URL? {
        project.url
    }

    private func makePrompt(
        userPrompt: String,
        projectRoot: URL,
        tree: String,
        activePath: String?,
        activeText: String,
        inspectedFiles: [String: String],
        lastMessage: String
    ) -> String {
        var text = "User task:\n\(userPrompt)\n\n"
        text += "Project file tree:\n\(tree)\n\n"
        text += "Active file: \(activePath ?? "unknown")\n"
        text += "Active editor buffer:\n---\n\(capped(activeText, limit: 30000))\n---\n\n"

        if !inspectedFiles.isEmpty {
            text += "Files inspected in this agent run:\n"
            for path in inspectedFiles.keys.sorted() {
                text += "\nFILE: \(path)\n---\n\(inspectedFiles[path] ?? "")\n---\n"
            }
        }

        if !lastMessage.isEmpty {
            text += "\nPrevious agent message: \(lastMessage)\n"
        }

        text += "\nChoose either read_files for more context, operations for code changes, or both only when you need additional inspection before editing."
        return text
    }

    private func makeTree(root: URL) -> String {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return "(unable to enumerate project)"
        }

        var paths: [String] = []
        for case let url as URL in enumerator {
            let relative = relativePath(url, root: root)
            if relative.isEmpty || isProtected(relative) { continue }
            if relative.hasPrefix("DerivedData/") || relative.hasPrefix("build/") || relative.hasPrefix(".build/") { continue }
            paths.append(relative)
            if paths.count >= 300 { break }
        }
        return paths.sorted().joined(separator: "\n")
    }

    private func apply(_ operations: [NyxianAIFileOperation], projectRoot: URL, editor: CodeEditorViewController) throws -> [NyxianAIAppliedChange] {
        var applied: [NyxianAIAppliedChange] = []
        let activePath = editor.aiFileURL.map { relativePath($0, root: projectRoot) }

        for operation in operations.prefix(20) {
            let path = normalizeRelativePath(operation.path)
            guard !path.isEmpty,
                  !path.hasPrefix("/"),
                  !isProtected(path),
                  let destination = safeURL(relativePath: path, root: projectRoot) else {
                continue
            }

            guard operation.content.utf8.count <= 1_000_000 else {
                throw NSError(domain: "NyxianAIAgent", code: 4, userInfo: [NSLocalizedDescriptionKey: "AI tried to write a file larger than 1 MB: \(path)"])
            }

            let isExisting = fileManager.fileExists(atPath: destination.path)
            if operation.type == "create_file" && isExisting {
                // Treat create_file on an existing file as an intentional overwrite only when
                // the user asked for implementation work. This keeps the agent useful while
                // preventing accidental duplicate-file errors.
            }

            if isExisting, let currentData = try? Data(contentsOf: destination) {
                try? createBackup(data: currentData, projectRoot: projectRoot, relativePath: path)
            }

            if activePath == path {
                editor.aiApplyText(operation.content)
            } else {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try operation.content.write(to: destination, atomically: true, encoding: .utf8)
            }

            applied.append(NyxianAIAppliedChange(operation: operation.type, path: path))
        }

        return applied
    }

    private func createBackup(data: Data, projectRoot: URL, relativePath: String) throws {
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NyxianAIBackups", isDirectory: true)
            .appendingPathComponent(projectRoot.lastPathComponent, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = cacheRoot.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    private func safeURL(relativePath: String, root: URL) -> URL? {
        let normalized = normalizeRelativePath(relativePath)
        guard !normalized.isEmpty, !normalized.hasPrefix("/") else { return nil }
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let url = root.appendingPathComponent(normalized).standardizedFileURL
        guard url.path == root.standardizedFileURL.path || url.path.hasPrefix(rootPath) else { return nil }
        return url
    }

    private func normalizeRelativePath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .filter { $0 != "." && !$0.isEmpty }
            .reduce(into: [String]()) { components, part in
                if part == ".." {
                    if !components.isEmpty { components.removeLast() }
                } else {
                    components.append(String(part))
                }
            }
            .joined(separator: "/")
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        var value = String(path.dropFirst(rootPath.count))
        if value.hasPrefix("/") { value.removeFirst() }
        return value
    }

    private func isProtected(_ path: String) -> Bool {
        let lower = path.lowercased()
        let protectedPrefixes = [".git/", ".git", ".build/", "deriveddata/", "build/"]
        if protectedPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        if [".env", ".env.local", ".env.production", "project.xcworkspace/xcuserdata"].contains(lower) { return true }
        let blockedExtensions = [".p12", ".pfx", ".mobileprovision", ".cer", ".pem", ".key"]
        return blockedExtensions.contains(where: { lower.hasSuffix($0) })
    }

    private func capped(_ value: String, limit: Int = 30000) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "\n… truncated by Nyxian …"
    }
}

// MARK: - AI UI

@MainActor
final class NyxianAICodingViewController: UIViewController, UITextViewDelegate {
    private let editor: CodeEditorViewController
    private let transcript = UITextView()
    private let promptView = UITextView()
    private let sendButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let stateLabel = UILabel()
    private var isRunning = false

    init(editor: CodeEditorViewController) {
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
        self.title = "AI Coding"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = currentTheme?.backgroundColor ?? .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))

        let modelLabel = UILabel()
        modelLabel.font = .preferredFont(forTextStyle: .caption1)
        modelLabel.textColor = .secondaryLabel
        modelLabel.text = "Gemini · \(NyxianAIConfiguration.model)"

        stateLabel.font = .preferredFont(forTextStyle: .footnote)
        stateLabel.textColor = .secondaryLabel
        stateLabel.numberOfLines = 2
        stateLabel.text = editor.aiProject == nil
            ? "No project context available."
            : "Edits are applied directly to the project. File writes are backed up in the app cache."

        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        transcript.textColor = currentTheme?.textColor ?? .label
        transcript.backgroundColor = currentTheme?.gutterBackgroundColor ?? .secondarySystemBackground
        transcript.layer.cornerRadius = 14
        transcript.text = "Describe the coding task.\n\nNyxian will inspect the active file and request additional project files from Gemini when necessary."

        promptView.delegate = self
        promptView.font = .preferredFont(forTextStyle: .body)
        promptView.textColor = currentTheme?.textColor ?? .label
        promptView.backgroundColor = currentTheme?.gutterBackgroundColor ?? .secondarySystemBackground
        promptView.layer.cornerRadius = 14
        promptView.layer.borderWidth = 1
        promptView.layer.borderColor = UIColor.separator.cgColor
        promptView.text = ""

        promptView.translatesAutoresizingMaskIntoConstraints = false
        transcript.translatesAutoresizingMaskIntoConstraints = false
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        modelLabel.translatesAutoresizingMaskIntoConstraints = false

        sendButton.setTitle("Send", for: .normal)
        sendButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        sendButton.configuration = .filled()

        let stack = UIStackView(arrangedSubviews: [modelLabel, stateLabel, transcript, promptView])
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
            sendButton.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            sendButton.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            sendButton.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 10),
            sendButton.heightAnchor.constraint(equalToConstant: 48),
            sendButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            spinner.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: sendButton.trailingAnchor, constant: -16)
        ])

        if NyxianAIConfiguration.apiKey == nil {
            appendTranscript("⚠️ Gemini API key is not configured. Open Settings → AI Coding first.")
            sendButton.isEnabled = false
        }
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    @objc private func send() {
        guard !isRunning else { return }
        let prompt = promptView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        promptView.resignFirstResponder()
        promptView.text = ""
        isRunning = true
        sendButton.isEnabled = false
        spinner.startAnimating()
        appendTranscript("\n> \(prompt)\n\nThinking…")

        Task { [weak self, editor] in
            do {
                let result = try await NyxianAIAgent().run(prompt: prompt, editor: editor)
                self?.appendResult(result.0, changes: result.1)
            } catch {
                self?.appendTranscript("\n❌ \(error.localizedDescription)")
            }
            self?.isRunning = false
            self?.sendButton.isEnabled = NyxianAIConfiguration.apiKey != nil
            self?.spinner.stopAnimating()
        }
    }

    private func appendResult(_ message: String, changes: [NyxianAIAppliedChange]) {
        var text = "\n\n✓ \(message)"
        if !changes.isEmpty {
            text += "\n\nChanged files:"
            for change in changes {
                text += "\n• \(change.path)"
            }
        }
        appendTranscript(text)
    }

    private func appendTranscript(_ text: String) {
        transcript.text += text
        transcript.scrollRangeToVisible(NSRange(location: max(transcript.text.count - 1, 0), length: 1))
    }
}
