import Foundation

enum ClockState {
    static func angles(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> (hour: Float, minute: Float) {
        let c = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let seconds = Double(c.second ?? 0) + Double(c.nanosecond ?? 0) / 1e9
        let minutes = Double(c.minute ?? 0) + seconds / 60
        let hours = Double((c.hour ?? 0) % 12) + minutes / 60
        return (Float(hours / 12 * 2 * .pi), Float(minutes / 60 * 2 * .pi))
    }

    static func dayPhase(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> Float {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Float((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)) / 86400
    }

    static func fixtureDate(_ hour: Int, _ minute: Int) -> Date {
        Calendar.autoupdatingCurrent.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }
}
