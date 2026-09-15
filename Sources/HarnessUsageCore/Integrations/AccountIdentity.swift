import Foundation

// A login's display identity is public account metadata, not a credential. Both harnesses may carry
// it as an `email` claim in a JWT; decoding that payload locally never sends the token anywhere.
enum AccountIdentity {
    static func email(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while !payload.count.isMultiple(of: 4) { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let email = (json["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !email.isEmpty
        else { return nil }
        return email
    }
}
