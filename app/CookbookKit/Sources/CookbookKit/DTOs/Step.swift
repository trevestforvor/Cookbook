import Foundation

/// One instruction step. Backend SELECT shape: `step_number, text`.
public struct Step: Codable, Sendable, Hashable, Identifiable {
    public var number: Int
    public var text: String

    public var id: Int { number }

    public init(number: Int, text: String) {
        self.number = number
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case number = "step_number"
        case text
    }
}
