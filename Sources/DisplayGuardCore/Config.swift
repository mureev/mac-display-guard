import Foundation

/// Facts about one connected display, as read from CoreGraphics.
public struct DisplayInfo: Sendable {
    public var id: UInt32
    public var serial: UInt32
    public var vendor: UInt32
    public var model: UInt32
    public var name: String?
    public var builtin: Bool

    public init(id: UInt32, serial: UInt32, vendor: UInt32, model: UInt32, name: String?, builtin: Bool) {
        self.id = id
        self.serial = serial
        self.vendor = vendor
        self.model = model
        self.name = name
        self.builtin = builtin
    }

    /// Short human label, e.g. `Odyssey G7 (serial 123456789)`.
    public var label: String {
        let n = name ?? (builtin ? "Built-in display" : "Display \(id)")
        return serial != 0 ? "\(n) (serial \(serial))" : n
    }
}

/// Which display a rule applies to. Every field that is set must match.
public struct DisplayMatch: Codable, Equatable, Sendable {
    public var serial: UInt32?
    public var vendor: UInt32?
    public var model: UInt32?
    /// Case-insensitive substring of the display's name (e.g. "Odyssey").
    public var name: String?
    /// Free text for humans; ignored when matching.
    public var label: String?

    public init(serial: UInt32? = nil, vendor: UInt32? = nil, model: UInt32? = nil,
                name: String? = nil, label: String? = nil) {
        self.serial = serial
        self.vendor = vendor
        self.model = model
        self.name = name
        self.label = label
    }

    public var isEmpty: Bool { serial == nil && vendor == nil && model == nil && name == nil }

    public func matches(_ d: DisplayInfo) -> Bool {
        if isEmpty { return false }
        if let serial, serial != d.serial { return false }
        if let vendor, vendor != d.vendor { return false }
        if let model, model != d.model { return false }
        if let name {
            guard let dn = d.name, dn.range(of: name, options: .caseInsensitive) != nil else { return false }
        }
        return true
    }
}

public struct Rule: Codable, Equatable, Sendable {
    public var display: DisplayMatch
    /// Modes in order of preference, e.g. `["2560x1440@165 hidpi", "2560x1440@60 hidpi"]`.
    public var prefer: [String]

    public init(display: DisplayMatch, prefer: [String]) {
        self.display = display
        self.prefer = prefer
    }
}

public struct Config: Codable, Equatable, Sendable {
    /// Safety-net check interval in seconds (display events trigger checks immediately). Default 5.
    public var pollSeconds: Double?
    public var rules: [Rule]

    public init(pollSeconds: Double? = nil, rules: [Rule]) {
        self.pollSeconds = pollSeconds
        self.rules = rules
    }

    public var effectivePollSeconds: Double { max(1, pollSeconds ?? 5) }
}

public enum ConfigError: Error, CustomStringConvertible {
    case badMode(rule: Int, text: String)
    case emptyMatch(rule: Int)
    case emptyPrefer(rule: Int)

    public var description: String {
        switch self {
        case let .badMode(rule, text):
            return "rule \(rule + 1): can't read mode \"\(text)\" (expected e.g. \"2560x1440@165 hidpi\")"
        case let .emptyMatch(rule):
            return "rule \(rule + 1): \"display\" needs at least one of serial, vendor, model, name"
        case let .emptyPrefer(rule):
            return "rule \(rule + 1): \"prefer\" is empty"
        }
    }
}

/// A rule with its modes parsed.
public struct CompiledRule: Sendable {
    public var match: DisplayMatch
    public var prefer: [ModeSpec]
}

extension Config {
    public static func load(from url: URL) throws -> Config {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }

    /// Validates and parses every rule.
    public func compiled() throws -> [CompiledRule] {
        try rules.enumerated().map { i, rule in
            if rule.display.isEmpty { throw ConfigError.emptyMatch(rule: i) }
            if rule.prefer.isEmpty { throw ConfigError.emptyPrefer(rule: i) }
            let specs = try rule.prefer.map { text -> ModeSpec in
                guard let spec = ModeSpec(parsing: text) else { throw ConfigError.badMode(rule: i, text: text) }
                return spec
            }
            return CompiledRule(match: rule.display, prefer: specs)
        }
    }
}

extension Array where Element == CompiledRule {
    /// The first rule that matches this display.
    public func rule(for d: DisplayInfo) -> CompiledRule? {
        first { $0.match.matches(d) }
    }
}
