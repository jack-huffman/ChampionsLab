//  SelfPlay.swift
//  Playing a whole game out, with an engine in each chair.
//
//  This is the machinery behind `make duel`. It lives in the library rather
//  than in the tool because it is the only place that knows how to take a
//  position from the opening to somebody winning, and a test wants that too.

import Foundation

enum SelfPlay {
    enum Winner: Sendable { case mine, theirs, none }

    struct Outcome: Sendable {
        let winner: Winner
        let turns: Int
    }

    /// What one Pokémon did in one game.
    ///
    /// Counted per form rather than per slot, because a slot is whoever is
    /// standing in it and the question is always about the Pokémon.
    struct Tally: Sendable {
        var brought = 0
        var survived = 0
        var faints = 0
        var knockouts = 0
        var damageDealt = 0
        var damageTaken = 0
        /// How often each move was actually played. A move that never appears
        /// here across a thousand games is a slot the team is not using.
        var moves: [String: Int] = [:]

        static func + (a: Tally, b: Tally) -> Tally {
            var out = a
            out.brought += b.brought; out.survived += b.survived
            out.faints += b.faints; out.knockouts += b.knockouts
            out.damageDealt += b.damageDealt; out.damageTaken += b.damageTaken
            for (move, count) in b.moves { out.moves[move, default: 0] += count }
            return out
        }
    }

    /// How a Pokémon is named in a record.
    ///
    /// A Mega and the Pokémon it evolved from are one entry, because they are
    /// one Pokémon across a game and splitting them put Garchomp on the table
    /// with nothing beside it and Mega Garchomp Z with all of its work. By name
    /// rather than by species: species would fold Alolan Ninetales into
    /// Ninetales, and in this format those are two different Pokémon with
    /// different types and different abilities.
    ///
    /// Anything reading a record back has to key it the same way, which is why
    /// this is not a local function any more.
    static func recordLabel(_ form: Form) -> String {
        guard form.isMega else { return form.formLabel }
        var base = form.formLabel
        if base.hasPrefix("Mega ") { base.removeFirst(5) }
        for tag in [" X", " Y", " Z"] where base.hasSuffix(tag) { base.removeLast(2) }
        return base.isEmpty ? form.formLabel : base
    }

    /// A whole game, written down.
    ///
    /// Attribution comes from the turn model's own steps: each one already
    /// records who was acting and the health of everything at that moment, so
    /// the damage a move did is the difference between its step and the one
    /// before it. That is exact, including for a spread move that hits two and
    /// a move that was redirected — nothing here has to guess who was hit.
    struct Ledger: Sendable {
        var winner: Winner = .none
        var turns: Int = 0
        /// The four each side chose at preview, in the order the picker ranked
        /// them. Distinct from `brought`, which is who actually reached the
        /// field — a game can end before the back two are ever sent out.
        var pickedMine: [String] = []
        var pickedTheirs: [String] = []
        /// Where the picker ranked the four that was actually played, counting
        /// from one, and what it scored it. This is what makes the picker
        /// measurable: if its ranking means anything, rank one should win more
        /// often than rank eight across a few thousand games.
        var rankMine = 0
        var rankTheirs = 0
        var scoreMine = 0
        var scoreTheirs = 0
        /// How many fours it was choosing between.
        var choicesMine = 0
        var choicesTheirs = 0
        var broughtMine: [String] = []
        var broughtTheirs: [String] = []
        var mine: [String: Tally] = [:]
        var theirs: [String: Tally] = [:]
        /// Who hurt whom, with what, across the side line.
        ///
        /// The per-Pokémon tallies say a Pokémon took a lot of damage; they
        /// cannot say where it came from, and "took a lot of damage" is not
        /// something you can build a spread against. This can:
        /// "Mega Salamence's Double-Edge is a third of everything Whimsicott
        /// loses" is the sentence a stat spread is actually written from.
        ///
        /// Only blows that cross the side line are here. Recoil, a Life Orb and
        /// an Earthquake that catches your own partner are all real damage and
        /// none of them is a threat to build against.
        var blows: [Blow: Hit] = [:]
    }

    /// One attacker, one move, one victim.
    struct Blow: Hashable, Sendable {
        /// Whether the victim was on the first player's side.
        var onMine: Bool
        var victim: String
        var attacker: String
        var move: String
    }

    struct Hit: Sendable {
        var damage = 0
        var knockouts = 0
        var times = 0
    }

    /// The teams people actually registered, turned into something playable.
    ///
    /// The first version of this drew six Pokémon from the usage table and gave
    /// each one its three strongest attacks. It was fair — both engines faced
    /// the same draws — but it produced damage races, and a damage race is a
    /// position where thinking harder barely helps. That is a bad place to
    /// measure an engine from.
    ///
    /// The dataset already carries a hundred and twelve real lists, with the
    /// items, abilities and movesets their owners chose: Fake Out, U-turn,
    /// Tailwind, Choice Scarf, the support moves that make a turn a decision
    /// rather than an exchange. Those are the games worth learning from.
    ///
    /// Stat spreads are the one thing a registered list never publishes, so
    /// they have to be worked out here.
    ///
    /// `planner` is how. Without one every Pokémon on every published list got
    /// the same crude three lines — twenty into health, twenty-three into
    /// whichever attack was higher, twenty-three into Speed — which is not a
    /// spread anybody would register. Measuring a real team against a field
    /// built like that measures the *builds* rather than the teams, and
    /// flatters the side whose spreads are real.
    ///
    /// Given one, each Pokémon is built the way the app's own spread planner
    /// would build it: against the speed tiers and the attacks the field
    /// actually throws. It costs a second or two per shard at startup and it
    /// is the difference between a fair comparison and a rigged one.
    @MainActor
    static func teams(from dataset: Dataset, rules: Rulebook,
                      planner: SpreadPlanner? = nil) -> [Team] {
        // The same Pokémon turns up on a great many of these lists, and a plan
        // depends only on the form, the ability and the item — so planning
        // Incineroar forty times over is forty times the work for one answer.
        var planned: [String: SpreadPlanner.Plan] = [:]
        func spread(_ form: Form, _ ability: String, _ item: String) -> SpreadPlanner.Plan? {
            guard let planner else { return nil }
            let key = "\(form.id)|\(ability)|\(item)"
            if let known = planned[key] { return known }
            let built = planner.plan(for: form, ability: ability, item: item)
            planned[key] = built
            return built
        }
        return dataset.metaTeams.compactMap { entry -> Team? in
            var out = Team()
            out.format = entry.format.isEmpty ? "doubles" : entry.format
            out.name = entry.name
            out.slots = entry.members.compactMap { member -> TeamSlot? in
                guard let form = rules.forms.first(where: {
                    $0.formLabel == member.form || $0.name == member.form
                }) else { return nil }
                var slot = TeamSlot(formID: form.id)
                slot.item = member.item
                slot.ability = member.ability.isEmpty
                    ? (form.abilities.first?.name ?? "") : member.ability
                slot.moves = member.moves.compactMap { name in
                    rules.moves.values.first { $0.name == name }?.id
                }
                if slot.moves.isEmpty { return nil }
                let physical = form.attack >= form.spAttack
                if let built = spread(form, slot.ability, slot.item) {
                    slot.sp = built.sp
                    slot.alignmentName = member.nature ?? built.alignment.name
                } else {
                    var sp = Array(repeating: 0, count: 6)
                    sp[Stat.hp.rawValue] = 20
                    sp[(physical ? Stat.attack : Stat.spAttack).rawValue] = 23
                    sp[Stat.speed.rawValue] = 23
                    slot.sp = sp
                    slot.alignmentName = member.nature ?? (physical ? "Adamant" : "Modest")
                }
                return slot
            }
            // A list that lost most of itself to a form or move this dataset
            // does not carry is not a game worth playing.
            return out.slots.count >= 4 ? out : nil
        }
    }

    /// A configuration in one of the two chairs.
    struct Seat: Sendable {
        let engine: BattleEngine
        let branchedRolls: Int
        init(engine: BattleEngine, branchedRolls: Int) {
            self.engine = engine
            self.branchedRolls = branchedRolls
        }
    }

    /// Play until one side has nothing left, or the clock runs out.
    ///
    /// Each side is asked for its move on its *own* view of the board, which
    /// for the far side means the board turned round. Neither is handed the
    /// other's hidden bench: the two-board solve already keeps that honest, and
    /// an evaluation that leaked it would be measuring the wrong thing.
    static func play(
        mine: Team, theirs: Team, rules: Rulebook,
        forMine: Seat, forTheirs: Seat,
        limit: Int = 40, dice: RandomNumberGenerator) -> Outcome {
        let ledger = playLogged(mine: mine, theirs: theirs, rules: rules,
                                forMine: forMine, forTheirs: forTheirs,
                                limit: limit, dice: dice, logging: false)
        return Outcome(winner: ledger.winner, turns: ledger.turns)
    }

    /// The same game, with everything it did written down.
    ///
    /// `logging` turns on the turn model's narration for the *played* board
    /// only. That costs one set of board snapshots per real turn, which is
    /// nothing beside the search: the engine plays out thousands of boards per
    /// decision and none of those narrate.
    static func playLogged(
        mine: Team, theirs: Team, rules: Rulebook,
        forMine: Seat, forTheirs: Seat,
        limit: Int = 40, dice: RandomNumberGenerator,
        logging: Bool = true, bringSpread: Int = 1,
        weightedMine: Bool = true, weightedTheirs: Bool = true,
        stagesMine: Bool = true, stagesTheirs: Bool = true,
        forWinMine: Bool = true, forWinTheirs: Bool = true,
        floorMine: Double = Board.aliveFloor,
        floorTheirs: Double = Board.aliveFloor,
        /// What each side has been measured to do with each four, for the
        /// picker to lean on. Per side, so one can be given the benefit of its
        /// own history while the other picks on theory alone.
        measuredMine: [String: (wins: Int, games: Int)] = [:],
        measuredTheirs: [String: (wins: Int, games: Int)] = [:],
        /// A line to play rather than one to pick: the Pokémon to bring, by
        /// label, lead pair first. Nil leaves it to the picker.
        ///
        /// This is what makes a line testable. A team usually has a main way of
        /// being played and an alternate, and the question "which is better
        /// into this field" cannot be asked of a picker that keeps choosing for
        /// itself — pinning the line is the only way to hold everything else
        /// still and vary the one thing.
        pinnedMine: [String]? = nil,
        pinnedTheirs: [String]? = nil) -> Ledger {

        // The battle's own dice, not just the engine's play sampling. Handing
        // both halves of a mirrored pair the same stream is what lets the
        // mirroring cancel the luck as well as the draw.
        let wasDice = TurnModel.dice
        TurnModel.dice = dice
        defer { TurnModel.dice = wasDice }

        // Four of six, which is the format. Playing all six was giving every
        // team its whole roster every game — a different and much easier game
        // than the one being modelled, and useless for asking which four a
        // team should bring. Each side chooses against the other's six, the
        // same way the team-preview picker does.
        let field = Field(isDoubles: true)
        //
        // `bringSpread` is how many of the ranked fours are in play. At 1 the
        // picker's favourite is taken every time, which is right for measuring
        // a field but useless for asking which four is actually best: every
        // game of A against B would replay the identical eight Pokémon. Above
        // 1 the choice is drawn uniformly from the top N — uniformly rather
        // than by score, because the point is to give each candidate enough
        // games to be compared, not to play the favourite most often.
        struct Chosen {
            var team: Team
            var picked: [String] = []
            var rank = 0
            var score = 0
            var choices = 0
        }
        /// The line as asked for, in the order asked for. Nil if the team
        /// cannot field it — a label that is not on the team, or fewer than two
        /// that are, in which case the caller is told by getting the picker.
        func pinned(_ team: Team, to line: [String]) -> Chosen? {
            var slots: [TeamSlot] = []
            for label in line {
                guard let slot = team.slots.first(where: {
                    $0.battleForm(in: rules)?.formLabel == label
                        || $0.form(in: rules)?.formLabel == label
                }), !slots.contains(where: { $0.formID == slot.formID }) else { continue }
                slots.append(slot)
            }
            guard slots.count >= 2 else { return nil }
            var out = team
            out.slots = slots
            return Chosen(team: out, picked: slots.compactMap {
                $0.battleForm(in: rules)?.formLabel
            })
        }

        func fourOf(_ team: Team, against foe: Team,
                    measured: [String: (wins: Int, games: Int)]) -> Chosen {
            let whole = Chosen(team: team,
                               picked: team.slots.compactMap { $0.battleForm(in: rules)?.formLabel })
            guard team.slots.count > 4 else { return whole }
            let grid = Matchup(mine: team, theirs: foe, rules: rules, field: field)
            var picker = BringFour(matchup: grid, rules: rules, bring: 4)
            picker.measured = measured
            // Only where a caller has deliberately handed one in, which is the
            // held-out harness and nothing else.
            picker.leanOnMeasured = !measured.isEmpty
            let plans = picker.plans
            guard !plans.isEmpty else { return whole }
            // A spread of zero or less means every four is in play, which is
            // what measuring the ranking needs: the bottom of the list has to
            // be played too, or there is nothing to compare the top against.
            let reach = bringSpread <= 0 ? plans.count
                                         : Swift.max(1, Swift.min(bringSpread, plans.count))
            let at = reach == 1 ? 0 : Int.random(in: 0..<reach, using: &TurnModel.dice)
            let plan = plans[at]
            var out = team
            out.slots = plan.bring.compactMap { form in
                team.slots.first { $0.battleForm(in: rules)?.id == form.id }
            }
            guard out.slots.count >= 2 else { return whole }
            return Chosen(team: out, picked: plan.bring.map(\.formLabel),
                          rank: at + 1, score: plan.score, choices: plans.count)
        }
        let myFour = pinnedMine.flatMap { pinned(mine, to: $0) }
            ?? fourOf(mine, against: theirs, measured: measuredMine)
        let theirFour = pinnedTheirs.flatMap { pinned(theirs, to: $0) }
            ?? fourOf(theirs, against: mine, measured: measuredTheirs)
        var board = Board(mine: myFour.team, theirs: theirFour.team, rules: rules,
                          field: field, alreadyEvolved: false)
        board.activeCount = 2
        // Off the sixes, not the fours: what a Pokémon is worth is decided by
        // the team it is facing, and the other side's back two are part of that
        // whether they have been seen yet or not.
        // Settable per side, which is the whole experiment: one engine that
        // knows what its Pokémon are worth against this opponent, one that
        // prices them all the same, playing the same game with the same dice.
        board.myRoster = mine.slots.compactMap { $0.battleForm(in: rules)?.id }
        board.theirRoster = theirs.slots.compactMap { $0.battleForm(in: rules)?.id }
        if weightedMine {
            board.myBeats = Worth.table(for: mine, against: theirs, rules: rules, field: field)
        }
        if weightedTheirs {
            board.theirBeats = Worth.table(for: theirs, against: mine, rules: rules, field: field)
        }
        board.myCountsStages = stagesMine
        board.theirCountsStages = stagesTheirs
        board.myPlaysForWin = forWinMine
        board.theirPlaysForWin = forWinTheirs
        board.myAliveFloor = floorMine
        board.theirAliveFloor = floorTheirs
        board.refreshWorth()
        // Narration is what records the steps, and the steps are what make the
        // ledger exact. It is on for the played board only: the engine's own
        // search boards are separate and stay silent, which is where the cost
        // would actually be.
        board.narrating = logging
        board.sendOutLeads()

        var ledger = Ledger()
        ledger.pickedMine = myFour.picked
        ledger.pickedTheirs = theirFour.picked
        ledger.rankMine = myFour.rank; ledger.rankTheirs = theirFour.rank
        ledger.scoreMine = myFour.score; ledger.scoreTheirs = theirFour.score
        ledger.choicesMine = myFour.choices; ledger.choicesTheirs = theirFour.choices
        /// Who is standing where, so a form can be credited after it has been
        /// switched out. Read off the step rather than the live board.
        // A Mega and the Pokémon it evolved from are one entry. They were two,
        // which put Garchomp on the table with nothing beside it and Mega
        // Garchomp Z with all of its work.
        //
        // By name rather than by species: species would fold Alolan Ninetales
        // into Ninetales, and in this format those are two different Pokémon
        // with different types and different abilities.
        func label(_ id: String) -> String {
            guard let form = rules.forms.first(where: { $0.id == id }) else { return id }
            return SelfPlay.recordLabel(form)
        }
        /// The same Pokémon, uncollapsed.
        ///
        /// A threat record is the one place the Mega must stay separate: the
        /// whole point is to spend stat points against a particular attacker's
        /// numbers, and Mega Salamence's numbers are not Salamence's.
        func threatLabel(_ id: String) -> String {
            rules.forms.first(where: { $0.id == id })?.formLabel ?? id
        }
        func note(_ mineSide: Bool, _ form: String, _ change: (inout Tally) -> Void) {
            if mineSide { change(&ledger.mine[form, default: Tally()]) }
            else { change(&ledger.theirs[form, default: Tally()]) }
        }
        /// One blow across the side line, for the threat record.
        func strike(onMine: Bool, victim: String, attacker: String, move: String,
                    lost: Int, fatal: Bool) {
            guard logging, !move.isEmpty else { return }
            let key = Blow(onMine: onMine, victim: victim, attacker: attacker, move: move)
            ledger.blows[key, default: Hit()].damage += lost
            ledger.blows[key, default: Hit()].times += 1
            if fatal { ledger.blows[key, default: Hit()].knockouts += 1 }
        }

        /// Everything each side actually brought, in the order it appeared.
        func sawTheField() {
            for index in 0..<Swift.min(board.activeCount, board.mine.count) {
                let who = label(board.mine[index].build.form.id)
                if !ledger.broughtMine.contains(who) {
                    ledger.broughtMine.append(who)
                    note(true, who) { $0.brought = 1 }
                }
            }
            for index in 0..<Swift.min(board.activeCount, board.theirs.count) {
                let who = label(board.theirs[index].build.form.id)
                if !ledger.broughtTheirs.contains(who) {
                    ledger.broughtTheirs.append(who)
                    note(false, who) { $0.brought = 1 }
                }
            }
        }
        sawTheField()

        /// Read one turn's steps into the ledger.
        ///
        /// Each step carries who acted and everyone's health at that moment, so
        /// what a move did is the difference from the step before it. Steps
        /// with no actor — the residuals, the weather, a Leftovers — are damage
        /// nobody is credited with, which is right.
        func readSteps(_ played: Board) {
            guard logging else { return }
            var previous: Board.Step?
            for step in played.steps {
                defer { previous = step }
                guard let action = step.action else { continue }
                let actor = action.byMine
                    ? (step.myForms.indices.contains(action.slot)
                       ? label(step.myForms[action.slot]) : "")
                    : (step.theirForms.indices.contains(action.slot)
                       ? label(step.theirForms[action.slot]) : "")
                guard !actor.isEmpty else { continue }
                let actorForm = action.byMine
                    ? (step.myForms.indices.contains(action.slot)
                       ? threatLabel(step.myForms[action.slot]) : actor)
                    : (step.theirForms.indices.contains(action.slot)
                       ? threatLabel(step.theirForms[action.slot]) : actor)
                if !action.move.isEmpty {
                    note(actor.isEmpty ? false : action.byMine, actor) {
                        $0.moves[action.move, default: 0] += 1
                    }
                }
                guard let before = previous else { continue }
                var dealt = 0
                for slot in step.myHP.indices where before.myHP.indices.contains(slot) {
                    let lost = before.myHP[slot] - step.myHP[slot]
                    guard lost > 0, step.myForms.indices.contains(slot) else { continue }
                    let hurt = label(step.myForms[slot])
                    note(true, hurt) { $0.damageTaken += lost }
                    // A move never credits itself for what it cost its own
                    // user: recoil, a Life Orb, Belly Drum.
                    if !(action.byMine && slot == action.slot) {
                        if step.myHP[slot] == 0 { note(true, hurt) { $0.faints += 1 } }
                        // Nor for what it cost its own partner. An Earthquake
                        // that takes the ally down is a real event and it is
                        // not a knockout for the Pokémon that threw it —
                        // crediting it there would make the trade column say a
                        // Pokémon is carrying the team by killing it.
                        if !action.byMine {
                            dealt += lost
                            if step.myHP[slot] == 0 {
                                note(action.byMine, actor) { $0.knockouts += 1 }
                            }
                            strike(onMine: true, victim: hurt, attacker: actorForm,
                                   move: action.move, lost: lost,
                                   fatal: step.myHP[slot] == 0)
                        }
                    }
                }
                for slot in step.theirHP.indices where before.theirHP.indices.contains(slot) {
                    let lost = before.theirHP[slot] - step.theirHP[slot]
                    guard lost > 0, step.theirForms.indices.contains(slot) else { continue }
                    let hurt = label(step.theirForms[slot])
                    note(false, hurt) { $0.damageTaken += lost }
                    if !(!action.byMine && slot == action.slot) {
                        if step.theirHP[slot] == 0 { note(false, hurt) { $0.faints += 1 } }
                        if action.byMine {
                            dealt += lost
                            if step.theirHP[slot] == 0 {
                                note(action.byMine, actor) { $0.knockouts += 1 }
                            }
                            strike(onMine: false, victim: hurt, attacker: actorForm,
                                   move: action.move, lost: lost,
                                   fatal: step.theirHP[slot] == 0)
                        }
                    }
                }
                if dealt > 0 { note(action.byMine, actor) { $0.damageDealt += dealt } }
            }
        }

        /// Whoever is still standing when it is over.
        func countSurvivors() {
            // Only what was actually brought: the rest of the roster did not
            // survive the game, it was never in it.
            for fighter in board.mine.prefix(4) where !fighter.fainted {
                note(true, label(fighter.build.form.id)) { $0.survived = 1 }
            }
            for fighter in board.theirs.prefix(4) where !fighter.fainted {
                note(false, label(fighter.build.form.id)) { $0.survived = 1 }
            }
        }

        for turn in 1...limit {
            if board.isOut(mine: false) {
                ledger.winner = .mine; ledger.turns = turn; countSurvivors(); return ledger
            }
            if board.isOut(mine: true) {
                ledger.winner = .theirs; ledger.turns = turn; countSurvivors(); return ledger
            }

            TurnModel.branchedRolls = forMine.branchedRolls
            let ours = choose(forMine.engine, on: board)
            TurnModel.branchedRolls = forTheirs.branchedRolls
            let theirsPlay = choose(forTheirs.engine, on: board.flipped)

            TurnModel.branchedRolls = forMine.branchedRolls
            board = TurnModel.resolve(board, mine: ours, theirs: theirsPlay, rolling: true)
            readSteps(board)
            board.fillGaps()
            sawTheField()
        }
        // Nobody finished it. Whoever is further ahead on the board takes it,
        // because calling a clear lead a draw would hide a real difference.
        let standing = TurnModel.value(board)
        ledger.turns = limit
        if standing > 0.25 { ledger.winner = .mine }
        else if standing < -0.25 { ledger.winner = .theirs }
        countSurvivors()
        return ledger
    }

    /// One play, sampled from the equilibrium the engine found.
    ///
    /// Sampled rather than taken at its most likely, because the equilibrium is
    /// a mix for a reason: always playing its favourite makes an engine
    /// readable, and two engines that both do it play a stranger game than
    /// either would against a person.
    private static func choose(_ engine: BattleEngine, on board: Board) -> Play {
        let thought = engine.think(board)
        guard !thought.plays.isEmpty else { return Play(left: .pass, right: .pass) }
        let total = thought.mix.reduce(0, +)
        guard total > 0 else { return thought.plays[0] }
        var roll = Double.random(in: 0..<total, using: &TurnModel.dice)
        for (index, weight) in thought.mix.enumerated() {
            roll -= weight
            if roll <= 0, thought.plays.indices.contains(index) { return thought.plays[index] }
        }
        return thought.plays[0]
    }
}
