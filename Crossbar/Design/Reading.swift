import Foundation

/// Instants and durations, as a person reads them.
///
/// The service sends the instants it recorded, in ISO 8601 and in UTC, because that is what a
/// record is. What a call is *called* — "Yesterday", "6 min" — is this app's business, and it
/// is the same business in three places, so it lives in one.
enum Reading {

    private static let iso = ISO8601DateFormatter()

    /// The service writes its instants as `toISOString()` output, which carries milliseconds, and
    /// a plain ISO-8601 formatter refuses those — silently, by returning nothing, so a row that
    /// asked for one comes out with no time in it at all rather than with an error. Both
    /// spellings are read.
    private static let isoMilliseconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return iso.date(from: value) ?? isoMilliseconds.date(from: value)
    }

    /// The instant a service value names, for the one screen that needs the moment rather than
    /// the words.
    ///
    /// The invitation screen is that screen: it says when a code stops working, and it also has to
    /// know when that is, so that a code past its life does not sit on the glass looking as though
    /// it still works. Both come through here, so the sentence and the moment it describes cannot
    /// disagree about which instant the service meant.
    static func instant(_ value: String?) -> Date? { date(value) }

    /// When a call was: the hour if it was today, a word if it was yesterday, a date after.
    ///
    /// Today's calls are the ones somebody is looking for, and a bare time is how they know
    /// them. Anything older needs the day, and "Yesterday" is a word rather than a date
    /// because that is how people say it.
    static func when(_ value: String?) -> String {
        guard let date = date(value) else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// How long somebody was on a call, for one that was answered and has finished.
    ///
    /// Seconds only appear on a call short enough that they are the whole of it.
    static func duration(from start: String?, to end: String?) -> String? {
        guard let start = date(start), let end = date(end), end > start else { return nil }
        let seconds = Int(end.timeIntervalSince(start))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        return "\(hours) hr \(minutes % 60) min"
    }

    /// How long ago something was, in the fewest words that are still true.
    ///
    /// Used for the one thing in this app that is genuinely remote: when somebody was last
    /// seen. Deliberately coarse — "4 hours ago" is as much as anyone wants, and a precise
    /// instant would pretend to a precision the presence record does not have.
    static func ago(_ value: String?) -> String? {
        guard let date = date(value) else { return nil }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) minutes ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) hours ago" }
        let days = Int(seconds / 86400)
        return days == 1 ? "yesterday" : "\(days) days ago"
    }
}
