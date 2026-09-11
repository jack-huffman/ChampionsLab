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
                      "Inner Focus and Own Tempo cannot be made to flinch."],
            tools: Tools(abilities: ["Inner Focus", "Own Tempo"], items: ["Covert Cloak"])) {
            self.moveShare($0, "Fake Out")
        }

        add("Redirection",
            effect: "Follow Me and Rage Powder pull your single-target attacks away from what you meant to hit.",
            answers: ["Spread moves hit both regardless of redirection.",
                      "Safety Goggles ignores Rage Powder specifically."],
            tools: Tools(items: ["Safety Goggles"])) {
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
            tools: Tools(moves: ["Wide Guard"], abilities: ["Levitate"])) { member in
            ["Earthquake", "Rock Slide", "Make It Rain", "Hyper Voice", "Heat Wave",
             "Blizzard", "Muddy Water", "Dazzling Gleam", "Snarl", "Icy Wind"]
                .map { self.moveShare(member, $0) }.reduce(0, +)
        }

        return out.sorted { $0.share > $1.share }
    }

    // MARK: - Does a team answer any of it?

    struct Coverage: Identifiable {
        let pressure: String
        let share: Double
        /// Members that provide an answer, and what the answer is.
        let providers: [(form: Form, how: String)]
        let advice: String
        var id: String { pressure }
        var isAnswered: Bool { !providers.isEmpty }
    }

    /// Who on this team turns each of the format's tactics off.
    func coverage(of team: Team) -> [Coverage] {
        // Learnsets resolved once per member rather than once per tactic.
        let members: [(slot: TeamSlot, form: Form, moves: Set<String>, abilities: Set<String>)] =
            team.slots.compactMap { slot in
                guard let form = slot.battleForm(in: store) else { return nil }
                return (slot, form,
                        Set(form.moves.compactMap { store.move($0)?.name }),
                        Set(form.abilities.map(\.name)))
            }
        return tactics.map { tactic in
            var providers: [(Form, String)] = []
            for (slot, form, learnset, abilities) in members {
                var how: [String] = []
                for move in tactic.tools.moves where learnset.contains(move) {
                    how.append(move)
                }
                for ability in tactic.tools.abilities where abilities.contains(ability) {
                    how.append(ability + (slot.ability == ability ? "" : " (not selected)"))
                }
                for item in tactic.tools.items where slot.item == item {
                    how.append(item)
                }
                if !how.isEmpty { providers.append((form, how.prefix(2).joined(separator: ", "))) }
            }
            let advice = providers.isEmpty
                ? "Nothing on this team answers it. " + (tactic.answers.first ?? "")
                : tactic.answers.first ?? ""
            return Coverage(pressure: tactic.name, share: tactic.share,
                            providers: providers, advice: advice)
        }
    }

    /// Whether this team can change the field the format puts up, and how.
    func fieldControl(of team: Team) -> [(pressure: FieldPressure, answer: String?)] {
        let members = team.slots.compactMap { $0.battleForm(in: store) }
        return fieldPressures.map { pressure in
            var answers: [String] = []
            for form in members {
                let learnset = Set(store.moves(for: form).map(\.name))
                let abilities = Set(form.abilities.map(\.name))
                // Any other terrain displaces theirs; any other weather does too.
                for (terrain, ability, move) in [(Terrain.grassy, "Grassy Surge", "Grassy Terrain"),
                                                 (.psychic, "Psychic Surge", "Psychic Terrain"),
                                                 (.electric, "Electric Surge", "Electric Terrain"),
                                                 (.misty, "Misty Surge", "Misty Terrain")]
                where pressure.terrain != .none && terrain != pressure.terrain {
                    if abilities.contains(ability) {
                        answers.append("\(form.formLabel) overrides it with \(ability)")
                    } else if learnset.contains(move) {
                        answers.append("\(form.formLabel) can click \(move)")
                    }
                }
                for (weather, ability, move) in [(Weather.sun, "Drought", "Sunny Day"),
                                                 (.rain, "Drizzle", "Rain Dance"),
                                                 (.sand, "Sand Stream", "Sandstorm"),
                                                 (.snow, "Snow Warning", "Snowscape")]
                where pressure.weather != .none && weather != pressure.weather {
                    if abilities.contains(ability) {
                        answers.append("\(form.formLabel) overrides it with \(ability)")
                    } else if learnset.contains(move) {
                        answers.append("\(form.formLabel) can click \(move)")
                    }
                }
                if pressure.terrain != .none, learnset.contains("Steel Roller") {
                    answers.append("\(form.formLabel) removes it with Steel Roller")
                }
            }
            return (pressure, answers.first)
        }
    }
}
