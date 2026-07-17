import ArgumentParser
import Foundation

/// JSON-literal option decoding for generated commands: request fields whose
/// wire shape has no flat command-line form (structures, maps, non-enum named
/// types) accept a JSON literal, decoded here into the generated `Codable`
/// type. Generated integer `CodingKeys` carry their case name as
/// `stringValue`, so the JSON keys are the field names.
public enum MMCLIJSON {
    /// Decodes an optional JSON option; `nil` input stays `nil`. A malformed
    /// literal is a usage error (`ValidationError`), not a call failure.
    public static func decode<T: Decodable>(
        _ type: T.Type, from raw: String?, option: String
    ) throws -> T? {
        guard let raw else { return nil }
        return try decodeRequired(type, from: raw, option: option)
    }

    /// Decodes a required JSON option.
    public static func decodeRequired<T: Decodable>(
        _ type: T.Type, from raw: String, option: String
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(raw.utf8))
        } catch {
            throw ValidationError(
                "--\(option) is not valid JSON for \(String(describing: type)): \(error)")
        }
    }
}
