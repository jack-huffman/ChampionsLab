//  Matchup.swift
//  Team versus team.
//
//  The threat matrix answers "how do I fare against this one Pokémon". That is
//  not the same question as "how do I fare against this team", because a team
//  gets to choose which of its six leads and which four it brings. This file
//  works the grid: every one of mine against every one of theirs, both
//  directions, then aggregates it into who is carrying the matchup and who is
//  dead weight.

import Foundation

/// One cell of the grid: my Pokémon against theirs.
struct Duel: Identifiable {
    let mine: Form
    let theirs: Form
    /// Fraction of the opponent's HP my best move deals, on the high roll.
    let outgoing: Double
    /// Fraction of my HP their best move deals.
    let incoming: Double
    let mySpeed: Int
    let theirSpeed: Int
    let myBestMove: String
    let theirBestMove: String
    /// How much of that damage you can count on — accuracy, and what the move
    /// costs you to click. A 70% accurate "OHKO" is not an OHKO, and a Steel
    /// Beam that halves your own HP is not the same trade as an Iron Head.
    var myReliability: Double = 1
    var theirReliability: Double = 1
    /// Turns spent setting up or applying status before attacking starts.
    var mySetupTurns: Int = 0
    var theirSetupTurns: Int = 0
    /// A selected move that leaves the field after acting — U-turn, Volt
    /// Switch, Flip Turn, Parting Shot, Baton Pass. Leaving is free either way,
    /// but a pivot leaves having done something.
    var myPivot: String?
    var theirPivot: String?
    /// Protect, or one of its family. Most VGC sets carry one and the model had
    /// never heard of it: a turn of damage refused is a turn added to whatever
    /// clock the other side is racing, and it is the answer to being focused.
    var myProtect: String?
    var theirProtect: String?
    /// Shadow Tag on the other side. In Regulation M-C that is Mega Gengar and
    /// nothing else: no other Pokémon in the dex has a trapping ability, and no
    /// move in it traps at all.
    var iAmTrapped = false
    var theyAreTrapped = false

    var id: String { "\(mine.id)-vs-\(theirs.id)" }

    var effectiveOutgoing: Double { outgoing * myReliability }
    var effectiveIncoming: Double { incoming * theirReliability }

    var iAmFaster: Bool { mySpeed > theirSpeed }

    /// Turns this side needs to knock the other out, on the high roll,
    /// including any spent setting up or applying status first.
    ///
    /// A Protect on the far side adds one: it refuses a turn of damage, so
    /// whatever clock you are racing gets a turn longer. Counted once, because
    /// using it twice in a row mostly fails, and not modelled as the prediction
    /// game it really is — a Protect clicked on the wrong turn does nothing,
    /// and nothing here is choosing turns.
    var myTurnsToKO: Int {
        guard effectiveOutgoing > 0 else { return 99 }
        return mySetupTurns + Int(ceil(1 / effectiveOutgoing)) + (theirProtect != nil ? 1 : 0)
    }
    var theirTurnsToKO: Int {
        guard effectiveIncoming > 0 else { return 99 }
        return theirSetupTurns + Int(ceil(1 / effectiveIncoming)) + (myProtect != nil ? 1 : 0)
    }

    /// How a side gets out of a cell it is losing.
    ///
    /// Switching resolves before any move is used, so leaving always works —
    /// the question is what it costs, not whether it is possible. That makes a
    /// lost one-on-one normally a lost turn rather than a lost Pokémon, which
    /// is the single biggest thing this grid used to get wrong: it scored every
    /// bad cell as though you were nailed to the floor in it.
    enum Exit {
        /// Winning it; nothing to escape from.
        case notNeeded
        /// A pivot move: out on your own terms, having done something first.
        case pivot
        /// Out, but the turn is spent and the switch-in takes the hit.
        case switchOut
        /// Shadow Tag. You are in this cell until one of you faints.
        case trapped
    }

    var myExit: Exit {
        if outcome == .win || outcome == .favoured { return .notNeeded }
        if iAmTrapped { return .trapped }
        return myPivot != nil ? .pivot : .switchOut
    }

    var theirExit: Exit {
        if outcome == .loss || outcome == .against { return .notNeeded }
        if theyAreTrapped { return .trapped }
        return theirPivot != nil ? .pivot : .switchOut
    }

    /// Rough 1v1 verdict, respecting who moves first.
    ///
    /// This stays the pure one-on-one answer — "would this lose if the two were
    /// left alone" — and says nothing about switching. What leaving is worth is
    /// applied when cells are added up, so that the grid on screen still reads
    /// as the honest matchup rather than a matchup already discounted.
    ///
    /// Speed is not just a tie-break. It used to be consulted only when both
    /// sides scored a one-hit knockout; every other cell — which is most of
    /// them — compared raw damage ratios and ignored turn order entirely. That
    /// scored a two-hit race identically whether you moved first or last, which
    /// is the opposite of how those games go.
    ///
    /// Both sides are now raced: how many turns each needs, and who lands the
    /// last one. Moving first wins an equal race outright.
    var outcome: Outcome {
        // A one-hit knockout only counts if it happens on the first turn; a
        // setup turn means they get to act first whatever the damage says.
        let iKO = effectiveOutgoing >= 1.0 && mySetupTurns == 0
        let theyKO = effectiveIncoming >= 1.0 && theirSetupTurns == 0
        switch (iKO, theyKO) {
        case (true, true):
            // A genuine speed tie is a coin flip, not a loss. Scoring it as a
            // loss biased every mirror match negative.
            if mySpeed == theirSpeed { return .neutral }
            return iAmFaster ? .win : .loss
        case (true, false):  return .win
        case (false, true):  return .loss
        case (false, false):
            let mine = myTurnsToKO, theirs = theirTurnsToKO
            // Two clear turns ahead is a win, not merely an advantage.
            if mine + 2 <= theirs { return .win }
            if theirs + 2 <= mine { return .loss }
            if mine < theirs { return .favoured }
            if theirs < mine { return .against }
            // Same number of turns: whoever moves first lands the last hit.
            if mySpeed == theirSpeed { return .neutral }
            return iAmFaster ? .favoured : .against
        }
    }

    enum Outcome: String {
        case win = "Win"
        case favoured = "Favoured"
        case neutral = "Even"
        case against = "Against"
        case loss = "Loss"

        var score: Double {
            switch self {
            case .win: return 1.0
            case .favoured: return 0.5
            case .neutral: return 0.0
            case .against: return -0.5
            case .loss: return -1.0
            }
        }
    }
}

/// How one of my Pokémon does across their whole team.
struct MemberReport: Identifiable {
    let form: Form
    let duels: [Duel]
    var id: String { form.id }

    var wins: Int { duels.filter { $0.outcome == .win }.count }
    var losses: Int { duels.filter { $0.outcome == .loss }.count }
    var score: Double { duels.reduce(0) { $0 + $1.outcome.score } }

    /// Beats nothing and loses to most of it — the slot to cut.
    var isDeadWeight: Bool { wins == 0 && losses >= max(2, duels.count / 2) }
}

/// How one of *their* Pokémon does against my whole team.
struct OpposingReport: Identifiable {
    let form: Form
    let duels: [Duel]
    var id: String { form.id }

    /// My members that beat it.
    var answeredBy: [Form] { duels.filter { $0.outcome == .win }.map(\.mine) }
    var beats: [Form] { duels.filter { $0.outcome == .loss }.map(\.mine) }
    var isUnanswered: Bool { answeredBy.isEmpty }
    var threatScore: Double { duels.reduce(0) { $0 - $1.outcome.score } }
}

@MainActor
struct Matchup {
    let mine: Team
    let theirs: Team
    let store: Store
    var field: Field = Field()
    /// Speed control in effect for each side. Tailwind doubles Speed for four
    /// turns, which decides a large share of the one-on-ones — scoring without
    /// it made every support Pokémon look like a wasted slot.
    var myTailwind = false
    var theirTailwind = false
    var myTrickRoom = false

    /// Computed once at construction; every report below reads this array.
    ///
    /// A var rather than a let only because buildDuels() needs a fully
    /// initialised self to run — it is never written again after init.
    private(set) var duels: [Duel] = []

    /// The grid by cell id, because the bring-four search reads single cells
    /// several hundred times and a linear scan of thirty-six is not free.
    private var byCell: [String: Duel] = [:]

    init(mine: Team, theirs: Team, store: Store, field: Field = Field(),
         myTailwind: Bool = false, theirTailwind: Bool = false,
         myTrickRoom: Bool = false) {
        self.mine = mine
        self.theirs = theirs
        self.store = store
        self.field = field
        self.myTailwind = myTailwind
        self.theirTailwind = theirTailwind
        self.myTrickRoom = myTrickRoom
        self.duels = buildDuels()
        self.byCell = Dictionary(duels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// One cell of the grid: how mine fares against theirs.
    func cell(mine: Form, theirs: Form) -> Duel? { byCell["\(mine.id)-vs-\(theirs.id)"] }

    /// Effective Speed for the comparison that decides who moves first.
    /// Trick Room inverts the order, so it is expressed by negating both sides.
    private func order(mine: Int, theirs: Int) -> (Int, Int) {
        let a = myTailwind ? mine * 2 : mine
        let b = theirTailwind ? theirs * 2 : theirs
        return myTrickRoom ? (-a, -b) : (a, b)
    }

    /// A representative build for a slot. Anything the paste or archetype left
    /// blank gets the obvious default rather than zero, so an unspecified team
    /// does not read as harmless.
    private func combatant(_ slot: TeamSlot, form: Form) -> Combatant {
        // A Mega fights with its own ability, which is most of the reason to
        // evolve: Salamence's Intimidate becomes Aerilate, and that changes
        // what its moves are as well as how hard they hit.
        let ability = slot.megaEvolution(in: store)?.abilities.first?.name
            ?? (slot.ability.isEmpty ? (form.abilities.first?.name ?? "") : slot.ability)
        var c = Combatant(form: form, ability: ability, item: slot.item,
                          sp: slot.sp, alignment: slot.alignment)
        if slot.sp.allSatisfy({ $0 == 0 }) {
            let physical = form.attack >= form.spAttack
            var sp = Array(repeating: 0, count: 6)
            sp[physical ? Stat.attack.rawValue : Stat.spAttack.rawValue] = 32
            sp[Stat.speed.rawValue] = 32
            c.sp = sp
        }
        return c
    }

    /// The slot's whole set, falling back to the form's best STAB when it has
    /// nothing selected. Status and setup moves are included deliberately —
    /// filtering to damage is what made Will-O-Wisp and Swords Dance worth zero.
    /// `ability` is the one the Pokémon fights with, which is not always the
    /// one on the slot: a Mega brings its own, and an -ate ability changes both
    /// the type and the power of half the moves being ranked. Passing the
    /// slot's ability here handed Mega Salamence a Dragon move, because
    /// Aerilate was not in the room when Double-Edge was priced.
    private func moves(_ slot: TeamSlot, form: Form, ability: String) -> [Move] {
        let chosen = slot.moves.compactMap { store.move($0) }
        if chosen.contains(where: \.isDamaging) { return chosen }
        let learnable = store.moves(for: form).filter { $0.isDamaging && $0.power > 0 }
        // Under the effective type, not the printed one: filtering on the
        // printed type drops every -ate move out of its own user's STAB pool.
        let stab = learnable.filter {
            form.types.contains(AteAbility.resolve(type: $0.type, ability: ability).type)
        }
        let pool = stab.isEmpty ? learnable : stab
        // Ranked on what the move is worth, not its base power: otherwise the
        // fallback set is Giga Impact and Steel Beam every time.
        return Array(pool.sorted {
            store.moveValue($0, for: form, ability: ability, item: slot.item)
                > store.moveValue($1, for: form, ability: ability, item: slot.item)
        }.prefix(3))
    }

    /// The form each slot fights as, not the one it is registered as.
    ///
    /// Champions registers the base Pokémon holding its stone, so a team list
    /// says "Salamence @ Salamencite" and a Mega Salamence walks out. This grid
    /// read the registered form, which meant 186 of the 192 stone-holders in the
    /// bundled team lists were duelled as their unevolved selves — Salamence at
    /// 600 base stats with Intimidate rather than 700 with Aerilate.
    var myPairs: [(TeamSlot, Form)] {
        mine.slots.compactMap { slot in
            slot.battleForm(in: store).map { (slot, $0) }
        }
    }

    var theirPairs: [(TeamSlot, Form)] {
        theirs.slots.compactMap { slot in
            slot.battleForm(in: store).map { (slot, $0) }
        }
    }

    private var mineTeamFormat: String { mine.format }

    var myForms: [Form] { myPairs.map(\.1) }
    var theirForms: [Form] { theirPairs.map(\.1) }

    // MARK: - Grid

    /// The whole grid, computed once.
    ///
    /// This used to be a computed property, and `verdict`, `memberReports` and
    /// `opposingReports` each re-ran it — so drawing the Versus screen worked the
    /// grid five or six times over.
    private func buildDuels() -> [Duel] {
        var out: [Duel] = []
        for (mySlot, myForm) in myPairs {
            let me = combatant(mySlot, form: myForm)
            let myMoves = moves(mySlot, form: myForm, ability: me.ability)
            for (theirSlot, theirForm) in theirPairs {
                let them = combatant(theirSlot, form: theirForm)
                let theirMoves = moves(theirSlot, form: theirForm, ability: them.ability)

                let speeds = order(mine: me.speed(in: field), theirs: them.speed(in: field))
                out.append(DuelEngine.duel(
                    mine: DuelEngine.Side(combatant: me, moves: myMoves, speed: speeds.0),
                    theirs: DuelEngine.Side(combatant: them, moves: theirMoves, speed: speeds.1),
                    field: field, store: store))
            }
        }
        return out
    }

    var memberReports: [MemberReport] {
        let all = duels
        return myPairs.map { _, form in
            MemberReport(form: form, duels: all.filter { $0.mine.id == form.id })
        }
    }

    var opposingReports: [OpposingReport] {
        let all = duels
        return theirPairs.map { _, form in
            OpposingReport(form: form, duels: all.filter { $0.theirs.id == form.id })
        }
        .sorted { $0.threatScore > $1.threatScore }
    }

    // MARK: - Verdict

    struct Verdict {
        /// −100 (losing badly) to +100 (winning comfortably).
        let score: Int
        let headline: String
        let winCount: Int
        let lossCount: Int
        let totalCells: Int
        let speedEdge: Int
        let unanswered: [Form]
        let deadWeight: [Form]
        let advice: [String]
        /// Opponents two of yours can remove in a single turn together, and the
        /// pair that does it. This is how knockouts actually happen in doubles;
        /// scoring one attacker at a time misses most of them.
        let focusKOs: [FocusKO]
        /// The same thing done to you.
        let focusedOnMe: [FocusKO]
    }

    struct FocusKO: Identifiable {
        let target: Form
        let first: Form
        let second: Form
        /// Combined share of the target's health, 0…1+.
        let combined: Double
        /// The target is running Protect, so this is a read rather than a
        /// knockout — the most common thing Protect is actually for.
        var refusedBy: String?
        var id: String { target.id }
    }

    /// Every target two attackers can remove together in one turn.
    ///
    /// Doubles gives you two actions a turn, so the question is not "does any
    /// one of mine beat that" but "can two of mine remove it before it acts".
    /// A team of four that individually trade evenly but can focus down their
    /// win condition is winning a game the one-on-one grid calls even.
    /// Members of a side running Helping Hand or Coaching.
    private func boosterIDs(_ pairs: [(TeamSlot, Form)]) -> Set<String> {
        Set(pairs.filter { slot, _ in
            slot.moves.contains { ["Helping Hand", "Coaching"].contains(store.move($0)?.name) }
        }.map(\.1.id))
    }

    private func focusFire(attackers: [Form], defenders: [Form], cells: [Duel],
                           mineAttacking: Bool, boosterSet: Set<String>) -> [FocusKO] {
        var out: [FocusKO] = []
        // Helping Hand and Coaching are the other way two Pokémon remove one
        // target: instead of both attacking, one boosts and the other hits for
        // half again as much. They did nothing in this model before, because
        // they deal no damage on the turn they are used.
        //
        // Only boosters among `attackers` count — a four that left the Helping
        // Hand user at home must not be credited with the boost.
        let boosters = attackers.filter { boosterSet.contains($0.id) }
        let boost = boosters.isEmpty ? 1.0 : 1.5
        for defender in defenders {
            // Every attacker's single-turn share of this defender.
            let shares: [(Form, Double)] = attackers.compactMap { attacker in
                guard let cell = cells.first(where: {
                    mineAttacking ? ($0.mine.id == attacker.id && $0.theirs.id == defender.id)
                                  : ($0.theirs.id == attacker.id && $0.mine.id == defender.id)
                }) else { return nil }
                // Only damage available on the turn itself: a setup turn is not
                // part of a focus.
                let setup = mineAttacking ? cell.mySetupTurns : cell.theirSetupTurns
                guard setup == 0 else { return (attacker, 0) }
                let share = mineAttacking ? cell.effectiveOutgoing : cell.effectiveIncoming
                return (attacker, share)
            }
            let ranked = shares.sorted { $0.1 > $1.1 }
            guard ranked.count >= 2 else { continue }
            // Two attacks, or one attack backed by Helping Hand — whichever
            // actually removes the target.
            let bothAttack = ranked[0].1 + ranked[1].1
            let boosted = boosters.contains { $0.id != ranked[0].0.id }
                ? ranked[0].1 * boost : 0
            let combined = max(bothAttack, boosted)
            // Only interesting when neither could do it alone.
            guard combined >= 1.0, ranked[0].1 < 1.0 else { continue }
            let partner = boosted > bothAttack
                ? (boosters.first { $0.id != ranked[0].0.id } ?? ranked[1].0)
                : ranked[1].0
            // Whether the target can simply refuse it. Focusing something with
            // Protect up is the single most common way a "guaranteed" knockout
            // does not happen, so it is worth saying rather than scoring a
            // certainty that is a coin flip.
            let cell = cells.first {
                mineAttacking ? $0.theirs.id == defender.id : $0.mine.id == defender.id
            }
            let refusedBy = mineAttacking ? cell?.theirProtect : cell?.myProtect
            out.append(FocusKO(target: defender, first: ranked[0].0,
                               second: partner, combined: combined,
                               refusedBy: refusedBy))
        }
        return out.sorted { $0.combined > $1.combined }
    }

    /// Where a member in trouble goes, and what gets it there.
    ///
    /// The grid says a cell is lost. In doubles that is usually not the end of
    /// it — you leave, because switching resolves before any move. The question
    /// the grid cannot answer on its own is whether there is anything to leave
    /// *to*: a lost cell with a good switch-in costs a turn, and a lost cell
    /// with nowhere to go costs the Pokémon.
    struct Retreat: Identifiable {
        let from: Form
        let against: Form
        /// A member that beats what you are running from and is not knocked out
        /// coming in. Nil when the team has no such answer.
        let into: Form?
        /// The move that gets you out having done something, if you have one.
        let pivot: String?
        let trapped: Bool
        var id: String { "\(from.id)-from-\(against.id)" }
    }

    /// Who can come in on each of theirs: beats it, and survives the hit it
    /// takes on the way in. Winning the cell is not enough — a switch-in that
    /// is removed as it lands is not a switch-in.
    private func refuge(mineForms: [Form], theirForms: [Form]) -> [String: Form] {
        var out: [String: Form] = [:]
        for their in theirForms {
            out[their.id] = mineForms.first { candidate in
                guard let c = cell(mine: candidate, theirs: their) else { return false }
                return c.outcome == .win && c.effectiveIncoming < 1
            }
        }
        return out
    }

    /// The same thing the other way: which of theirs can come in on mine.
    private func theirRefuge(mineForms: [Form], theirForms: [Form]) -> [String: Form] {
        var out: [String: Form] = [:]
        for mine in mineForms {
            out[mine.id] = theirForms.first { candidate in
                guard let c = cell(mine: mine, theirs: candidate) else { return false }
                return c.outcome == .loss && c.effectiveOutgoing < 1
            }
        }
        return out
    }

    /// Every losing cell, with the way out of it.
    func retreats(bringing forms: [Form]? = nil) -> [Retreat] {
        let mineForms = forms ?? myForms
        let ids = Set(mineForms.map(\.id))
        let safe = refuge(mineForms: mineForms, theirForms: theirForms)
        return duels
            .filter { ids.contains($0.mine.id) && $0.outcome == .loss }
            .map { cell in
                let into = safe[cell.theirs.id]
                return Retreat(from: cell.mine, against: cell.theirs,
                               into: into?.id == cell.mine.id ? nil : into,
                               pivot: cell.myPivot, trapped: cell.iAmTrapped)
            }
    }

    /// What a cell is really worth once leaving is accounted for.
    ///
    /// A lost one-on-one that you can walk out of into something that beats the
    /// thing you ran from is a lost turn, not a lost Pokémon, and scoring it as
    /// the latter is why bad matchups read as catastrophes. The same discount
    /// applies to cells you win, because the opponent leaves too — doing it
    /// only on your own losses would inflate every score on the screen.
    ///
    /// These multipliers are judgment rather than measurement, and they are
    /// deliberately mild: the cell is still lost, it just does not cost what
    /// being stuck in it costs.
    private func exitFactor(_ cell: Duel, mine: [String: Form],
                            theirs: [String: Form]) -> Double {
        if cell.outcome.score < 0 {
            if cell.iAmTrapped { return 1.3 }
            guard mine[cell.theirs.id] != nil else { return 1.0 }
            return cell.myPivot != nil ? 0.6 : 0.8
        }
        if cell.outcome.score > 0 {
            if cell.theyAreTrapped { return 1.3 }
            guard theirs[cell.mine.id] != nil else { return 1.0 }
            return cell.theirPivot != nil ? 0.6 : 0.8
        }
        return 1
    }

    /// A speed control move and the window it buys.
    ///
    /// Tailwind is four turns and Trick Room is five, and those numbers are the
    /// whole plan on the teams that run them: the question is not whether you
    /// are faster but whether you can finish inside the window. The engine
    /// could say "you have Tailwind" and could say "this takes three turns to
    /// knock out", and never put the two together.
    ///
    /// Durations come out of the move text rather than a table here, so a
    /// change to the game is picked up by re-running mkdata.py.
    struct Window {
        let tactic: String
        let turns: Int
        /// Attacking actions the window actually gives you. Doubles hands you
        /// two a turn, and counting each target's knockout separately -- as
        /// though the whole team could attack it at once -- said every team
        /// closes every game, which is not a useful thing to be told.
        let actions: Int
        /// Actions needed to remove the four you have to remove to win, worst
        /// case: they choose which four they bring, so this assumes the four
        /// that cost you most.
        let needed: Int
        /// What each of those costs, dearest first.
        let cost: [(them: Form, mine: Form?, turns: Int)]

        var closes: Bool { needed <= actions }
        var shortfall: Int { max(0, needed - actions) }
    }

    /// How many turns a speed control move lasts, read from what it says.
    static func duration(of move: Move) -> Int? {
        guard let match = Matchup.durationPattern.firstMatch(
            in: move.effect, range: NSRange(move.effect.startIndex..., in: move.effect)),
              let range = Range(match.range(at: 1), in: move.effect) else { return nil }
        return Int(move.effect[range])
    }

    private static let durationPattern = try! NSRegularExpression(
        pattern: #"for (\d+) turns"#)

    /// The window this side's own speed control buys, and what fits inside it.
    func window(bringing mineForms: [Form]? = nil,
                against theirForms: [Form]? = nil) -> Window? {
        let mine = mineForms ?? myForms
        let theirs = theirForms ?? self.theirForms
        let mineIDs = Set(mine.map(\.id))

        // The speed control this six is actually running, not what it could.
        var best: (name: String, turns: Int)?
        for (slot, form) in myPairs where mineIDs.contains(form.id) {
            for move in slot.moves.compactMap({ store.move($0) })
            where ["Tailwind", "Trick Room"].contains(move.name) {
                guard let turns = Matchup.duration(of: move) else { continue }
                if best == nil || turns < best!.turns { best = (move.name, turns) }
            }
        }
        guard let control = best else { return nil }

        // What removing each of theirs costs in attacking turns, using the
        // best answer among the ones you brought. Optimistic on two counts --
        // it is the high damage roll, and it assumes the right answer is the
        // one standing there -- so a team that cannot close on these numbers
        // certainly cannot close in a game.
        var cost: [(Form, Form?, Int)] = []
        for their in theirs {
            let quickest = mine.compactMap { form -> (Form, Int)? in
                guard let cell = cell(mine: form, theirs: their) else { return nil }
                return cell.myTurnsToKO < 99 ? (form, cell.myTurnsToKO) : nil
            }.min { $0.1 < $1.1 }
            // Nothing removes it at all: count it as the whole window, since
            // that is what it does to the clock.
            cost.append((their, quickest?.0, quickest?.1 ?? (control.turns * 2 + 1)))
        }
        cost.sort { $0.2 > $1.2 }

        let bring = store.data.rules.formats.first { $0.id == mineTeamFormat }?.bring ?? 4
        let mustRemove = min(bring, cost.count)
        let needed = cost.prefix(mustRemove).reduce(0) { $0 + $1.2 }
        let actions = control.turns * (field.isDoubles ? 2 : 1)

        return Window(tactic: control.name, turns: control.turns,
                      actions: actions, needed: needed,
                      cost: cost.map { (them: $0.0, mine: $0.1, turns: $0.2) })
    }

    /// The edge for any subset of either side, read off the grid already built,
    /// together with the focus knockouts each way.
    ///
    /// `verdict` is this over the whole six; the bring-four search is this over
    /// each of the fifteen fours. Sharing the arithmetic is the point — a four
    /// scored here and the same four entered as its own team have to agree.
    ///
    /// `weights` scales each of theirs by how likely it is to be brought. Only
    /// four of their six will appear, and beating the two they leave at home is
    /// worth nothing.
    func rate(bringing mineForms: [Form], against theirForms: [Form],
              weights: [String: Double] = [:])
        -> (score: Int, focusKOs: [FocusKO], focusedOnMe: [FocusKO]) {
        let mineIDs = Set(mineForms.map(\.id)), theirIDs = Set(theirForms.map(\.id))
        let cells = duels.filter {
            mineIDs.contains($0.mine.id) && theirIDs.contains($0.theirs.id)
        }
        guard !cells.isEmpty else { return (0, [], []) }

        let safe = refuge(mineForms: mineForms, theirForms: theirForms)
        let theirSafe = theirRefuge(mineForms: mineForms, theirForms: theirForms)
        var total = 0.0, weighed = 0.0
        for cell in cells {
            let weight = weights[cell.theirs.id] ?? 1
            let value = cell.outcome.score
                * exitFactor(cell, mine: safe, theirs: theirSafe)
            total += max(-1, min(1, value)) * weight
            weighed += weight
        }
        let raw = weighed > 0 ? total / weighed : 0

        let focusKOs = focusFire(attackers: mineForms, defenders: theirForms, cells: cells,
                                 mineAttacking: true, boosterSet: boosterIDs(myPairs))
        let focusedOnMe = focusFire(attackers: theirForms, defenders: mineForms, cells: cells,
                                    mineAttacking: false, boosterSet: boosterIDs(theirPairs))
        // Worth a real but bounded amount: being able to remove two of theirs
        // by focusing is a genuine edge, not a rout. One the target can refuse
        // with Protect is worth about half, since it becomes a read.
        func weight(_ kos: [FocusKO]) -> Double {
            kos.reduce(0) { $0 + ($1.refusedBy == nil ? 1.0 : 0.5) }
        }
        let focusEdge = (weight(focusKOs) - weight(focusedOnMe))
            / Double(max(mineForms.count, 1)) * 0.35
        return (Int(((raw + focusEdge) * 100).rounded().clamped(to: -100...100)),
                focusKOs, focusedOnMe)
    }

    var verdict: Verdict {
        let all = duels
        guard !all.isEmpty else {
            return Verdict(score: 0, headline: "Pick two teams to compare.",
                           winCount: 0, lossCount: 0, totalCells: 0, speedEdge: 0,
                           unanswered: [], deadWeight: [], advice: [],
                           focusKOs: [], focusedOnMe: [])
        }

        let wins = all.filter { $0.outcome == .win }.count
        let losses = all.filter { $0.outcome == .loss }.count

        // Doubles gives both sides two actions a turn, so a target neither of
        // yours beats alone can still be removed by two of them together. The
        // one-on-one grid cannot see that, and it is how most knockouts happen.
        let rated = rate(bringing: myForms, against: theirForms)
        let score = rated.score
        let focusKOs = rated.focusKOs, focusedOnMe = rated.focusedOnMe

        let faster = all.filter(\.iAmFaster).count
        let speedEdge = Int((Double(faster) / Double(all.count) * 100).rounded())

        let unanswered = opposingReports.filter(\.isUnanswered).map(\.form)
        let dead = memberReports.filter(\.isDeadWeight).map(\.form)

        var advice: [String] = []
        if let worst = opposingReports.first, worst.isUnanswered {
            advice.append("Nothing on your team beats \(worst.form.formLabel). That is the matchup.")
        }
        for form in dead.prefix(2) {
            advice.append("\(form.formLabel) beats none of their six — it is not earning its slot here.")
        }
        if speedEdge < 35 {
            advice.append("You are slower in \(100 - speedEdge)% of the one-on-ones. Tailwind or Trick Room is doing the work, not raw stats.")
        }
        if let star = memberReports.max(by: { $0.score < $1.score }), star.wins > 0 {
            advice.append("\(star.form.formLabel) carries this matchup with \(star.wins) winning matchups.")
        }
        for ko in focusKOs.prefix(2) {
            advice.append(ko.refusedBy.map {
                "\(ko.first.formLabel) and \(ko.second.formLabel) together remove \(ko.target.formLabel) in one turn, but it runs \($0) — so it is a read, not a certainty."
            } ?? "\(ko.first.formLabel) and \(ko.second.formLabel) together remove \(ko.target.formLabel) in one turn — neither does it alone.")
        }
        for ko in focusedOnMe.prefix(1) {
            advice.append("They can focus \(ko.target.formLabel) down in a turn with \(ko.first.formLabel) and \(ko.second.formLabel). Do not lead it into both.")
        }

        // Losing a cell and being stuck in it are different problems, and the
        // grid on its own cannot tell them apart.
        let ways = retreats()
        if let caught = ways.first(where: \.trapped) {
            advice.append("\(caught.against.formLabel) traps with Shadow Tag, so whichever of yours it catches is in that fight to the end. \(caught.from.formLabel) is one of them.")
        }
        if let clean = ways.first(where: { $0.pivot != nil && $0.into != nil }) {
            advice.append("\(clean.from.formLabel) loses to \(clean.against.formLabel), but \(clean.pivot!) takes it out into \(clean.into!.formLabel), which beats it. That is a lost turn, not a lost Pokémon.")
        }
        // The ones with nowhere to go are the real holes: you can always leave,
        // but leaving into something that also loses is not an answer.
        let stranded = Dictionary(grouping: ways.filter { $0.into == nil },
                                  by: { $0.against.id })
        if let worst = stranded.values.max(by: { $0.count < $1.count }), worst.count >= 2,
           let sample = worst.first {
            advice.append("Nothing here can come in on \(sample.against.formLabel) — \(worst.count) of yours lose to it and none of the rest beats it, so switching only changes who is standing in front of it.")
        }
        // Speed control is a clock, not a state. Being faster for four turns
        // only wins if four turns is enough.
        if let window = window() {
            let dearest = window.cost.prefix(2)
                .map { "\($0.them.formLabel) costs \($0.turns)" }.joined(separator: " and ")
            if window.closes {
                advice.append("\(window.tactic) runs \(window.turns) turns, which is \(window.actions) attacking turns in doubles. Removing the four that cost you most takes about \(window.needed), so the plan closes inside its own clock — \(dearest).")
            } else {
                advice.append("\(window.tactic) runs \(window.turns) turns, which is \(window.actions) attacking turns in doubles, and removing the four that cost you most takes about \(window.needed). You are \(window.shortfall) short, so this wins on the turns after it ends rather than during it — \(dearest).")
            }
        }

        // Terrain and weather flip a lot of these cells, so say so once.
        if field.terrain == .none && theirPairs.contains(where: { form in
            form.1.abilities.contains { $0.name.hasSuffix("Surge") }
        }) {
            advice.append("They have a terrain setter; re-run this with their terrain up to see the real numbers.")
        }

        let headline: String
        switch score {
        case 25...:      headline = "Favoured — you out-trade them across the board."
        case 8..<25:     headline = "Slight edge, but it turns on a few cells."
        case -8..<8:     headline = "Close. Lead choice and speed control decide it."
        case -25..<(-8): headline = "Uphill. They have answers you do not."
        default:         headline = "Losing matchup as built."
        }

        return Verdict(score: score, headline: headline, winCount: wins,
                       lossCount: losses, totalCells: all.count, speedEdge: speedEdge,
                       unanswered: unanswered, deadWeight: dead, advice: advice,
                       focusKOs: focusKOs, focusedOnMe: focusedOnMe)
    }
}


private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
