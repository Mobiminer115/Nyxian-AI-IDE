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
import Security

// MARK: - Gemini configuration

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
              !value.isEmpty else {
            return nil
        }
        return value
    }

    static func saveAPIKey(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            deleteAPIKey()
            return
        }

        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: "NyxianKeychain", code: Int(addStatus), userInfo: [NSLocalizedDescriptionKey: "Unable to save Gemini API key to Keychain."])
            }
        } else if updateStatus != errSecSuccess {
            throw NSError(domain: "NyxianKeychain", code: Int(updateStatus), userInfo: [NSLocalizedDescriptionKey: "Unable to update Gemini API key in Keychain."])
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
}

struct NyxianAIConfiguration {
    static let defaultModel = "gemini-3.6-flash"
    private static let modelDefaultsKey = "Nyxian.Gemini.Model"

    static var apiKey: String? {
        NyxianKeychain.readAPIKey()
    }

    static var model: String {
        let saved = UserDefaults.standard.string(forKey: modelDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (saved?.isEmpty == false) ? saved! : defaultModel
    }

    static func save(model: String, apiKey: String) throws {
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelDefaultsKey)
        try NyxianKeychain.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Gemini REST client

struct GeminiAgentResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }
            let parts: [Part]?
        }
        let content: Content?
    }
    let candidates: [Candidate]?
}

struct GeminiAPIErrorPayload: Decodable {
    struct APIError: Decodable {
        let message: String?
        let status: String?
    }
    let error: APIError?
}

final class NyxianGeminiClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func generateJSON(
        prompt: String,
        systemInstruction: String,
        schema: [String: Any],
        model: String = NyxianAIConfiguration.model,
        apiKey: String? = NyxianAIConfiguration.apiKey
    ) async throws -> String {
        guard let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw NSError(domain: "NyxianGemini", code: 401, userInfo: [NSLocalizedDescriptionKey: "Gemini API key is not configured. Open Settings → AI Coding."])
        }

        guard let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent") else {
            throw NSError(domain: "NyxianGemini", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini model name."])
        }

        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": systemInstruction]]
            ],
            "contents": [[
                "role": "user",
                "parts": [["text": prompt]]
            ]],
            "generationConfig": [
                "temperature": 0.15,
                "responseMimeType": "application/json",
                "responseSchema": schema
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = data
        request.timeoutInterval = 90

        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "NyxianGemini", code: -1, userInfo: [NSLocalizedDescriptionKey: "Gemini returned an invalid response."])
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let payload = try? JSONDecoder().decode(GeminiAPIErrorPayload.self, from: responseData),
               let message = payload.error?.message {
                throw NSError(domain: "NyxianGemini", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            }
            let text = String(data: responseData, encoding: .utf8) ?? "Unknown Gemini API error."
            throw NSError(domain: "NyxianGemini", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: text])
        }

        let decoded = try JSONDecoder().decode(GeminiAgentResponse.self, from: responseData)
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
        _ = try await generateJSON(
            prompt: "Return ok=true.",
            systemInstruction: "You are a connectivity test. Return only the requested JSON.",
            schema: schema
        )
    }
}

// MARK: - Settings

class SettingsViewController: UIThemedTableViewController {
    init() {
        super.init(style: .insetGrouped)
    }
    
    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.title = "Settings"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
#if DEBUG
        return NXApplicationState.extensionLessMode ? 4 : 7
#else
        return NXApplicationState.extensionLessMode ? 4 : 6
#endif // DEBUG
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.accessoryType = .disclosureIndicator

        switch indexPath.row {
        case 0:
            cell.imageView?.image = UIImage(systemName: "wrench.adjustable.fill")
            cell.textLabel?.text = "Toolchain"
        case 1:
            if NXApplicationState.extensionLessMode {
                cell.imageView?.image = UIImage(systemName: "paintbrush.fill")
                cell.textLabel?.text = "Customization"
            } else {
                cell.imageView?.image = UIImage(systemName: "bolt.shield.fill")
                cell.textLabel?.text = "Management"
            }
        case 2:
            if NXApplicationState.extensionLessMode {
                cell.imageView?.image = UIImage(systemName: "person.3.fill")
                cell.textLabel?.text = "Credits"
            } else {
                cell.imageView?.image = UIImage(systemName: "app.badge.fill")
                cell.textLabel?.text = "Applications"
            }
        case 3:
            if NXApplicationState.extensionLessMode {
                cell.imageView?.image = UIImage(systemName: "sparkles")
                cell.textLabel?.text = "AI Coding"
            } else {
                cell.imageView?.image = UIImage(systemName: "paintbrush.fill")
                cell.textLabel?.text = "Customization"
            }
#if DEBUG
        case 4:
            if NXApplicationState.extensionLessMode {
                cell.imageView?.image = UIImage(systemName: "sparkles")
                cell.textLabel?.text = "AI Coding"
            } else {
                cell.imageView?.image = UIImage(systemName: "ant.fill")
                cell.textLabel?.text = "Debug"
            }
        case 5:
            if NXApplicationState.extensionLessMode {
                cell.imageView?.image = UIImage(systemName: "sparkles")
                cell.textLabel?.text = "AI Coding"
            } else {
                cell.imageView?.image = UIImage(systemName: "person.3.fill")
                cell.textLabel?.text = "Credits"
            }
        case 6:
            cell.imageView?.image = UIImage(systemName: "sparkles")
            cell.textLabel?.text = "AI Coding"
#else
        case 4:
            if NXApplicationState.extensionLessMode {
                cell.imageView?.image = UIImage(systemName: "sparkles")
                cell.textLabel?.text = "AI Coding"
            } else {
                cell.imageView?.image = UIImage(systemName: "person.3.fill")
                cell.textLabel?.text = "Credits"
            }
        case 5:
            cell.imageView?.image = UIImage(systemName: "sparkles")
            cell.textLabel?.text = "AI Coding"
#endif // DEBUG
        default:
            break
        }

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigateToController(for: indexPath.row, animated: true)
    }

    private func navigateToController(for index: Int, animated: Bool) {
        guard let viewController: UIViewController = {
            switch index {
            case 0:
                return ToolChainViewController(style: .insetGrouped)
            case 1:
                if NXApplicationState.extensionLessMode {
                    return CustomizationViewController(style: .insetGrouped)
                } else {
                    return ManagementViewController(style: .insetGrouped)
                }
            case 2:
                if NXApplicationState.extensionLessMode {
                    return CreditsViewController(style: .insetGrouped)
                } else {
                    return ApplicationManagementViewController.shared
                }
            case 3:
                if NXApplicationState.extensionLessMode {
                    return NyxianAICodingSettingsViewController(style: .insetGrouped)
                }
                return CustomizationViewController(style: .insetGrouped)
#if DEBUG
            case 4:
                if NXApplicationState.extensionLessMode {
                    return NyxianAICodingSettingsViewController(style: .insetGrouped)
                }
                return DebugToolboxViewController()
            case 5:
                if NXApplicationState.extensionLessMode {
                    return NyxianAICodingSettingsViewController(style: .insetGrouped)
                }
                return CreditsViewController(style: .insetGrouped)
            case 6:
                return NyxianAICodingSettingsViewController(style: .insetGrouped)
#else
            case 4:
                if NXApplicationState.extensionLessMode {
                    return NyxianAICodingSettingsViewController(style: .insetGrouped)
                }
                return CreditsViewController(style: .insetGrouped)
            case 5:
                return NyxianAICodingSettingsViewController(style: .insetGrouped)
#endif // DEBUG
            default:
                return nil
            }
        }() else { return }

        navigationController?.pushViewController(viewController, animated: animated)
    }
    
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return "\(Bundle.main.infoDictionary?[\"CFBundleName\"] as? String ?? \"Nyxian\") \(Bundle.main.infoDictionary?[\"CFBundleShortVersionString\"] as? String ?? \"Unknown\") \"Scriptura\" Beta (\(Bundle.main.infoDictionary?[\"CFBundleVersion\"] as? String ?? \"Unknown\"))"
    }
}

// MARK: - AI settings screen

final class NyxianAICodingSettingsViewController: UITableViewController {
    private let apiKeyField = UITextField()
    private let modelField = UITextField()
    private let statusLabel = UILabel()
    private var activityIndicator = UIActivityIndicatorView(style: .medium)

    override init(style: UITableView.Style) {
        super.init(style: style)
        self.title = "AI Coding"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = currentTheme?.backgroundColor ?? .systemBackground
        tableView.keyboardDismissMode = .interactive
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "AISettingsCell")

        apiKeyField.placeholder = "Paste Gemini API key"
        apiKeyField.isSecureTextEntry = true
        apiKeyField.autocorrectionType = .no
        apiKeyField.autocapitalizationType = .none
        apiKeyField.clearButtonMode = .whileEditing
        apiKeyField.text = NyxianAIConfiguration.apiKey

        modelField.placeholder = NyxianAIConfiguration.defaultModel
        modelField.autocorrectionType = .no
        modelField.autocapitalizationType = .none
        modelField.text = NyxianAIConfiguration.model

        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = NyxianAIConfiguration.apiKey == nil
            ? "Not configured. Your API key is stored in the iOS Keychain and is never written into the project."
            : "Gemini is configured for \(NyxianAIConfiguration.model)."
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 2 : 3
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: "AISettingsCell")
        cell.selectionStyle = .none

        switch indexPath.section {
        case 0:
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
        default:
            switch indexPath.row {
            case 0:
                cell.textLabel?.text = "Save Gemini configuration"
                cell.textLabel?.textColor = .systemBlue
                let checkmark = UIImageView(image: UIImage(systemName: "checkmark.circle"))
                checkmark.tintColor = .systemBlue
                cell.accessoryView = checkmark
            case 1:
                cell.textLabel?.text = "Test connection"
                cell.textLabel?.textColor = .systemBlue
                let spinner = activityIndicator
                spinner.hidesWhenStopped = true
                spinner.stopAnimating()
                cell.accessoryView = spinner
            case 2:
                cell.textLabel?.text = "Remove API key"
                cell.textLabel?.textColor = .systemRed
            default:
                break
            }
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Gemini" : "Connection"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 {
            return "Use a Gemini API key from Google AI Studio. Keep the key restricted to the Gemini API."
        }
        return "AI Coding can read project files, generate file changes, and apply code directly to the current project."
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        switch indexPath.row {
        case 0:
            saveConfiguration()
        case 1:
            saveConfiguration(showAlert: false) { [weak self] in
                self?.runConnectionTest()
            }
        case 2:
            NyxianKeychain.deleteAPIKey()
            apiKeyField.text = nil
            statusLabel.text = "Gemini API key removed from Keychain."
            showAlert(title: "API key removed", message: "Nyxian no longer has a Gemini API key configured.")
        default:
            break
        }
    }

    private func saveConfiguration(showAlert: Bool = true, completion: (() -> Void)? = nil) {
        do {
            let key = apiKeyField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let model = modelField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else {
                throw NSError(domain: "NyxianAISettings", code: 1, userInfo: [NSLocalizedDescriptionKey: "Please enter a Gemini API key."])
            }
            guard !model.isEmpty else {
                throw NSError(domain: "NyxianAISettings", code: 2, userInfo: [NSLocalizedDescriptionKey: "Please enter a Gemini model name."])
            }
            try NyxianAIConfiguration.save(model: model, apiKey: key)
            statusLabel.text = "Gemini is configured for \(model). The key is stored in Keychain."
            if showAlert {
                showAlert(title: "Saved", message: "Gemini AI Coding is ready.")
            }
            completion?()
        } catch {
            showAlert(title: "Could not save", message: error.localizedDescription)
        }
    }

    private func runConnectionTest() {
        activityIndicator.startAnimating()
        Task { [weak self] in
            do {
                try await NyxianGeminiClient().testConnection()
                await MainActor.run {
                    self?.activityIndicator.stopAnimating()
                    self?.statusLabel.text = "Connection successful. Gemini responded correctly."
                    self?.showAlert(title: "Gemini connected", message: "The configured Gemini model accepted the API key.")
                }
            } catch {
                await MainActor.run {
                    self?.activityIndicator.stopAnimating()
                    self?.statusLabel.text = "Connection failed: \(error.localizedDescription)"
                    self?.showAlert(title: "Gemini connection failed", message: error.localizedDescription)
                }
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
