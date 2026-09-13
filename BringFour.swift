//  BringFour.swift
//  Which four to bring, and which two to lead.
//
//  Six are registered and four are brought, so the decision made at Team
//  Preview is not "is this team good" but "which four of these six, and which
//  two of those four start". That is the highest-leverage choice in a game of
//  doubles, and the engine had no opinion about it. The only bring-four
//  reasoning anywhere was the two-Mega path in the builder, which picked its
//  four against the bundled archetypes in the abstract rather than against the
//  six actually across from you.
//
//  Nothing new is needed to answer it. The versus grid already works out all
//  thirty-six one-on-ones; this reads them.
//
//  Three things decide it:
//
//    · The grid, over the four you bring rather than the six you own, and
//      weighted by how likely each of theirs is to appear. You are scored
//      against the four they will probably pick, because beating the two they
//      leave at home is worth nothing.
//    · Turn one. Two of yours act against two of theirs before anything else
//      happens, and a lead pair that removes one of theirs before it moves has
//      won a turn the grid average cannot see.
//    · What the four gives up. Leaving your only Tailwind setter, or your only
//      answer to their best Pokémon, at home loses games the six wins.
//
//  Their lead is treated as adversarial: each of your pairs is scored against
//  the pair of theirs that answers it best, never a convenient one. That makes
//  the number a floor rather than an expectation, which is the right way round
//  for a choice you make before seeing what they lead.
//
//  The limits are worth stating. Nobody switches, nobody protects, and nobody
//  predicts, so this is the opening exchange rather than the game. It assumes
//  they bring their strongest four, which good players do and everyone else
//  does not. And it reads what the slots have selected — an opponent whose set
//  is inferred is being answered on a guess about its moves.

import Foundation

@MainActor
struct BringFour {
    let matchup: Matchup
    let store: Store
    /// How many are brought. Four in doubles, three in singles.
    var bring = 4

    init(matchup: Matchup, store: Store, bring: Int = 4) {
        self.matchup = matchup
        self.store = store
        self.bring = bring
    }

    // MARK: - Turn one

    /// What happens on the first turn, against the lead pair of theirs that
    /// answers yours best.
    struct TurnOne {
        let against: [Form]
        let myTarget: Form?
        let myShare: Double
        let myUsing: [Form]
        /// Every attacker the knockout needs moves before the target does, so
        /// it never gets to act. That is a turn won outright rather than traded.
        let myClean: Bool
        let theirTarget: Form?
        let theirShare: Double
        let theirUsing: [Form]
        let theirClean: Bool

        static let none = TurnOne(against: [], myTarget: nil, myShare: 0, myUsing: [],
                                  myClean: false, theirTarget: nil, theirShare: 0,
                                  theirUsing: [], theirClean: false)

        /// Roughly −2…2. Damage counts, but removing something before it moves
        /// is worth much more than the same damage spread across two turns.
        var value: Double {
            var out = min(myShare, 1.5) - min(theirShare, 1.5)
            if myShare >= 1 { out += myClean ? 0.6 : 0.25 }
            if theirShare >= 1 { out -= theirClean ? 0.6 : 0.25 }
            return out
        }

        private func names(_ forms: [Form]) -> String {
            let labels = forms.map(\.formLabel)
            if labels.count == 2 { return "\(labels[0]) and \(labels[1])" }
            return labels.joined(separator: ", ")
        }

        /// The exchange in a sentence.
        ///
        /// The two halves are alternatives rather than a sequence: each side's
        /// best focus is worked out against a full board, and only one of them
        /// can actually land as described. So their half is phrased as what
        /// they *can* do, which is what it is.
        var line: String {
            guard let myTarget else { return "Nothing here attacks on turn one." }
            var parts: [String] = []
            let verb = myUsing.count == 1 ? "removes" : "remove"
            if myShare >= 1 {
                parts.append(myClean
                    ? "\(names(myUsing)) \(verb) their \(myTarget.formLabel) before it moves."
                    : "\(names(myUsing)) \(verb) their \(myTarget.formLabel), but it gets its turn first.")
            } else {
                parts.append("The most you get is their \(myTarget.formLabel) to "
                             + "\(Int((myShare * 100).rounded()))%, so no knockout turn one.")
            }
            if let theirTarget, theirShare >= 1 {
                parts.append(theirClean
                    ? "They can trade by taking \(theirTarget.formLabel) off you before it acts."
                    : "They can trade by taking \(theirTarget.formLabel) off you, though it acts first.")
            } else if let theirTarget, theirShare > 0.6 {
                parts.append("Their best back is your \(theirTarget.formLabel) to "
                             + "\(Int((theirShare * 100).rounded()))%.")
            }
            return parts.joined(separator: " ")
        }
    }

    /// The most one side's pair can do to a single target in one turn, and
    /// whether the target lives long enough to act.
    private func focus(_ target: Form, by attackers: [Form],
                       mineAttacking: Bool) -> (share: Double, clean: Bool, used: [Form]) {
        var entries: [(form: Form, share: Double, first: Bool)] = []
        for attacker in attackers {
            guard let cell = mineAttacking ? matchup.cell(mine: attacker, theirs: target)
                                           : matchup.cell(mine: target, theirs: attacker)
            else { continue }
            // A setup or status turn is not part of a focus: it deals nothing
            // on the turn it is spent.
            let setup = mineAttacking ? cell.mySetupTurns : cell.theirSetupTurns
            guard setup == 0 else { continue }
            let share = mineAttacking ? cell.effectiveOutgoing : cell.effectiveIncoming
            let movesFirst = mineAttacking ? cell.mySpeed > cell.theirSpeed
                                           : cell.theirSpeed > cell.mySpeed
            entries.append((attacker, share, movesFirst))
        }
        let ranked = entries.sorted { $0.share > $1.share }
        guard let top = ranked.first else { return (0, false, []) }
        // One attacker that does it alone leaves the other free for the rest of
        // the board, so it is the better line even though the total is smaller.
        if top.share >= 1 { return (top.share, top.first, [top.form]) }
        guard ranked.count >= 2 else { return (top.share, false, [top.form]) }
        let pair = Array(ranked.prefix(2))
        return (pair.reduce(0) { $0 + $1.share }, pair.allSatisfy(\.first), pair.map(\.form))
    }

    /// One lead pair against one lead pair.
    func turnOne(leads: [Form], against theirLeads: [Form]) -> TurnOne {
        var mine: (target: Form, share: Double, clean: Bool, used: [Form])?
        for target in theirLeads {
            let hit = focus(target, by: leads, mineAttacking: true)
            if mine == nil || hit.share > mine!.share {
                mine = (target, hit.share, hit.clean, hit.used)
            }
        }
        var theirs: (target: Form, share: Double, clean: Bool, used: [Form])?
        for target in leads {
            let hit = focus(target, by: theirLeads, mineAttacking: false)
            if theirs == nil || hit.share > theirs!.share {
                theirs = (target, hit.share, hit.clean, hit.used)
            }
        }
        return TurnOne(against: theirLeads,
                       myTarget: mine?.target, myShare: mine?.share ?? 0,
                       myUsing: mine?.used ?? [], myClean: mine?.clean ?? false,
                       theirTarget: theirs?.target, theirShare: theirs?.share ?? 0,
                       theirUsing: theirs?.used ?? [], theirClean: theirs?.clean ?? false)
    }

    // MARK: - What they will bring

    /// At most one Mega: a second cannot evolve, so bringing it wastes a slot
    /// on a Pokémon holding an item it can never use.
    private func legal(_ four: [Form]) -> Bool {
        four.filter(\.isMega).count <= 1
    }

    /// The four of theirs that gives you the least, which is the four a good
    /// player brings. They choose against your six exactly as you choose
    /// against theirs, both sides blind.
    var theirLikelyFour: [Form] {
        let theirs = matchup.theirForms
        guard theirs.count > bring else { return theirs }
        var worst: (four: [Form], edge: Int)?
        for four in combinations(theirs, bring) where legal(four) {
            let edge = matchup.rate(bringing: matchup.myForms, against: four).score
            if worst == nil || edge < worst!.edge { worst = (four, edge) }
        }
        return worst?.four ?? Array(theirs.prefix(bring))
    }

    /// How much each of theirs counts when scoring your four.
    ///
    /// Full weight to the four they will most likely bring, and a third to the
    /// two they probably leave home — a third rather than nothing, because this
    /// is a prediction about someone else's team and it will sometimes be wrong.
    private func bringWeights(_ likely: [Form]) -> [String: Double] {
        let chosen = Set(likely.map(\.id))
        var out: [String: Double] = [:]
        for form in matchup.theirForms {
            out[form.id] = chosen.contains(form.id) ? 1.0 : 0.35
        }
        return out
    }

    // MARK: - Output

    struct Plan: Identifiable {
        /// The four, lead pair first.
        let bring: [Form]
        let benched: [Form]
        /// Grid edge for this four against their six, weighted by what they
        /// will probably bring. −100…100, the same scale as the versus verdict.
        let edge: Int
        let turnOne: TurnOne
        /// What it is ranked on: the grid edge plus what turn one is worth.
        let score: Int
        let reasons: [String]
        let warnings: [String]

        var leads: [Form] { Array(bring.prefix(2)) }
        var back: [Form] { Array(bring.dropFirst(2)) }
        var id: String { bring.map(\.id).joined(separator: "+") }
    }

    /// Turn one is one turn of maybe eight, but it is the turn that decides
    /// whether the other seven are played a Pokémon up. Worth a real share of
    /// the ranking and capped so it cannot overturn a four that is simply
    /// better across the board.
    private func tempoBonus(_ turn: TurnOne) -> Int {
        Int((turn.value * 15).rounded().clamped(to: -25...25))
    }

    /// Every four, ranked. Best first.
    var plans: [Plan] {
        let mine = matchup.myForms
        guard mine.count >= 2, !matchup.theirForms.isEmpty else { return [] }
        let likely = theirLikelyFour
        let weights = bringWeights(likely)

        // A six that is already at or below the bring limit has no choice to
        // make about who comes, only about who starts.
        let fours = mine.count <= bring ? [mine] : combinations(mine, bring).filter(legal)
        guard !fours.isEmpty else { return [] }

        var out: [Plan] = []
        for four in fours {
            let rated = matchup.rate(bringing: four, against: matchup.theirForms,
                                     weights: weights)
            // Their lead is the one that answers yours best, so every pair of
            // yours is scored on its worst case rather than its best.
            var best: (leads: [Form], turn: TurnOne)?
            for pair in combinations(four, 2) {
                var floor: TurnOne?
                for theirPair in combinations(likely, 2) {
                    let turn = turnOne(leads: pair, against: theirPair)
                    if floor == nil || turn.value < floor!.value { floor = turn }
                }
                guard let floor else { continue }
                if best == nil || floor.value > best!.turn.value { best = (pair, floor) }
            }
            let leads = best?.leads ?? Array(four.prefix(2))
            let turn = best?.turn ?? .none
            let ordered = leads + four.filter { form in !leads.contains { $0.id == form.id } }
            let benched = mine.filter { form in !four.contains { $0.id == form.id } }

            out.append(Plan(bring: ordered, benched: benched, edge: rated.score,
                            turnOne: turn,
                            score: (rated.score + tempoBonus(turn)).clamped(to: -100...100),
                            reasons: reasons(four: ordered, benched: benched, turn: turn,
                                             likely: likely, focusKOs: rated.focusKOs),
                            warnings: warnings(four: ordered, benched: benched,
                                               likely: likely,
                                               focusKOs: rated.focusKOs,
                                               focusedOnMe: rated.focusedOnMe)))
        }
        return out.sorted { $0.score > $1.score }
    }

    // MARK: - Saying why

    /// Whether anything in a set both beats `target` and is worth naming.
    private func answers(_ target: Form, within four: [Form]) -> [Form] {
        four.filter { matchup.cell(mine: $0, theirs: target)?.outcome == .win }
    }

    private func reasons(four: [Form], benched: [Form], turn: TurnOne,
                         likely: [Form], focusKOs: [Matchup.FocusKO]) -> [String] {
        var out: [String] = []
        if !turn.against.isEmpty {
            // The exchange itself is `turn.line`, shown on its own. Repeating it
            // here printed the same sentence twice on the screen.
            let theirLead = turn.against.map(\.formLabel).joined(separator: " and ")
            out.append("Lead \(four.prefix(2).map(\.formLabel).joined(separator: " and ")); "
                       + "their strongest answer to that is \(theirLead).")
        }

        // Anything that is the team's only answer to something they will bring
        // has to come, and that is usually the whole reason a four looks odd.
        for threat in likely {
            let all = answers(threat, within: matchup.myForms)
            guard all.count == 1, let only = all.first,
                  four.contains(where: { $0.id == only.id }) else { continue }
            out.append("\(only.formLabel) is the only thing on your six that beats their "
                       + "\(threat.formLabel), so it comes whatever else changes.")
        }

        for ko in focusKOs.prefix(2) where four.contains(where: { $0.id == ko.first.id })
            && four.contains(where: { $0.id == ko.second.id }) {
            // When nothing in the four beats the target one-on-one, the warning
            // says this already and says it better — it adds "keep both alive".
            guard !answers(ko.target, within: four).isEmpty else { continue }
            out.append("\(ko.first.formLabel) and \(ko.second.formLabel) together remove "
                       + "\(ko.target.formLabel) in a turn; neither does it alone.")
        }

        // What the back two are actually for. A four is not four Pokémon that
        // each beat something; it is two that start and two that come in when
        // the first pair runs into the wrong thing.
        let ways = matchup.retreats(bringing: four)
            .filter { retreat in likely.contains { $0.id == retreat.against.id } }
        if let escape = ways.first(where: { $0.pivot != nil && $0.into != nil }),
           let into = escape.into, let pivot = escape.pivot {
            out.append("If \(escape.from.formLabel) is caught by their "
                       + "\(escape.against.formLabel), \(pivot) takes it out into "
                       + "\(into.formLabel), which beats it.")
        } else if let escape = ways.first(where: { $0.into != nil }),
                  let into = escape.into {
            out.append("\(escape.from.formLabel) loses to their \(escape.against.formLabel), "
                       + "but \(into.formLabel) can come in on it — a turn, not a Pokémon.")
        }

        // Why the two at home are at home. A four is chosen by what it leaves
        // out as much as by what it takes.
        for form in benched {
            let losses = likely.filter {
                matchup.cell(mine: form, theirs: $0)?.outcome == .loss
            }.count
            let wins = likely.filter {
                matchup.cell(mine: form, theirs: $0)?.outcome == .win
            }.count
            if wins == 0 && losses > 0 {
                out.append("Your \(form.formLabel) stays home: it beats none of the four "
                           + "they will bring and loses to \(losses) of them.")
            } else if let mega = benched.first(where: \.isMega),
                      mega.id == form.id,
                      four.contains(where: \.isMega) {
                out.append("Your \(form.formLabel) stays home because only one Pokémon may "
                           + "Mega Evolve, and the other is the better one here.")
            } else if wins == 0 {
                out.append("Your \(form.formLabel) stays home: nothing it beats is coming.")
            }
        }
        return out
    }

    private func warnings(four: [Form], benched: [Form], likely: [Form],
                          focusKOs: [Matchup.FocusKO],
                          focusedOnMe: [Matchup.FocusKO]) -> [String] {
        var out: [String] = []
        for threat in likely where answers(threat, within: four).isEmpty {
            // Two of yours removing it together is a real answer, just not a
            // one-on-one one — saying "nothing beats it" next to "these two
            // remove it in a turn" is the sort of contradiction that makes the
            // whole screen read as noise.
            // Species clause is per team, so both sides can field the same
            // Pokémon — and these two lists often do. "Garchomp stays home"
            // beside "nothing beats Garchomp" is unreadable without the "their".
            if let ko = focusKOs.first(where: { $0.target.id == threat.id }) {
                out.append("Their \(threat.formLabel) beats every one of this four on its "
                           + "own. It only goes down to \(ko.first.formLabel) and "
                           + "\(ko.second.formLabel) together, so keep both alive.")
                continue
            }
            let athome = answers(threat, within: benched)
            out.append(athome.isEmpty
                ? "Nothing in this four beats their \(threat.formLabel)."
                : "Nothing in this four beats their \(threat.formLabel) — "
                  + "\(athome[0].formLabel), which does, is one of the two you left home.")
        }
        // Shadow Tag is the one thing that makes a lost cell a lost Pokémon,
        // and it is the only trapping ability in the format.
        for retreat in matchup.retreats(bringing: four)
            where retreat.trapped && likely.contains(where: { $0.id == retreat.against.id }) {
            out.append("Their \(retreat.against.formLabel) traps with Shadow Tag: "
                       + "\(retreat.from.formLabel) cannot switch away from it once they meet.")
            break
        }
        for ko in focusedOnMe.prefix(1) {
            out.append("They can focus \(ko.target.formLabel) down in one turn with "
                       + "\(ko.first.formLabel) and \(ko.second.formLabel). Do not lead it "
                       + "into both.")
        }
        // Speed control and redirection are team-wide jobs, and a four that
        // drops the only Pokémon doing one of them has changed what it is.
        for (job, moves) in [("speed control", ["Tailwind", "Trick Room"]),
                             ("redirection", ["Follow Me", "Rage Powder"]),
                             ("a Fake Out", ["Fake Out"])] {
            let names = Set(moves)
            func has(_ forms: [Form]) -> [Form] {
                forms.filter { form in
                    guard let slot = matchup.myPairs.first(where: { $0.1.id == form.id })?.0
                    else { return false }
                    return slot.moves.contains { names.contains(store.move($0)?.name ?? "") }
                }
            }
            let onSix = has(matchup.myForms)
            guard !onSix.isEmpty, has(four).isEmpty else { continue }
            out.append("This four has no \(job): \(onSix.map(\.formLabel).joined(separator: " and ")) "
                       + "\(onSix.count == 1 ? "is" : "are") staying home.")
        }
        return out
    }

    // MARK: - Combinations

    /// Every way of choosing `count` from `items`, order ignored.
    private func combinations<T>(_ items: [T], _ count: Int) -> [[T]] {
        guard count > 0 else { return [[]] }
        guard items.count >= count else { return [] }
        if items.count == count { return [items] }
        let head = items[0], tail = Array(items.dropFirst())
        return combinations(tail, count - 1).map { [head] + $0 } + combinations(tail, count)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
