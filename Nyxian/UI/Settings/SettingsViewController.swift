/*
 SPDX-License-Identifier: AGPL-3.0-or-later
 Copyright (C) 2025 - 2026 emexlab
 This file is part of Nyxian.
*/

import Foundation
import UIKit
import Security

// MARK: - Secret storage

enum NyxianKeychain {
    private static let service = "com.nyxian.ide.gemini"
    private static let account = "api-key"

    static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static func saveAPIKey(_ value: String) throws {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { deleteAPIKey(); return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(clean.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let update = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var add = base
            attributes.forEach { add[$0.key] = $0.value }
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw keychainError(status) }
        } else if update != errSecSuccess {
            throw keychainError(update)
        }
    }

    static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func keychainError(_ status: OSStatus) -> Error {
        NSError(domain: "NyxianKeychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Unable to store the Gemini API key in Keychain."])
    }
}

struct NyxianAIConfiguration {
    static let defaultModel = "gemini-3.6-flash"
    private static let modelKey = "Nyxian.Gemini.Model"

    static var apiKey: String? { NyxianKeychain.readAPIKey() }

    static var model: String {
        let saved = UserDefaults.standard.string(forKey: modelKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return saved?.isEmpty == false ? saved! : defaultModel
    }

    static func save(model: String, apiKey: String) throws {
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanModel.isEmpty else {
            throw NSError(domain: "NyxianAISettings", code: 1, userInfo: [NSLocalizedDescriptionKey: "A Gemini model name is required."])
        }
        UserDefaults.standard.set(cleanModel, forKey: modelKey)
        try NyxianKeychain.saveAPIKey(apiKey)
    }
}

// MARK: - Gemini REST client

private struct GeminiResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { let text: String? }
            let parts: [Part]?
        }
        let content: Content?
    }
    let candidates: [Candidate]?
}

private struct GeminiErrorResponse: Decodable {
    struct Detail: Decodable { let message: String? }
    let error: Detail?
}

final class NyxianGeminiClient {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func generateJSON(prompt: String, systemInstruction: String, schema: [String: Any], model: String = NyxianAIConfiguration.model, apiKey: String? = NyxianAIConfiguration.apiKey) async throws -> String {
        guard let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw NSError(domain: "NyxianGemini", code: 401, userInfo: [NSLocalizedDescriptionKey: "Gemini API key is not configured. Open Settings → AI Coding."])
        }
        guard let encoded = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encoded):generateContent") else {
            throw NSError(domain: "NyxianGemini", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini model name."])
        }

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemInstruction]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": schema
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "NyxianGemini", code: -1, userInfo: [NSLocalizedDescriptionKey: "Gemini returned an invalid HTTP response."])
        }
        guard (200..<300).contains(http.statusCode) else {
            if let error = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data), let message = error.error?.message {
                throw NSError(domain: "NyxianGemini", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            }
            throw NSError(domain: "NyxianGemini", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Gemini request failed."])
        }

        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        guard let text = decoded.candidates?.first?.content?.parts?.compactMap(\.text).first, !text.isEmpty else {
            throw NSError(domain: "NyxianGemini", code: 204, userInfo: [NSLocalizedDescriptionKey: "Gemini returned no text content."])
        }
        return text
    }

    func testConnection() async throws {
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["ok": ["type": "boolean"]],
            "required": ["ok"]
        ]
        _ = try await generateJSON(prompt: "Return ok=true.", systemInstruction: "Return only the requested JSON.", schema: schema)
    }
}

// MARK: - Settings

class SettingsViewController: UIThemedTableViewController {
    init() { super.init(style: .insetGrouped) }
    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() { super.viewDidLoad(); title = "Settings" }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
#if DEBUG
        return NXApplicationState.extensionLessMode ? 4 : 7
#else
        return NXApplicationState.extensionLessMode ? 4 : 6
#endif
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.accessoryType = .disclosureIndicator
        switch indexPath.row {
        case 0: cell.imageView?.image = UIImage(systemName: "wrench.adjustable.fill"); cell.textLabel?.text = "Toolchain"
        case 1:
            if NXApplicationState.extensionLessMode { cell.imageView?.image = UIImage(systemName: "paintbrush.fill"); cell.textLabel?.text = "Customization" }
            else { cell.imageView?.image = UIImage(systemName: "bolt.shield.fill"); cell.textLabel?.text = "Management" }
        case 2:
            if NXApplicationState.extensionLessMode { cell.imageView?.image = UIImage(systemName: "person.3.fill"); cell.textLabel?.text = "Credits" }
            else { cell.imageView?.image = UIImage(systemName: "app.badge.fill"); cell.textLabel?.text = "Applications" }
        case 3:
            if NXApplicationState.extensionLessMode { cell.imageView?.image = UIImage(systemName: "sparkles"); cell.textLabel?.text = "AI Coding" }
            else { cell.imageView?.image = UIImage(systemName: "paintbrush.fill"); cell.textLabel?.text = "Customization" }
#if DEBUG
        case 4:
            if NXApplicationState.extensionLessMode { cell.imageView?.image = UIImage(systemName: "sparkles"); cell.textLabel?.text = "AI Coding" }
            else { cell.imageView?.image = UIImage(systemName: "ant.fill"); cell.textLabel?.text = "Debug" }
        case 5:
            if NXApplicationState.extensionLessMode { cell.imageView?.image = UIImage(systemName: "sparkles"); cell.textLabel?.text = "AI Coding" }
            else { cell.imageView?.image = UIImage(systemName: "person.3.fill"); cell.textLabel?.text = "Credits" }
        case 6: cell.imageView?.image = UIImage(systemName: "sparkles"); cell.textLabel?.text = "AI Coding"
#else
        case 4:
            if NXApplicationState.extensionLessMode { cell.imageView?.image = UIImage(systemName: "sparkles"); cell.textLabel?.text = "AI Coding" }
            else { cell.imageView?.image = UIImage(systemName: "person.3.fill"); cell.textLabel?.text = "Credits" }
        case 5: cell.imageView?.image = UIImage(systemName: "sparkles"); cell.textLabel?.text = "AI Coding"
#endif
        default: break
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let controller: UIViewController?
        switch indexPath.row {
        case 0: controller = ToolChainViewController(style: .insetGrouped)
        case 1: controller = NXApplicationState.extensionLessMode ? CustomizationViewController(style: .insetGrouped) : ManagementViewController(style: .insetGrouped)
        case 2: controller = NXApplicationState.extensionLessMode ? CreditsViewController(style: .insetGrouped) : ApplicationManagementViewController.shared
        case 3: controller = NXApplicationState.extensionLessMode ? NyxianAICodingSettingsViewController(style: .insetGrouped) : CustomizationViewController(style: .insetGrouped)
#if DEBUG
        case 4: controller = NXApplicationState.extensionLessMode ? NyxianAICodingSettingsViewController(style: .insetGrouped) : DebugToolboxViewController()
        case 5: controller = NXApplicationState.extensionLessMode ? NyxianAICodingSettingsViewController(style: .insetGrouped) : CreditsViewController(style: .insetGrouped)
        case 6: controller = NyxianAICodingSettingsViewController(style: .insetGrouped)
#else
        case 4: controller = NXApplicationState.extensionLessMode ? NyxianAICodingSettingsViewController(style: .insetGrouped) : CreditsViewController(style: .insetGrouped)
        case 5: controller = NyxianAICodingSettingsViewController(style: .insetGrouped)
#endif
        default: controller = nil
        }
        if let controller { navigationController?.pushViewController(controller, animated: true) }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "\(Bundle.main.infoDictionary?[\"CFBundleName\"] as? String ?? \"Nyxian\") \(Bundle.main.infoDictionary?[\"CFBundleShortVersionString\"] as? String ?? \"Unknown\") \"Scriptura\" Beta (\(Bundle.main.infoDictionary?[\"CFBundleVersion\"] as? String ?? \"Unknown\"))"
    }
}

// MARK: - AI settings

final class NyxianAICodingSettingsViewController: UITableViewController {
    private let apiKeyField = UITextField()
    private let modelField = UITextField()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(style: UITableView.Style) { super.init(style: style); title = "AI Coding" }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = currentTheme?.backgroundColor ?? .systemBackground
        tableView.keyboardDismissMode = .interactive
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "GeminiSettingCell")

        apiKeyField.placeholder = "Gemini API key"
        apiKeyField.isSecureTextEntry = true
        apiKeyField.autocorrectionType = .no
        apiKeyField.autocapitalizationType = .none
        apiKeyField.clearButtonMode = .whileEditing
        apiKeyField.text = NyxianAIConfiguration.apiKey

        modelField.placeholder = NyxianAIConfiguration.defaultModel
        modelField.autocorrectionType = .no
        modelField.autocapitalizationType = .none
        modelField.text = NyxianAIConfiguration.model
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        apiKeyField.text = NyxianAIConfiguration.apiKey
        modelField.text = NyxianAIConfiguration.model
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 2 : 3 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: "GeminiSettingCell")
        cell.selectionStyle = .none
        if indexPath.section == 0 {
            let field = indexPath.row == 0 ? apiKeyField : modelField
            field.translatesAutoresizingMaskIntoConstraints = false
            field.textColor = currentTheme?.textColor ?? .label
            cell.contentView.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
                field.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
                field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
                field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
                field.heightAnchor.constraint(greaterThanOrEqualToConstant: 36)
            ])
            return cell
        }

        switch indexPath.row {
        case 0: cell.textLabel?.text = "Save Gemini configuration"; cell.textLabel?.textColor = .systemBlue
        case 1:
            cell.textLabel?.text = "Test connection"
            cell.textLabel?.textColor = .systemBlue
            spinner.hidesWhenStopped = true
            cell.accessoryView = spinner
        case 2: cell.textLabel?.text = "Remove API key"; cell.textLabel?.textColor = .systemRed
        default: break
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "Gemini" : "Actions" }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 {
            return NyxianAIConfiguration.apiKey == nil
                ? "Enter a Gemini API key. Nyxian stores it in the iOS Keychain and never saves it inside your project. Current model: \(NyxianAIConfiguration.model)."
                : "Gemini is configured. API key is stored in the iOS Keychain. Current model: \(NyxianAIConfiguration.model)."
        }
        return "AI Coding can inspect project files and apply complete file changes directly to the current project. Existing files are backed up before overwrite."
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        switch indexPath.row {
        case 0: saveConfiguration()
        case 1: saveConfiguration(showAlert: false) { [weak self] in self?.testConnection() }
        case 2:
            NyxianKeychain.deleteAPIKey()
            apiKeyField.text = nil
            tableView.reloadData()
            alert("API key removed", "The Gemini API key is no longer configured.")
        default: break
        }
    }

    private func saveConfiguration(showAlert: Bool = true, completion: (() -> Void)? = nil) {
        let key = apiKeyField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = modelField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { alert("Missing API key", "Enter your Gemini API key first."); return }
        guard !model.isEmpty else { alert("Missing model", "Enter a Gemini model name."); return }
        do {
            try NyxianAIConfiguration.save(model: model, apiKey: key)
            tableView.reloadData()
            if showAlert { alert("Saved", "Gemini AI Coding is ready.") }
            completion?()
        } catch { alert("Could not save", error.localizedDescription) }
    }

    private func testConnection() {
        spinner.startAnimating()
        Task { [weak self] in
            do {
                try await NyxianGeminiClient().testConnection()
                await MainActor.run {
                    self?.spinner.stopAnimating()
                    self?.tableView.reloadData()
                    self?.alert("Gemini connected", "The configured Gemini model accepted the API key.")
                }
            } catch {
                await MainActor.run {
                    self?.spinner.stopAnimating()
                    self?.alert("Gemini connection failed", error.localizedDescription)
                }
            }
        }
    }

    private func alert(_ title: String, _ message: String) {
        let controller = UIAlertController(title: title, message: message, preferredStyle: .alert)
        controller.addAction(UIAlertAction(title: "OK", style: .default))
        present(controller, animated: true)
    }
}
