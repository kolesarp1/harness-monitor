import Foundation

public enum UsageEndpoint {
    public static func makeSession(requestTimeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = max(requestTimeout * 2, 30)
        return URLSession(configuration: config)
    }

    public static func retryAfter(from response: HTTPURLResponse, now: Date) -> Date? {
        guard
            let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        let ceiling = now.addingTimeInterval(3_600)
        if let seconds = TimeInterval(raw), seconds >= 0 {
            return now.addingTimeInterval(min(seconds, 3_600))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: raw).map { min($0, ceiling) }
    }
}
