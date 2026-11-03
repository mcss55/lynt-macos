import Foundation

public struct BudgetSnapshot: Sendable {
    public let month: String
    /// Settled consumption. Failed/unknown requests are charged conservatively.
    public let usedTokens: Int
    public let reservedTokens: Int
    public let limit: Int
    public var remainingTokens: Int { max(0, limit - usedTokens - reservedTokens) }
}

public struct BudgetReservation: Sendable {
    fileprivate let id: UUID
    fileprivate let month: String
    public let tokens: Int
}

public enum TokenBudgetError: Error, LocalizedError {
    case exceeded
    public var errorDescription: String? { "Monthly token budget reached. Increase the limit in Settings or wait for the next month." }
}

/// Only month + token counters are persisted. Reservations are charged before transmission,
/// so an app crash cannot silently reset the cost of an in-flight request.
public actor TokenBudget {
    private var limit: Int
    private var month: String
    private var charged: Int
    private var reservations: [UUID: BudgetReservation] = [:]
    private let store: UserDefaults?
    private let now: @Sendable () -> Date
    private let prefix: String

    public init(monthlyLimit: Int = 100_000, store: UserDefaults? = nil,
                prefix: String = "lynt.budget", now: @escaping @Sendable () -> Date = { Date() }) {
        self.limit = max(0, monthlyLimit)
        self.store = store
        self.prefix = prefix
        self.now = now
        let current = Self.monthKey(now())
        month = current
        charged = store?.string(forKey: "\(prefix).month") == current
            ? max(0, store?.integer(forKey: "\(prefix).charged") ?? 0) : 0
    }

    public func setLimit(_ value: Int) { limit = max(0, value) }

    public func snapshot() -> BudgetSnapshot {
        rollMonth()
        let reserved = reservations.values.filter { $0.month == month }.reduce(0) { $0 + $1.tokens }
        return .init(month: month, usedTokens: max(0, charged - reserved), reservedTokens: reserved, limit: limit)
    }

    public func reserve(_ tokens: Int) throws -> BudgetReservation {
        rollMonth()
        guard tokens >= 0, tokens <= limit, charged <= limit - tokens else { throw TokenBudgetError.exceeded }
        let reservation = BudgetReservation(id: UUID(), month: month, tokens: tokens)
        reservations[reservation.id] = reservation
        charged += tokens
        persist()
        return reservation
    }

    public func settle(_ reservation: BudgetReservation, chargedTokens: Int) {
        rollMonth()
        guard reservations.removeValue(forKey: reservation.id) != nil else { return }
        guard reservation.month == month else { return }
        // Keep over-reported usage visible too; future requests then fail closed.
        let actual = max(0, min(chargedTokens, Int.max / 4))
        charged = max(0, charged - reservation.tokens) + actual
        persist()
    }

    private func rollMonth() {
        let current = Self.monthKey(now())
        guard current != month else { return }
        month = current
        charged = 0
        persist()
    }

    private func persist() {
        store?.set(month, forKey: "\(prefix).month")
        store?.set(charged, forKey: "\(prefix).charged")
    }

    private static func monthKey(_ date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }
}
