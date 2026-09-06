import Foundation

/// A loss-free JSON tree.
///
/// The bridge is a proxy first and a translator second: it should rewrite the
/// handful of fields it understands and forward everything else untouched.
/// Strict `Codable` structs would silently drop unknown fields — new Anthropic
/// request fields, provider-specific extensions — so translation works on this.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Accessors

public extension JSONValue {
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    var intValue: Int? { if case .number(let n) = self { return Int(n) }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    subscript(key: String) -> JSONValue? {
        get { objectValue?[key] }
        set {
            guard case .object(var o) = self else { return }
            o[key] = newValue
            self = .object(o)
        }
    }

    /// Element access for arrays. Returns nil for any other kind of value, so
    /// `json["choices"]?[0]?["delta"]` reads cleanly against untrusted input.
    subscript(index: Int) -> JSONValue? {
        guard let a = arrayValue, a.indices.contains(index) else { return nil }
        return a[index]
    }

    /// Removes `key` from every object in the tree.
    ///
    /// Used to strip `cache_control` breakpoints before handing a request to an
    /// OpenAI backend, which rejects unknown content-block fields.
    func removingKeyRecursively(_ key: String) -> JSONValue {
        switch self {
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, v) in o where k != key {
                out[k] = v.removingKeyRecursively(key)
            }
            return .object(out)
        case .array(let a):
            return .array(a.map { $0.removingKeyRecursively(key) })
        default:
            return self
        }
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // Emit integral numbers without a ".0" tail; strict backends reject
            // `"max_tokens": 4096.0`.
            if n.rounded() == n, abs(n) < 9.007e15 {
                try c.encode(Int(n))
            } else {
                try c.encode(n)
            }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}
extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}
extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

// MARK: - Serialisation

public extension JSONValue {
    static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Parses a JSON document that may be a fragment or malformed. Returns nil
    /// rather than throwing — used for tool-call argument strings, which some
    /// backends truncate.
    static func lenient(_ string: String) -> JSONValue? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? decode(data)
    }

    func encoded() throws -> Data { try JSONEncoder().encode(self) }

    var compactString: String {
        guard let d = try? encoded(), let s = String(data: d, encoding: .utf8) else { return "null" }
        return s
    }

    var prettyString: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let d = try? enc.encode(self), let s = String(data: d, encoding: .utf8) else { return "null" }
        return s
    }
}
