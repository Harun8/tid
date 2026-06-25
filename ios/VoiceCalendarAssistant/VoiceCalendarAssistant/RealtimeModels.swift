import Foundation

struct RealtimeSessionConfig: Codable {
    var model: String
    var voice: String
    var instructions: String
}

struct RealtimeFunctionCall: Decodable {
    var type: String
    var name: String
    var callId: String?
    var arguments: String

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case callId = "call_id"
        case arguments
    }
}

struct RealtimeResponseDone: Decodable {
    var response: Response

    struct Response: Decodable {
        var output: [RealtimeFunctionCall]?
    }
}

struct RealtimeErrorEnvelope: Decodable {
    var error: RealtimeError

    struct RealtimeError: Decodable {
        var message: String?
        var type: String?
    }
}

enum RealtimeEventParser {
    static func jsonObject(from raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    static func stringValue(_ object: [String: Any], key: String) -> String? {
        object[key] as? String
    }
}

