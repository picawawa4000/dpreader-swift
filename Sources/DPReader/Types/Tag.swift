public enum TagValue: Codable, Equatable {
    case rawID(String)
    case tagID(String)

    public init(from decoder: any Decoder) throws {
        let rawValue: String

        if let container = try? decoder.singleValueContainer(), let stringValue = try? container.decode(String.self) {
            rawValue = stringValue
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rawValue = try container.decode(String.self, forKey: .id)
        }

        if rawValue.first == "#" {
            self = .tagID(addDefaultNamespace(String(rawValue.dropFirst())))
        } else {
            self = .rawID(addDefaultNamespace(rawValue))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .rawID(let id):
            try container.encode(id)
        case .tagID(let id):
            try container.encode("#" + id)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
    }
}

public struct TagDefinition: Codable {
    let replace: Bool
    let values: [TagValue]

    init(replace: Bool = false, values: [TagValue]) {
        self.replace = replace
        self.values = values
    }

    private enum CodingKeys: String, CodingKey {
        case replace
        case values
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.replace = try container.decodeIfPresent(Bool.self, forKey: .replace) ?? false
        self.values = try container.decode([TagValue].self, forKey: .values)
    }
}
