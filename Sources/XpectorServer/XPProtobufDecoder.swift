import Foundation
import XpectorKit

/// A dependency-free, schema-less protobuf decoder.
///
/// Given an opaque `[UInt8]` it walks the wire format a single time —
/// `tag = fieldNumber << 3 | wireType` — and produces an `XPProtoMessage` tree
/// of field-number-keyed values. No `.proto` schema is needed, so it can render
/// any binary WebSocket frame as a readable field tree.
///
/// Decoding is **advisory and never lossy**: the caller always keeps the raw
/// bytes (`binaryBase64`) so a wrong guess still falls back to Hex/Base64 in the
/// viewers. `decodeIfProbable` applies a heuristic (exact byte consumption, ≥1
/// valid field, not plain UTF-8 text / JSON) so plain-text frames aren't
/// misread as protobuf.
enum XPProtobufDecoder {
    /// Hard caps so a hostile/garbage frame can't blow the stack or spin.
    private static let maxDepth = 12
    private static let maxVarintBytes = 10

    /// Returns a decoded tree only when the bytes are *confidently* protobuf.
    /// Use this on binary frames; returns nil for text/JSON/garbage.
    static func decodeIfProbable(_ data: Data) -> XPProtoMessage? {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return nil }

        // Reject anything that reads as plain printable UTF-8 text — a JSON or
        // string frame can coincidentally parse as protobuf, but it's almost
        // never what the developer wants to see as a field tree.
        if looksLikePrintableText(bytes) { return nil }

        var index = 0
        guard let message = parseMessage(bytes, &index, end: bytes.count, depth: 0),
              index == bytes.count,            // must consume the whole frame
              !message.fields.isEmpty          // require at least one valid field
        else { return nil }
        return message
    }

    // MARK: - Core parse

    /// Parses a length-bounded region as a protobuf message. Returns nil on any
    /// malformed tag / truncation / implausible field so the caller can fall
    /// back to treating the region as a string or raw bytes.
    private static func parseMessage(_ bytes: [UInt8], _ index: inout Int, end: Int, depth: Int) -> XPProtoMessage? {
        guard depth <= maxDepth else { return nil }
        var rawFields: [(field: Int, value: XPProtoValue)] = []

        while index < end {
            guard let tag = readVarint(bytes, &index, end: end) else { return nil }
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x7)
            // Field numbers are 1…2^29-1; 0 and the reserved 19000–19999 aside,
            // a 0 field number is always malformed.
            guard fieldNumber >= 1, fieldNumber <= 536_870_911 else { return nil }

            let value: XPProtoValue
            switch wireType {
            case 0: // varint
                guard let v = readVarint(bytes, &index, end: end) else { return nil }
                value = .varint(v)
            case 1: // 64-bit
                guard index + 8 <= end else { return nil }
                var u: UInt64 = 0
                for b in 0..<8 { u |= UInt64(bytes[index + b]) << (8 * b) }
                index += 8
                value = .fixed64(u)
            case 5: // 32-bit
                guard index + 4 <= end else { return nil }
                var u: UInt32 = 0
                for b in 0..<4 { u |= UInt32(bytes[index + b]) << (8 * b) }
                index += 4
                value = .fixed32(u)
            case 2: // length-delimited
                guard let len = readVarint(bytes, &index, end: end) else { return nil }
                let length = Int(len)
                guard length >= 0, index + length <= end else { return nil }
                let sub = Array(bytes[index..<index + length])
                index += length
                value = decodeLengthDelimited(sub, depth: depth)
            default:
                // Wire types 3/4 (groups, deprecated) and 6/7 (invalid) → bail.
                return nil
            }
            rawFields.append((fieldNumber, value))
        }

        return XPProtoMessage(fields: collapseRepeated(rawFields))
    }

    /// A length-delimited field is, in preference order: a nested message (if it
    /// parses fully), then a printable UTF-8 string, then opaque bytes (base64).
    private static func decodeLengthDelimited(_ sub: [UInt8], depth: Int) -> XPProtoValue {
        if !sub.isEmpty {
            var inner = 0
            if let nested = parseMessage(sub, &inner, end: sub.count, depth: depth + 1),
               inner == sub.count, !nested.fields.isEmpty {
                return .message(nested)
            }
        }
        if let s = printableString(sub) {
            return .string(s)
        }
        return .bytes(Data(sub).base64EncodedString())
    }

    /// Collapses repeated field numbers into a single `.repeated` value while
    /// preserving first-seen order.
    private static func collapseRepeated(_ raw: [(field: Int, value: XPProtoValue)]) -> [XPProtoField] {
        var order: [Int] = []
        var grouped: [Int: [XPProtoValue]] = [:]
        for f in raw {
            if grouped[f.field] == nil { order.append(f.field) }
            grouped[f.field, default: []].append(f.value)
        }
        return order.map { num in
            let values = grouped[num] ?? []
            return XPProtoField(field: num, value: values.count == 1 ? values[0] : .repeated(values))
        }
    }

    // MARK: - Primitives

    /// Reads a base-128 varint, bounded to 10 bytes. Returns nil on truncation
    /// or overlong encoding.
    private static func readVarint(_ bytes: [UInt8], _ index: inout Int, end: Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var count = 0
        while index < end {
            let b = bytes[index]
            index += 1
            count += 1
            if count > maxVarintBytes { return nil }
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
        return nil   // ran off the end without a terminator
    }

    /// Returns the string if the bytes are valid UTF-8 with no disallowed
    /// control characters (tab/newline/return are allowed). Used both to label a
    /// length-delimited field and, on the whole frame, to reject plain text.
    private static func printableString(_ bytes: [UInt8]) -> String? {
        guard let s = String(bytes: bytes, encoding: .utf8) else { return nil }
        for scalar in s.unicodeScalars {
            if scalar.value < 0x20, scalar != "\t", scalar != "\n", scalar != "\r" {
                return nil
            }
        }
        return s
    }

    /// True when the whole frame is plain printable UTF-8 text (so it should be
    /// shown as text, not coerced into a protobuf tree).
    private static func looksLikePrintableText(_ bytes: [UInt8]) -> Bool {
        printableString(bytes) != nil
    }
}
