import Foundation
import Supabase

/// The database and the Edge Functions write their refusals for the person
/// reading them — "an organization must keep at least one owner" — so they are
/// shown rather than flattened into a generic failure.
enum ServerError {
    static func rpcMessage(_ error: Error) -> String? {
        guard let postgrest = error as? PostgrestError else { return nil }
        return sentence(postgrest.message)
    }

    static func functionMessage(_ error: Error) -> String? {
        functionCode(error).flatMap(sentence)
    }

    static func functionCode(_ error: Error) -> String? {
        guard let functionError = error as? FunctionsError,
              case let .httpError(_, data) = functionError else { return nil }
        struct Body: Decodable {
            let error: String?
        }
        return try? JSONDecoder().decode(Body.self, from: data).error
    }

    private static func sentence(_ message: String) -> String? {
        guard !message.isEmpty else { return nil }
        return message.prefix(1).uppercased() + message.dropFirst() + "."
    }
}
