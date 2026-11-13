//
//  AIPlan.swift
//  TypeRight
//
//  The three ways TypeRight can work and where an AI card's request goes. Spelling and basic
//  grammar are always checked on this Mac (Harper), whatever the plan. There are no free uses:
//  the AI cards come with a membership or the user's own key.
//

import Foundation

enum AIPlan: String, CaseIterable, Sendable {
    /// Only the on-device checks; no AI cards.
    case local
    /// The user's own key: requests go straight from this Mac to the provider they picked. Free for good.
    case own
    /// Membership: requests go through our backend, which holds the key.
    case member

    static let key = "typeright.aiPlan"

    /// Never chosen: a key already filled in means own (nothing changes for people who set one up),
    /// otherwise on-device only. A new Mac talks to no backend until the user buys or enters a code.
    static func resolve(stored: String?, hasOwnKey: Bool) -> AIPlan {
        AIPlan(rawValue: stored ?? "") ?? (hasOwnKey ? .own : .local)
    }
}

/// Where one AI card's request goes.
enum CoachAIRoute: Equatable, Sendable {
    /// Straight to the provider the user picked, with their key.
    case own(CoachProvider)
    /// Through our backend. `use` is the card's use number (X-Use-Id): every request and retry of
    /// the card carries it, so the card counts once against today's limit.
    case member(use: UUID)
}

/// Whether the AI cards are on right now, and if not, why.
enum CoachAIStatus: Equatable {
    case own(CoachProvider)
    case member
    /// The user chose on-device checks only.
    case localOnly
    /// The user chose their own key but none is filled in (or the custom address is incomplete).
    case noKey
    /// Member plan, but the membership cannot be used now (none bought, today's limit, renewal
    /// failed, ended, or a debug build not pointed at a backend).
    case memberBlocked(MemberState)

    var isOn: Bool {
        switch self {
        case .own, .member: true
        case .localOnly, .noKey, .memberBlocked: false
        }
    }

    /// The route for a new card; through our backend every card gets a new use number.
    func route(use: UUID = UUID()) -> CoachAIRoute? {
        switch self {
        case let .own(provider): .own(provider)
        case .member: .member(use: use)
        case .localOnly, .noKey, .memberBlocked: nil
        }
    }
}
