import Foundation
import XpectorKit

final class XPUserDefaultsCapture: @unchecked Sendable {

    func captureSnapshot() -> XPUserDefaultsSnapshot {
        let defaults = UserDefaults.standard
        var entries: [XPUserDefaultsEntry] = []

        for (key, value) in defaults.dictionaryRepresentation() {
            let valueType = Self.typeName(for: value)
            let valueString = Self.stringRepresentation(for: value)
            entries.append(XPUserDefaultsEntry(key: key, value: valueString, valueType: valueType))
        }

        entries.sort { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        return XPUserDefaultsSnapshot(entries: entries)
    }

    private static func typeName(for value: Any) -> String {
        switch value {
        case is Bool: return "Bool"
        case is Int: return "Int"
        case is Double: return "Double"
        case is Float: return "Float"
        case is String: return "String"
        case is Data: return "Data"
        case is Date: return "Date"
        case is [Any]: return "Array"
        case is [String: Any]: return "Dictionary"
        default: return String(describing: type(of: value))
        }
    }

    private static func stringRepresentation(for value: Any) -> String {
        switch value {
        case let data as Data:
            if let utf8 = String(data: data, encoding: .utf8), !utf8.isEmpty {
                return utf8
            }
            return "<\(data.count) bytes>"
        case let date as Date:
            let formatter = ISO8601DateFormatter()
            return formatter.string(from: date)
        case let arr as [Any]:
            return "[\(arr.count) items]"
        case let dict as [String: Any]:
            return "{\(dict.count) keys}"
        default:
            return String(describing: value)
        }
    }
}
