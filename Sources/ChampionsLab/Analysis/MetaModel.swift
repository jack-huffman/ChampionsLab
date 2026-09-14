//  MetaModel.swift
//  What the format is actually doing, and what turns it off.
//
//  Every other evaluation in this app runs on a neutral field, which is a
//  fiction. Rillaboom is on 37% of teams and runs Grassy Surge on 99% of them,
//  so roughly a third of your games start with Grassy Terrain already up — and
//  Grassy Terrain halves Earthquake. A Garchomp scored against an empty field
//  looks better than the one you will actually be playing.
//
//  So the field is modelled from measured usage: who sets what, how often, and
//  what that does to the moves people are actually clicking. Picks are then
//  scored across the field states the format produces rather than against
//  nothing, and the consequences are stated in the open so you can disagree
//  with them.
//
//  The second half is counterplay. A format is not beaten by out-statting it;
//  it is beaten by turning off the thing it wants to do — overriding the
//  terrain, Taunting the Trick Room, Wide Guarding the spread. Those answers
//  are detected from real learnsets and abilities, not assumed.

import Foundation

@MainActor
struct MetaModel {
    let store: Store
    var format = "doubles"

    /// A terrain setter on the opposing team still has to be one of the four
    /// they bring. Most are, but not all — this is the assumption the field
    /// probabilities rest on, stated rather than buried.
    static let broughtRate = 0.8

    // MARK: - The field the format produces

    struct FieldPressure: Identifiable {
        let terrain: Terrain
        let weather: Weather
        /// Chance this is up in a given game.
        let probability: Double
        let setters: [Share]
        let consequences: [String]

        var id: String { label }
        var label: String {
            terrain != .none ? "\(terrain.rawValue) Terrain" : weather.rawValue
        }
        var field: Field {
            Field(weather: weather, terrain: terrain, isDoubles: true)
        }
    }

    struct Share: Identifiable, Hashable {
        let name: String
        let value: Double
        var id: String { name }
    }

    /// One measured tracked Pokémon, with the share of teams carrying it.
    private struct Tracked {
        let entry: UsageEntry
        let form: Form
        /// Share of teams carrying it, 0…1.
        let weight: Double
    }

    private var tracked: [Tracked] {
        store.data.usage
            .filter { $0.formats.contains(format) && !$0.isProjected }
            .compactMap { entry in
                guard let form = store.form(named: entry.name) else { return nil }
                return Tracked(entry: entry, form: form, weight: entry.usage / 100)
            }
    }

    /// Share of sets running a named ability, measured where possible.
    private func abilityShare(_ member: Tracked, _ ability: String) -> Double {
        if let measured = member.entry.abilityUsage?.first(where: { $0.name == ability }) {
            return measured.percent / 100
        }
        // No measured split: only credit it when the form has nothing else.
        guard member.form.abilities.contains(where: { $0.name == ability }) else { return 0 }
        return member.form.abilities.count == 1 ? 1 : 0
    }

    /// Share of sets running a named move, measured where possible.
    private func moveShare(_ member: Tracked, _ move: String) -> Double {
        if let measured = member.entry.moveUsage?.first(where: { $0.name == move }) {
            return measured.percent / 100
        }
        return member.entry.keyMoves.contains(move) ? 0.5 : 0
    }

    /// Share of the whole field running something, and who runs it.
    private func fieldShare(_ test: (Tracked) -> Double) -> (Double, [Share]) {
        var carriers: [Share] = []
        var none = 1.0
        for member in tracked {
            let share = test(member) * member.weight
            guard share > 0.005 else { continue }
            carriers.append(Share(name: member.form.formLabel, value: share))
            none *= 1 - min(1, share)
        }
        return (1 - none, carriers.sorted { $0.value > $1.value })
    }

    /// Terrains and weathers the format puts up, most likely first.
    var fieldPressures: [FieldPressure] {
        var out: [FieldPressure] = []

        let terrains: [(Terrain, String, String)] = [
            (.grassy, "Grassy Surge", "Grassy Terrain"),
            (.psychic, "Psychic Surge", "Psychic Terrain"),
            (.electric, "Electric Surge", "Electric Terrain"),
            (.misty, "Misty Surge", "Misty Terrain"),
        ]
        for (terrain, ability, move) in terrains {
            let (probability, setters) = fieldShare { member in
                max(abilityShare(member, ability) * MetaModel.broughtRate,
                    moveShare(member, move) * MetaModel.broughtRate)
            }
            guard probability > 0.02 else { continue }
            out.append(FieldPressure(terrain: terrain, weather: .none,
                                     probability: probability, setters: setters,
                                     consequences: consequences(of: terrain)))
        }

        let weathers: [(Weather, [String], String)] = [
            (.sun, ["Drought", "Orichalcum Pulse"], "Sunny Day"),
            (.rain, ["Drizzle"], "Rain Dance"),
            (.sand, ["Sand Stream", "Sand Spit"], "Sandstorm"),
            (.snow, ["Snow Warning"], "Snowscape"),
        ]
        for (weather, abilities, move) in weathers {
            let (probability, setters) = fieldShare { member in
                let fromAbility = abilities.map { abilityShare(member, $0) }.max() ?? 0
                return max(fromAbility, moveShare(member, move)) * MetaModel.broughtRate
            }
            guard probability > 0.02 else { continue }
            out.append(FieldPressure(terrain: .none, weather: weather,
                                     probability: probability, setters: setters,
                                     consequences: consequences(of: weather)))
        }
        return out.sorted { $0.probability > $1.probability }
    }

    /// What the condition does, with the part of it that matters for this
    /// format quantified rather than described.
    private func consequences(of terrain: Terrain) -> [String] {
        switch terrain {
        case .grassy:
            let (quake, carriers) = fieldShare { moveShare($0, "Earthquake") }
            var out = ["Earthquake, Bulldoze and Magnitude deal half damage to grounded targets."]
            if quake > 0.02 {
                out.append(String(format: "%.0f%% of the field runs Earthquake (%@) — all of it halved while this is up.",
                                  quake * 100,
                                  carriers.prefix(3).map(\.name).joined(separator: ", ")))
            }
            out.append("Grassy Glide gains +1 priority for the side under it, and grounded Pokémon heal 1/16 each turn.")
            return out
        case .psychic:
            let (priority, carriers) = fieldShare { member in
                ["Fake Out", "Sucker Punch", "Aqua Jet", "Grassy Glide", "Extreme Speed",
                 "Ice Shard", "Bullet Punch", "Shadow Sneak", "Quick Attack", "Mach Punch"]
                    .map { moveShare(member, $0) }.reduce(0, +)
            }
            var out = ["Blocks every priority move against grounded targets."]
            if priority > 0.05 {
                out.append(String(format: "That is %.0f%% of the field's priority turned off, including %@.",
                                  min(1, priority) * 100,
                                  carriers.prefix(3).map(\.name).joined(separator: ", ")))
            }
            out.append("Psychic moves gain 30% for grounded users.")
            return out
        case .electric:
            return ["Grounded Pokémon cannot be put to sleep.",
                    "Electric moves gain 30% for grounded users, and Rising Voltage doubles."]
        case .misty:
            return ["Dragon moves deal half damage to grounded targets.",
                    "Grounded Pokémon cannot be statused — no burn, no paralysis, no sleep."]
        case .none:
            return []
        }
    }

    private func consequences(of weather: Weather) -> [String] {
        switch weather {
        case .sun:
            return ["Fire moves gain 50%, Water moves lose 50%.",
                    "Solar Beam fires the turn it is used, and Chlorophyll doubles Speed."]
        case .rain:
            return ["Water moves gain 50%, Fire moves lose 50%.",
                    "Thunder and Hurricane cannot miss, and Swift Swim doubles Speed."]
        case .sand:
            return ["Chip damage each turn on everything that is not Rock, Ground or Steel.",
                    "Rock types gain 50% Sp. Def."]
        case .snow:
            return ["Ice types gain 50% Defense — it is a defensive condition, not an offensive one.",
                    "Blizzard cannot miss."]
        case .none:
            return []
        }
    }

    /// The field states worth evaluating a pick in, with weights summing to 1.
    ///
    /// Capped at the two likeliest conditions plus neutral: past that the
    /// weights are too small to move a ranking and the cost is real.
    var fieldStates: [(field: Field, weight: Double, label: String)] {
        let doubles = format == "doubles"
        let top = fieldPressures.prefix(2)
        var states: [(Field, Double, String)] = []
        var claimed = 0.0
        for pressure in top {
            var field = pressure.field
            field.isDoubles = doubles
            states.append((field, pressure.probability, pressure.label))
            claimed += pressure.probability
        }
        let neutral = max(0.1, 1 - claimed)
        states.append((Field(isDoubles: doubles), neutral, "No terrain or weather"))
        let total = states.reduce(0.0) { $0 + $1.1 }
        return states.map { ($0.0, $0.1 / total, $0.2) }
    }

    // MARK: - Tactics the format runs

    struct TacticPressure: Identifiable {
        let name: String
        /// Share of teams carrying it, 0…1.
        let share: Double
        let carriers: [Share]
        let effect: String
        /// What turns it off, in plain terms.
        let answers: [String]
        /// Abilities, moves and items that provide an answer.
        let tools: Tools
        var id: String { name }
    }

    struct Tools {
        var moves: Set<String> = []
        var abilities: Set<String> = []
        var items: Set<String> = []
        /// Any spread move counts — the answer to redirection is not a
        /// particular move, it is hitting both of them at once.
        var anySpreadMove = false
    }

    var tactics: [TacticPressure] {
        var out: [TacticPressure] = []

        func add(_ name: String, effect: String, answers: [String], tools: Tools,
                 _ test: @escaping (Tracked) -> Double) {
            let (share, carriers) = fieldShare(test)
            guard share > 0.03 else { return }
            out.append(TacticPressure(name: name, share: share, carriers: carriers,
                                      effect: effect, answers: answers, tools: tools))
        }

        add("Tailwind",
            effect: "Doubles the user's side's Speed for four turns, which decides who moves first for most of a game.",
            answers: ["Set your own Tailwind and race them, or Trick Room to invert it entirely.",
                      "Icy Wind and Electroweb drop their Speed through the boost."],
            tools: Tools(moves: ["Tailwind", "Trick Room", "Icy Wind", "Electroweb"])) {
            self.moveShare($0, "Tailwind")
        }

        add("Trick Room",
            effect: "Inverts the Speed order for five turns, so their slowest attacker moves first.",
            answers: ["Taunt the setter before it goes up — Prankster Taunt is the cleanest answer.",
                      "Encore locks it out of resetting; Imprison stops it outright if you carry Trick Room too."],
            tools: Tools(moves: ["Taunt", "Encore", "Imprison", "Trick Room"],
                         abilities: ["Prankster"])) {
            self.moveShare($0, "Trick Room")
        }

        add("Fake Out",
            effect: "A free flinch on turn one, which is a free turn for whatever is beside it.",
            answers: ["Covert Cloak ignores the flinch entirely.",
                      "Your own Fake Out trades it off, and Inner Focus or Own Tempo cannot be made to flinch."],
            tools: Tools(moves: ["Fake Out"],
                         abilities: ["Inner Focus", "Own Tempo"],
                         items: ["Covert Cloak"])) {
            self.moveShare($0, "Fake Out")
        }

        add("Redirection",
            effect: "Follow Me and Rage Powder pull your single-target attacks away from what you meant to hit.",
            answers: ["Spread moves hit both regardless of redirection.",
                      "Safety Goggles ignores Rage Powder specifically."],
            tools: Tools(items: ["Safety Goggles"], anySpreadMove: true)) {
            max(self.moveShare($0, "Follow Me"), self.moveShare($0, "Rage Powder"))
        }

        add("Intimidate",
            effect: "Drops your physical attackers a stage on every switch-in, compounding across a game.",
            answers: ["Defiant and Competitive turn it into a boost.",
                      "Clear Body, White Smoke and Clear Amulet refuse the drop."],
            tools: Tools(abilities: ["Defiant", "Competitive", "Clear Body", "White Smoke",
                                     "Guard Dog", "Inner Focus", "Own Tempo", "Oblivious"],
                         items: ["Clear Amulet"])) {
            self.abilityShare($0, "Intimidate")
        }

        add("Priority",
            effect: "Sucker Punch, Grassy Glide, Aqua Jet and Extreme Speed close games before Speed matters.",
            answers: ["Psychic Terrain blocks all of it against your grounded side.",
                      "Armor Tail and Queenly Majesty block it outright."],
            tools: Tools(moves: ["Psychic Terrain"],
                         abilities: ["Psychic Surge", "Armor Tail", "Queenly Majesty"])) { member in
            ["Sucker Punch", "Grassy Glide", "Aqua Jet", "Extreme Speed", "Ice Shard",
             "Bullet Punch", "Shadow Sneak", "Quick Attack", "Mach Punch", "Fake Out"]
                .map { self.moveShare(member, $0) }.reduce(0, +)
        }

        add("Spread moves",
            effect: "Earthquake, Rock Slide, Make It Rain and Hyper Voice hit both of yours for 75% each.",
            answers: ["Wide Guard blocks the whole turn for your side.",
                      "A Flying type or Levitate simply ignores Earthquake."],
            tools: Tools(moves: ["Wide Guard"], abilities: ["Levitate", "Telepathy"])) { member in
            ["Earthquake", "Rock Slide", "Make It Rain", "Hyper Voice", "Heat Wave",
             "Blizzard", "Muddy Water", "Dazzling Gleam", "Snarl", "Icy Wind"]
                .map { self.moveShare(member, $0) }.reduce(0, +)
        }

        return out.sorted { $0.share > $1.share }
    }

    // MARK: - Opponents drawn from the ladder, not hand-written

    /// Teams the format would actually put in front of you.
    ///
    /// A third of the team score used to rest on seven archetypes I wrote by
    /// hand, while measured teammate data sat unused for nineteen of the twenty
    /// tracked Pokémon. These are built from that instead: take a Pokémon with
    /// real usage, add the partners it is actually seen with, and give each the
    /// set the ladder runs. They are opinions about nothing — just what the
    /// table says people bring.
    func ladderTeams(limit: Int = 8) -> [(team: Team, weight: Double)] {
        let tracked = self.tracked
        guard tracked.count >= 4 else { return [] }
        let byName = Dictionary(tracked.map { ($0.entry.name, $0) },
                                uniquingKeysWith: { a, _ in a })

        var out: [(Team, Double)] = []
        var seenRosters: Set<String> = []
        for seed in tracked.sorted(by: { $0.weight > $1.weight }) {
            var picked: [Tracked] = [seed]
            var usedDex: Set<Int> = [seed.form.dex]

            // Its measured partners first, then the rest of the field by usage.
            let partners = (seed.entry.teammates ?? []).compactMap { byName[$0] }
                + tracked.sorted { $0.weight > $1.weight }
            for candidate in partners where picked.count < 6 {
                guard usedDex.insert(candidate.form.dex).inserted else { continue }
                picked.append(candidate)
            }
            guard picked.count == 6 else { continue }

            let key = picked.map(\.form.id).sorted().joined(separator: "|")
            guard seenRosters.insert(key).inserted else { continue }

            var team = Team(name: "\(seed.entry.name) core", format: format)
            var usedItems: Set<String> = []
            team.slots = picked.map { member in
                var slot = TeamSlot(formID: member.form.id)
                // The ability and item the ladder actually runs.
                slot.ability = member.entry.abilityUsage?.first?.name
                    ?? member.form.abilities.first?.name ?? ""
                let item = (member.entry.itemUsage ?? [])
                    .map(\.name).first { !usedItems.contains($0) }
                    ?? member.entry.commonItems.first { !usedItems.contains($0) }
                    ?? ""
                slot.item = item
                if !item.isEmpty { usedItems.insert(item) }
                slot.moves = (member.entry.moveUsage ?? []).prefix(4).compactMap { share in
                    member.form.moves.first { store.move($0)?.name == share.name }
                }
                if slot.moves.isEmpty {
                    slot.moves = member.entry.keyMoves.prefix(4).compactMap { name in
                        member.form.moves.first { store.move($0)?.name == name }
                    }
                }
                // A representative spread: into its better attacking stat and
                // Speed, which is what most measured sets look like.
                let physical = member.form.attack >= member.form.spAttack
                var sp = Array(repeating: 0, count: 6)
                sp[physical ? Stat.attack.rawValue : Stat.spAttack.rawValue] = 32
                sp[Stat.speed.rawValue] = 32
                sp[Stat.hp.rawValue] = 2
                slot.sp = sp
                slot.alignmentName = physical ? "Adamant" : "Modest"
                return slot
            }
            team.locked = true
            out.append((team, seed.weight))
            if out.count >= limit { break }
        }
        return out
    }

    /// Share of the tracked field carrying an attacking move of this type.
    func attackingShare(of type: PokeType) -> Double {
        let members = tracked
        guard !members.isEmpty else { return 0 }
        var none = 1.0
        for member in members {
            let carries = (member.entry.moveUsage ?? []).contains { share in
                guard let move = store.data.moves.values.first(where: { $0.name == share.name })
                else { return false }
                return move.isDamaging && PokeType(loose: move.type) == type
            } || member.entry.keyMoves.contains { name in
                guard let move = store.data.moves.values.first(where: { $0.name == name })
                else { return false }
                return move.isDamaging && PokeType(loose: move.type) == type
            }
            if carries { none *= 1 - member.weight }
        }
        return 1 - none
    }

    // MARK: - What winning teams are actually made of

    /// A job a team needs done, and the different ways of doing it.
    ///
    /// This replaces a five-item checklist I wrote from memory. That checklist
    /// scored a team that beats twelve of sixteen tournament teams at 40%,
    /// because it counted categories rather than answers and had no notion that
    /// Trick Room and Tailwind do the same job, or that Armor Tail buys the same
    /// turn redirection does. Groups are substitutable, and each one's weight is
    /// how often teams that actually won carry it — measured, not asserted.
    struct RoleGroup: Identifiable {
        let name: String
        let moves: Set<String>
        /// The moves that define the job rather than merely touching it.
        ///
        /// Bulldoze lowers Speed and Rain Dance sets rain, so on a bare
        /// learnset test Kingambit qualifies as a weather setter and Rillaboom
        /// as speed control. Nobody runs either. Suggestions come from here;
        /// the wider set is still what counts a team as covered, because a team
        /// that happens to carry Bulldoze does have the effect available.
        let core: Set<String>
        let abilities: Set<String>
        /// Satisfied by any spread move, any priority attack, and so on.
        let anySpread: Bool
        let anyPriority: Bool
        let anySetup: Bool
        var id: String { name }

        init(_ name: String, moves: Set<String> = [], core: Set<String>? = nil,
             abilities: Set<String> = [], anySpread: Bool = false,
             anyPriority: Bool = false, anySetup: Bool = false) {
            self.name = name; self.moves = moves; self.core = core ?? moves
            self.abilities = abilities
            self.anySpread = anySpread; self.anyPriority = anyPriority; self.anySetup = anySetup
        }
    }

    static let roleGroups: [RoleGroup] = [
        RoleGroup("Speed control",
                  moves: ["Tailwind", "Trick Room", "Icy Wind", "Electroweb",
                          "Thunder Wave", "Glare", "Nuzzle", "Rock Tomb", "Bulldoze",
                          "Quash", "After You"],
                  core: ["Tailwind", "Trick Room", "Icy Wind", "Electroweb",
                         "Thunder Wave", "Glare", "Nuzzle"],
                  abilities: ["Swift Swim", "Chlorophyll", "Sand Rush", "Slush Rush",
                              "Unburden", "Prankster"]),
        RoleGroup("Buying a turn",
                  moves: ["Fake Out", "Follow Me", "Rage Powder", "Taunt", "Encore",
                          "Parting Shot", "Spore", "Hypnosis", "Revival Blessing"],
                  core: ["Fake Out", "Follow Me", "Rage Powder", "Encore",
                         "Parting Shot", "Spore", "Revival Blessing"],
                  abilities: ["Armor Tail", "Queenly Majesty", "Intimidate"]),
        RoleGroup("Blunting their damage",
                  moves: ["Will-O-Wisp", "Snarl", "Wide Guard", "Reflect",
                          "Light Screen", "Aurora Veil", "Struggle Bug", "Charm"],
                  abilities: ["Intimidate", "Heatproof", "Thick Fat", "Multiscale",
                              "Aura Guard", "Ice Scales", "Furry Coat"]),
        RoleGroup("Hitting both", anySpread: true),
        RoleGroup("Closing the game", anyPriority: true, anySetup: true),
        RoleGroup("Owning the field",
                  moves: ["Grassy Terrain", "Psychic Terrain", "Electric Terrain",
                          "Misty Terrain", "Sunny Day", "Rain Dance", "Sandstorm",
                          "Snowscape", "Steel Roller", "Defog"],
                  // Half the roster learns Sunny Day; that is not what makes a
                  // weather team. An ability is what makes one.
                  core: ["Grassy Terrain", "Psychic Terrain", "Electric Terrain",
                         "Misty Terrain", "Steel Roller"],
                  abilities: ["Grassy Surge", "Psychic Surge", "Electric Surge",
                              "Misty Surge", "Drizzle", "Drought", "Sand Stream",
                              "Snow Warning"]),
        RoleGroup("Staying alive",
                  moves: ["Recover", "Life Dew", "Strength Sap", "Roost", "Wish",
                          "Rest", "Leech Life", "Drain Punch", "Giga Drain",
                          "Matcha Gotcha", "Revival Blessing"],
                  core: ["Recover", "Life Dew", "Strength Sap", "Roost", "Wish",
                         "Matcha Gotcha", "Revival Blessing"],
                  abilities: ["Regenerator", "Poison Heal", "Hospitality"]),
    ]

    /// Whether a team does a job, and who does it.
    func fills(_ group: RoleGroup, in team: Team) -> [Form] {
        team.slots.compactMap { slot -> Form? in
            guard let form = slot.battleForm(in: store),
                  let combatant = slot.combatant(in: store) else { return nil }
            let moves = slot.moves.compactMap { store.move($0) }
            if moves.contains(where: { group.moves.contains($0.name) }) { return form }
            if group.abilities.contains(combatant.ability) { return form }
            if group.anySpread, moves.contains(where: \.isSpread) { return form }
            if group.anyPriority,
               moves.contains(where: { $0.priority > 0 && $0.isDamaging && $0.power >= 40 }) {
                return form
            }
            if group.anySetup,
               moves.contains(where: { !$0.selfBoosts.isEmpty }) { return form }
            return nil
        }
    }

    /// How often teams that actually won a game carry each job, weighted by how
    /// many games they won. This is the only outside evidence available about
    /// what a team needs, so it is what the role weights come from.
    func winningStructure() -> [(group: RoleGroup, share: Double)] {
        let winners = store.data.metaTeams.filter {
            $0.format == format && ($0.winRate ?? 0) > 0 && $0.gamesPlayed > 0
        }
        guard winners.count >= 8 else {
            // Not enough evidence: treat every job as equally expected.
            return MetaModel.roleGroups.map { ($0, 1.0) }
        }
        // Each list is built once, not once per job.
        //
        // This rebuilt every winning team from its paste inside the loop over
        // role groups, so answering ten questions constructed a thousand teams.
        // It cost 340ms of unbroken main thread the first time anything asked,
        // which was the largest single stall left in a build. Going through the
        // store's cache also means the pool the evaluation already warmed is
        // reused rather than rebuilt.
        let built = winners.map {
            (weight: Double($0.gamesPlayed) * ($0.winRate ?? 0), team: store.opponentTeam($0))
        }
        let total = built.reduce(0) { $0 + $1.weight }
        return MetaModel.roleGroups.map { group in
            let carried = built.reduce(0.0) { running, entry in
                fills(group, in: entry.team).isEmpty ? running : running + entry.weight
            }
            return (group, total > 0 ? carried / total : 0)
        }
    }

    // MARK: - Does a team answer any of it?

    struct Coverage: Identifiable {
        let pressure: String
        let share: Double
        /// Members that provide an answer, and what the answer is.
        let providers: [(form: Form, how: String)]
        let advice: String
        /// Members that own the answer but have not selected it — a swap away.
        let couldAnswer: [(form: Form, how: String)]
        var id: String { pressure }
        var isAnswered: Bool { !providers.isEmpty }
    }

    /// Who on this team turns each of the format's tactics off.
    func coverage(of team: Team) -> [Coverage] {
        // Resolved once per member rather than once per tactic. What a slot has
        // selected is kept apart from what it merely could learn: crediting a
        // team with a Taunt nobody picked is worse than reporting the gap.
        struct Member {
            let slot: TeamSlot
            let form: Form
            let running: Set<String>
            let learnable: Set<String>
            let abilities: Set<String>
            let ability: String
            let spreads: Bool
        }
        let members: [Member] = team.slots.compactMap { slot in
            guard let form = slot.battleForm(in: store),
                  let combatant = slot.combatant(in: store) else { return nil }
            let running = Set(slot.moves.compactMap { store.move($0)?.name })
            return Member(slot: slot, form: form, running: running,
                          learnable: Set(form.moves.compactMap { store.move($0)?.name }),
                          abilities: Set(form.abilities.map(\.name)),
                          // The ability it fights with: a Mega's replaces the
                          // base form's, which is what the slot stores.
                          ability: combatant.ability,
                          spreads: slot.moves.contains { store.move($0)?.isSpread == true })
        }
        return tactics.map { tactic in
            var providers: [(Form, String)] = []
            for member in members {
                var confirmed: [String] = []
                var possible: [String] = []
                for move in tactic.tools.moves {
                    if member.running.contains(move) { confirmed.append(move) }
                    else if member.learnable.contains(move) { possible.append(move) }
                }
                for ability in tactic.tools.abilities where member.abilities.contains(ability) {
                    if member.ability == ability { confirmed.append(ability) }
                    else { possible.append(ability) }
                }
                for item in tactic.tools.items where member.slot.item == item {
                    confirmed.append(item)
                }
                if tactic.tools.anySpreadMove, member.spreads {
                    confirmed.append("a spread move")
                }
                if !confirmed.isEmpty {
                    providers.append((member.form, confirmed.prefix(2).joined(separator: ", ")))
                } else if !possible.isEmpty {
                    providers.append((member.form,
                                      "could run " + possible.prefix(2).joined(separator: " or ")))
                }
            }
            // An answer nobody has selected is not an answer yet.
            providers.sort { !$0.1.hasPrefix("could run") && $1.1.hasPrefix("could run") }
            let selected = providers.filter { !$0.1.hasPrefix("could run") }
            let advice = selected.isEmpty
                ? (providers.isEmpty
                   ? "Nothing on this team answers it. " + (tactic.answers.first ?? "")
                   : "Nobody has the answer selected. " + (tactic.answers.first ?? ""))
                : tactic.answers.first ?? ""
            return Coverage(pressure: tactic.name, share: tactic.share,
                            providers: selected, advice: advice,
                            couldAnswer: providers.filter { $0.1.hasPrefix("could run") })
        }
    }

    struct FieldAnswer {
        let pressure: FieldPressure
        let answer: String?
        /// True when the answer is an ability it has or a move it has selected,
        /// rather than something it merely could run.
        let isSelected: Bool
        /// Set when the proposed override would damage this team's own game
        /// plan more than it costs the opponent.
        let warning: String?
    }

    /// The team's own moves a terrain would turn off or halve.
    ///
    /// Overriding Grassy Terrain with Misty Terrain looks like an answer and
    /// scores like one, right up until you notice Misty halves Dragon moves and
    /// your win condition is a Dragon-type Glaive Rush. Psychic Terrain has the
    /// same problem for a side built on priority: it blocks yours too.
    func selfDefeating(_ terrain: Terrain, for team: Team) -> [String] {
        var hurt: [String] = []
        for slot in team.slots {
            guard let form = slot.battleForm(in: store) else { continue }
            for id in slot.moves {
                guard let move = store.move(id), move.isDamaging else { continue }
                switch terrain {
                case .misty where move.type == "Dragon":
                    hurt.append("\(form.formLabel)'s \(move.name)")
                case .grassy where ["earthquake", "bulldoze", "magnitude"].contains(move.id):
                    hurt.append("\(form.formLabel)'s \(move.name)")
                case .psychic where move.priority > 0:
                    hurt.append("\(form.formLabel)'s \(move.name)")
                default:
                    break
                }
            }
        }
        return hurt
    }

    /// Whether this team can change the field the format puts up, and how.
    func fieldControl(of team: Team) -> [FieldAnswer] {
        // Mega Evolution replaces the ability, and the slot stores the base
        // form's. Reading slot.ability directly reported Mega Charizard Y's
        // Drought as something it "could run" rather than something it has.
        let members: [(Form, Set<String>, Set<String>, String)] = team.slots.compactMap { slot in
            guard let form = slot.battleForm(in: store),
                  let combatant = slot.combatant(in: store) else { return nil }
            return (form,
                    Set(slot.moves.compactMap { store.move($0)?.name }),
                    Set(form.moves.compactMap { store.move($0)?.name }),
                    combatant.ability)
        }
        return fieldPressures.map { pressure in
            var confirmed: [String] = []
            var possible: [String] = []
            var warning: String?
            for (form, running, learnset, chosen) in members {
                let abilities = Set(form.abilities.map(\.name))
                // Any other terrain displaces theirs; any other weather does too.
                for (terrain, ability, move) in [(Terrain.grassy, "Grassy Surge", "Grassy Terrain"),
                                                 (.psychic, "Psychic Surge", "Psychic Terrain"),
                                                 (.electric, "Electric Surge", "Electric Terrain"),
                                                 (.misty, "Misty Surge", "Misty Terrain")]
                where pressure.terrain != .none && terrain != pressure.terrain {
                    // An override that halves your own attacks is not a fix —
                    // but only worth mentioning when this team could set it.
                    let canSet = abilities.contains(ability) || learnset.contains(move)
                    let cost = canSet ? selfDefeating(terrain, for: team) : []
                    guard cost.isEmpty else {
                        if warning == nil {
                            warning = "\(form.formLabel) could set \(terrain.rawValue) Terrain, but it would turn off "
                                + cost.prefix(2).joined(separator: " and ")
                        }
                        continue
                    }
                    if abilities.contains(ability) {
                        let line = "\(form.formLabel) overrides it with \(ability)"
                        if chosen == ability { confirmed.append(line) } else { possible.append(line) }
                    } else if running.contains(move) {
                        confirmed.append("\(form.formLabel) clicks \(move)")
                    } else if learnset.contains(move) {
                        possible.append("\(form.formLabel) could run \(move)")
                    }
                }
                for (weather, ability, move) in [(Weather.sun, "Drought", "Sunny Day"),
                                                 (.rain, "Drizzle", "Rain Dance"),
                                                 (.sand, "Sand Stream", "Sandstorm"),
                                                 (.snow, "Snow Warning", "Snowscape")]
                where pressure.weather != .none && weather != pressure.weather {
                    if abilities.contains(ability) {
                        let line = "\(form.formLabel) overrides it with \(ability)"
                        if chosen == ability { confirmed.append(line) } else { possible.append(line) }
                    } else if running.contains(move) {
                        confirmed.append("\(form.formLabel) clicks \(move)")
                    } else if learnset.contains(move) {
                        possible.append("\(form.formLabel) could run \(move)")
                    }
                }
                if pressure.terrain != .none {
                    if running.contains("Steel Roller") {
                        confirmed.append("\(form.formLabel) removes it with Steel Roller")
                    } else if learnset.contains("Steel Roller") {
                        possible.append("\(form.formLabel) could run Steel Roller")
                    }
                }
            }
            return FieldAnswer(pressure: pressure,
                               answer: confirmed.first ?? possible.first,
                               isSelected: !confirmed.isEmpty,
                               warning: (confirmed.isEmpty && possible.isEmpty) ? warning : nil)
        }
    }
}
