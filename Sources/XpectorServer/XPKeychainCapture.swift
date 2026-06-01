import Foundation
import Security
import XpectorKit

#if DEBUG

final class XPKeychainCapture: @unchecked Sendable {

    // MARK: - Class mapping

    private static let itemClasses: [(CFString, String)] = [
        (kSecClassGenericPassword, "GenericPassword"),
        (kSecClassInternetPassword, "InternetPassword"),
        (kSecClassCertificate, "Certificate"),
        (kSecClassKey, "Key"),
    ]

    // MARK: - Query

    func queryItems(request: XPKeychainRequest) -> XPKeychainSnapshot {
        var allItems: [XPKeychainItem] = []

        for (secClass, className) in Self.itemClasses {
            if let filter = request.classFilter, filter != className {
                continue
            }
            let items = fetchItems(secClass: secClass, className: className, serviceFilter: request.serviceFilter)
            allItems.append(contentsOf: items)
        }

        return XPKeychainSnapshot(items: allItems)
    }

    // MARK: - Modify

    func modifyItem(_ modification: XPKeychainModification) -> XPKeychainModificationResponse {
        switch modification.action.lowercased() {
        case "set":
            return setItem(modification)
        case "delete":
            return deleteItem(modification)
        default:
            return XPKeychainModificationResponse(success: false, error: "Unknown action: \(modification.action). Use \"set\" or \"delete\".")
        }
    }

    // MARK: - Summary

    func summaryCounts() -> [String: Int] {
        var counts: [String: Int] = [:]

        for (secClass, className) in Self.itemClasses {
            let query: [String: Any] = [
                kSecClass as String: secClass,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
            ]

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            if status == errSecSuccess, let items = result as? [[String: Any]] {
                counts[className] = items.count
            } else if status == errSecItemNotFound {
                counts[className] = 0
            } else {
                counts[className] = 0
            }
        }

        return counts
    }

    // MARK: - Private helpers

    private func fetchItems(secClass: CFString, className: String, serviceFilter: String?) -> [XPKeychainItem] {
        // First attempt: request both attributes and data
        let items = performQuery(secClass: secClass, className: className, serviceFilter: serviceFilter, includeData: true)

        // If the full query failed due to auth, try attributes-only so we still surface the items
        if items == nil {
            let fallback = performQuery(secClass: secClass, className: className, serviceFilter: serviceFilter, includeData: false)
            return (fallback ?? []).map { item in
                XPKeychainItem(
                    id: item.id,
                    itemClass: item.itemClass,
                    service: item.service,
                    account: item.account,
                    label: item.label,
                    accessibility: item.accessibility,
                    createdAt: item.createdAt,
                    value: nil,
                    valueSize: item.valueSize,
                    requiresAuth: true
                )
            }
        }

        return items ?? []
    }

    private func performQuery(secClass: CFString, className: String, serviceFilter: String?, includeData: Bool) -> [XPKeychainItem]? {
        var query: [String: Any] = [
            kSecClass as String: secClass,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: includeData,
        ]

        if let serviceFilter {
            // kSecAttrService applies to generic passwords; kSecAttrServer to internet passwords
            if secClass == kSecClassInternetPassword {
                query[kSecAttrServer as String] = serviceFilter
            } else {
                query[kSecAttrService as String] = serviceFilter
            }
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return []
        case errSecAuthFailed, errSecInteractionNotAllowed:
            return nil // caller handles auth-required fallback
        default:
            return []
        }

        guard let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { attrs in
            parseItem(attrs: attrs, className: className, includeData: includeData)
        }
    }

    private func parseItem(attrs: [String: Any], className: String, includeData: Bool) -> XPKeychainItem {
        let service = attrs[kSecAttrService as String] as? String
            ?? attrs[kSecAttrServer as String] as? String
        let account = attrs[kSecAttrAccount as String] as? String
        let label = attrs[kSecAttrLabel as String] as? String
        let createdAt = attrs[kSecAttrCreationDate as String] as? Date
        let accessibility = readableAccessibility(attrs[kSecAttrAccessible as String] as? String)

        var value: String?
        var valueSize: Int = 0
        var requiresAuth = false

        if includeData {
            if let data = attrs[kSecValueData as String] as? Data {
                valueSize = data.count
                if let utf8 = String(data: data, encoding: .utf8), !utf8.isEmpty {
                    value = utf8
                } else {
                    value = data.base64EncodedString()
                }
            }
        } else {
            // When data was not requested we cannot know the size; mark as auth-required
            requiresAuth = true
        }

        return XPKeychainItem(
            itemClass: className,
            service: service,
            account: account,
            label: label,
            accessibility: accessibility,
            createdAt: createdAt,
            value: value,
            valueSize: valueSize,
            requiresAuth: requiresAuth
        )
    }

    // MARK: - Set / Delete

    private func setItem(_ modification: XPKeychainModification) -> XPKeychainModificationResponse {
        guard let valueData = modification.value?.data(using: .utf8) else {
            return XPKeychainModificationResponse(success: false, error: "Value is required for \"set\" action.")
        }

        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: modification.service,
            kSecAttrAccount as String: modification.account,
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: valueData,
        ]

        var status = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)

        if status == errSecItemNotFound {
            // Item does not exist yet; add it.
            var addQuery = searchQuery
            addQuery[kSecValueData as String] = valueData
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        if status == errSecSuccess {
            return XPKeychainModificationResponse(success: true)
        } else {
            return XPKeychainModificationResponse(success: false, error: "SecItem operation failed with status \(status).")
        }
    }

    private func deleteItem(_ modification: XPKeychainModification) -> XPKeychainModificationResponse {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: modification.service,
            kSecAttrAccount as String: modification.account,
        ]

        let status = SecItemDelete(query as CFDictionary)

        if status == errSecSuccess || status == errSecItemNotFound {
            return XPKeychainModificationResponse(success: true)
        } else {
            return XPKeychainModificationResponse(success: false, error: "SecItemDelete failed with status \(status).")
        }
    }

    // MARK: - Accessibility readability

    private func readableAccessibility(_ raw: String?) -> String? {
        guard let raw else { return nil }

        let mapping: [String: String] = [
            kSecAttrAccessibleWhenUnlocked as String: "WhenUnlocked",
            kSecAttrAccessibleAfterFirstUnlock as String: "AfterFirstUnlock",
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String: "WhenUnlockedThisDeviceOnly",
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String: "AfterFirstUnlockThisDeviceOnly",
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String: "WhenPasscodeSetThisDeviceOnly",
        ]

        return mapping[raw] ?? raw
    }
}

#endif
