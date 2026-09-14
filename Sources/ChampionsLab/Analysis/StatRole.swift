//  StatRole.swift
//  What a Pokémon's stats say it is for.
//
//  Ranking a move needs to know whether its holder can throw it — a 90 BP
//  special move is worth nothing to something with 150 Attack and 70 Sp. Atk.
//  That much was a ratio. This is the rest of the question: whether a Pokémon
//  is an attacker or a wall, which side it is bulky on, and whether it can
//  credibly be built more than one way.
//
//  The last part matters most and is the easiest to get wrong. Dragapult at 120
//  Attack and 100 Sp. Atk is genuinely both; calling it "physical" because one
//  number is larger throws away the set people actually run. A second style is
//  reported whenever it is close enough to be real.
//
//  Thresholds are percentiles of the legal roster rather than numbers I chose,
//  so "bulky" means bulky for this format.

import Foundation

struct StatRole: Equatable {
    enum Offence: String {
        case physical = "Physical attacker"
        case special = "Special attacker"
        case mixed = "Mixed attacker"
        case none = "Not an attacker"
    }

    enum Defence: String {
        case physicalWall = "Physically bulky"
        case specialWall = "Specially bulky"
        case balanced = "Evenly bulky"
        case frail = "Frail"
    }

    let offence: Offence
    let defence: Defence
    /// The other way it could credibly be built, where there is one. This is
    /// the Dragapult case: 120 Attack and 100 Sp. Atk is two real sets.
    let alsoViable: Offence?
    /// Where it sits in the roster, 0…1, for each of the four.
    let attackRank: Double
    let spAttackRank: Double
    let physicalBulkRank: Double
    let specialBulkRank: Double

    /// One line, the way a person would say it.
    var summary: String {
        var text = offence.rawValue
        if let alsoViable, offence != .mixed {
            text += " (can run \(alsoViable == .physical ? "physical" : "special") too)"
        }
        return "\(text) · \(defence.rawValue.lowercased())"
    }

    /// Whether investing in this attacking stat is defensible at all.
    func canUse(_ category: String) -> Bool {
        switch category {
        case "Physical": return offence == .physical || offence == .mixed
            || alsoViable == .physical
        case "Special":  return offence == .special || offence == .mixed
            || alsoViable == .special
        default:         return true
        }
    }
}

@MainActor
extension Store {
    /// Roster percentiles, worked out once.
    private static var rankCache: [String: [Double]] = [:]

    private func percentiles(_ pick: (Form) -> Int) -> [Double] {
        let values = data.forms.map { Double(pick($0)) }.sorted()
        return values
    }

    private func rank(_ value: Int, in sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0.5 }
        let below = sorted.firstIndex { $0 >= Double(value) } ?? sorted.count
        return Double(below) / Double(sorted.count)
    }

    /// What this Pokémon's stats say it is for.
    func statRole(of form: Form) -> StatRole {
        if let cached = roleCache[form.id] { return cached }

        // Bulk is health multiplied by the defence, which is what actually
        // decides how many hits something takes.
        func physicalBulk(_ f: Form) -> Int { f.hp * f.defense / 10 }
        func specialBulk(_ f: Form) -> Int { f.hp * f.spDefense / 10 }

        if Store.rankCache["attack"] == nil {
            Store.rankCache["attack"] = percentiles { $0.attack }
            Store.rankCache["spAttack"] = percentiles { $0.spAttack }
            Store.rankCache["physicalBulk"] = percentiles(physicalBulk)
            Store.rankCache["specialBulk"] = percentiles(specialBulk)
        }
        let attackRank = rank(form.attack, in: Store.rankCache["attack"]!)
        let spAttackRank = rank(form.spAttack, in: Store.rankCache["spAttack"]!)
        let physicalRank = rank(physicalBulk(form), in: Store.rankCache["physicalBulk"]!)
        let specialRank = rank(specialBulk(form), in: Store.rankCache["specialBulk"]!)

        // -- offence ---------------------------------------------------------
        let high = Double(max(form.attack, form.spAttack))
        let low = Double(min(form.attack, form.spAttack))
        let closeness = high > 0 ? low / high : 1
        let offence: StatRole.Offence
        var alsoViable: StatRole.Offence?

        if max(attackRank, spAttackRank) < 0.45 {
            // Nothing it does with either stat is going to trouble anyone.
            offence = .none
        } else if closeness >= 0.9 {
            offence = .mixed
        } else {
            offence = form.attack > form.spAttack ? .physical : .special
            // The second style counts when it is within about a quarter and
            // still respectable for the format — Dragapult, not an afterthought.
            let second: StatRole.Offence = offence == .physical ? .special : .physical
            let secondRank = offence == .physical ? spAttackRank : attackRank
            if closeness >= 0.75 && secondRank >= 0.55 { alsoViable = second }
        }

        // -- defence ---------------------------------------------------------
        //
        // Which side it is bulky on is a ratio, not a difference of
        // percentiles: the roster is dense enough around the middle that a
        // 175/120 split came out as "evenly bulky", which it plainly is not.
        // How frail it is overall stays a percentile, because that only means
        // anything relative to the format.
        let defence: StatRole.Defence
        let ratio = specialBulk(form) > 0
            ? Double(physicalBulk(form)) / Double(specialBulk(form)) : 1
        if max(physicalRank, specialRank) < 0.35 {
            defence = .frail
        } else if ratio > 1.2 {
            defence = .physicalWall
        } else if ratio < 1 / 1.2 {
            defence = .specialWall
        } else {
            defence = .balanced
        }

        let role = StatRole(offence: offence, defence: defence, alsoViable: alsoViable,
                            attackRank: attackRank, spAttackRank: spAttackRank,
                            physicalBulkRank: physicalRank, specialBulkRank: specialRank)
        roleCache[form.id] = role
        return role
    }
}
