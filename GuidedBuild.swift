//  GuidedBuild.swift
//  The interview: questions worked out from the Pokémon in front of you.
//
//  The one-shot builder hands back six finished teams and no reasoning you can
//  argue with. Coaching does the opposite — it asks what you want the team to
//  do, tells you what that costs, and lets you decide. Every question here is
//  generated from the seed rather than written in advance, and every option
//  carries the number that justifies it: not "Trick Room is an option" but
//  "under Tailwind this moves first against 2 of 20 tracked threats; under
//  Trick Room, 20 of 20".
//
//  The answers become a brief the search actually reads.

import Foundation

/// What the interview has established about the team you want.
struct BuildBrief {
    var plan: Archetype = .balance
    var dualMega = false
    /// Types a partner must resist, because the seed folds to them.
    var mustResist: Set<PokeType> = []
    /// Threats the team is required to have an answer to.
    var mustAnswer: [Form] = []
    /// Jobs the interview committed to filling.
    var wantRoles: Set<String> = []
    /// What was decided, in order, for the summary.
    var decisions: [(question: String, answer: String)] = []
}

@MainActor
struct BuildInterview {
    let store: Store
    let seed: Form
    var format = "doubles"

    struct Question: Identifiable {
        let id: String
        let prompt: String
        /// Why this is being asked, with the numbers behind it.
        let detail: String
        let options: [Option]
    }

    struct Option: Identifiable {
        /// Stable across regeneration. This was a fresh UUID, and since the
        /// questions are rebuilt whenever the view redraws, the id stored when
        /// you picked an option never matched the one being drawn a moment
        /// later — so the radio button never filled in.
        var id: String { label }
        let label: String
        /// The arithmetic that makes this a real choice, not a preference.
        let detail: String
        let recommended: Bool
        let apply: (inout BuildBrief) -> Void
    }

    // MARK: - The seed, read out loud

    struct Briefing {
        let types: [PokeType]
        let worstWeaknesses: [(type: PokeType, multiplier: Double, fieldShare: Double)]
        let bestMove: String
        let speed: Int
        let outspeeds: Int
        let fieldSize: Int
        let losesTo: [String]
        let beats: [String]
        let standing: Double
    }

    func briefing() -> Briefing {
        let forecast = Forecast(store: store, format: format)
        let profile = forecast.profile(of: seed)
        let meta = MetaModel(store: store, format: format)

        // Which of its weaknesses the format actually exploits.
        var weaknesses: [(PokeType, Double, Double)] = []
        for type in PokeType.allCases {
            let multiplier = TypeChart.multiplier(type, into: seed,
                                                  ability: seed.abilities.first?.name)
            guard multiplier > 1 else { continue }
            let share = meta.attackingShare(of: type)
            weaknesses.append((type, multiplier, share))
        }
        weaknesses.sort { ($0.1 * (0.3 + $0.2)) > ($1.1 * (0.3 + $1.2)) }

        var combatant = Combatant(form: seed, ability: seed.abilities.first?.name ?? "",
                                  item: seed.megaStone)
        combatant.sp = [2, 32, 0, 0, 0, 32]
        combatant.alignment = Alignment.named(
            seed.attack >= seed.spAttack ? "Adamant" : "Modest")

        return Briefing(
            types: seed.pokeTypes,
            worstWeaknesses: Array(weaknesses.prefix(3)).map {
                (type: $0.0, multiplier: $0.1, fieldShare: $0.2)
            },
            bestMove: store.bestMove(for: seed)?.name ?? "—",
            speed: combatant.stat(.speed),
            outspeeds: profile.outspeeds,
            fieldSize: profile.fieldSize,
            losesTo: profile.loses.prefix(4).map(\.name),
            beats: profile.beats.prefix(4).map(\.name),
            standing: profile.score)
    }

    // MARK: - The questions

    func questions() -> [Question] {
        var out: [Question] = [speedQuestion(), coverQuestion()]
        if let answer = answerQuestion() { out.append(answer) }
        out.append(fieldQuestion())
        out.append(megaQuestion())
        return out
    }

    /// How this Pokémon is going to move first, if it ever does.
    private func speedQuestion() -> Question {
        let forecast = Forecast(store: store, format: format)
        let marks = forecast.speedLandscape
        var combatant = Combatant(form: seed, ability: seed.abilities.first?.name ?? "",
                                  item: seed.megaStone)
        combatant.sp = [2, 32, 0, 0, 0, 32]
        combatant.alignment = Alignment.named(seed.attack >= seed.spAttack ? "Jolly" : "Timid")
        let flat = combatant.stat(.speed)
        let underTailwind = marks.filter { flat * 2 > $0.speed }.count
        let underTrickRoom = marks.filter { flat < $0.speed }.count
        let unaided = marks.filter { flat > $0.speed }.count

        let hasPriority = store.attackingMoves(for: seed)
            .contains { $0.priority > 0 && $0.power >= 40 }
        let wantsTrickRoom = underTrickRoom > underTailwind
        let fastEnough = unaided >= marks.count / 2

        var options: [Option] = []
        options.append(Option(
            label: "Tailwind",
            detail: "At \(flat) Speed with full investment it moves first against \(underTailwind) of \(marks.count) tracked threats under Tailwind, and \(unaided) without it.",
            recommended: !wantsTrickRoom && !fastEnough) { brief in
                brief.plan = .tailwind
                brief.wantRoles.insert("Speed control")
            })
        options.append(Option(
            label: "Trick Room",
            detail: "Inverted, it moves first against \(underTrickRoom) of \(marks.count). "
                + (hasPriority ? "It also has priority, which works either way."
                               : "It has no priority to fall back on."),
            recommended: wantsTrickRoom) { brief in
                brief.plan = .trickRoom
                brief.wantRoles.insert("Speed control")
            })
        options.append(Option(
            label: "Neither — it is fast enough",
            detail: fastEnough
                ? "It already moves first against \(unaided) of \(marks.count) with no help."
                : "It would be moving second against \(marks.count - unaided) of \(marks.count). Only pick this if something else on the team handles Speed.",
            recommended: fastEnough && !wantsTrickRoom) { brief in
                brief.plan = .balance
            })
        return Question(
            id: "speed",
            prompt: "How does it move first?",
            detail: "Speed decides more games than damage does, and this one sits at \(flat) with full investment.",
            options: options)
    }

    /// The weakness the format is actually going to punish.
    private func coverQuestion() -> Question {
        let brief = briefing()
        let meta = MetaModel(store: store, format: format)
        guard let worst = brief.worstWeaknesses.first else {
            return Question(id: "cover", prompt: "Anything to shore up?",
                            detail: "Nothing on this Pokémon is badly exposed.",
                            options: [Option(label: "Nothing in particular",
                                             detail: "Build for offence.",
                                             recommended: true) { _ in }])
        }
        let multiplier = worst.multiplier == 4 ? "4×" : "2×"
        var options: [Option] = []

        // Weather that halves the offending type, where one exists.
        let halving: [(String, Weather)] = [("rain", .rain), ("harsh sun", .sun)]
        if worst.type == .fire || worst.type == .water {
            let weather: Weather = worst.type == .fire ? .rain : .sun
            let plan: Archetype = weather == .rain ? .rain : .sun
            _ = halving
            options.append(Option(
                label: weather == .rain ? "Put up rain" : "Put up sun",
                detail: "\(weather == .rain ? "Rain" : "Sun") halves every \(worst.type.rawValue) move on the field, which turns its \(multiplier) weakness into a \(worst.multiplier == 4 ? "2×" : "1×") one for the whole game.",
                recommended: true) { b in
                    b.plan = plan
                    b.wantRoles.insert("Owning the field")
                })
        }
        options.append(Option(
            label: "A partner that resists \(worst.type.rawValue)",
            detail: String(format: "%.0f%% of the field attacks with %@. A member that resists it can take those hits instead.",
                           worst.fieldShare * 100, worst.type.rawValue),
            recommended: options.isEmpty) { b in
                b.mustResist.insert(worst.type)
            })
        options.append(Option(
            label: "Redirection, so it never takes the hit",
            detail: String(format: "Follow Me or Rage Powder pulls the attack away entirely. %.0f%% of the field already uses it.",
                           (meta.tactics.first { $0.name == "Redirection" }?.share ?? 0) * 100),
            recommended: false) { b in
                b.wantRoles.insert("Buying a turn")
            })
        options.append(Option(
            label: "Accept it and play around it",
            detail: "No slot spent on the problem. Workable if you are confident about what you bring at Preview.",
            recommended: false) { _ in })

        return Question(
            id: "cover",
            prompt: "It takes \(multiplier) from \(worst.type.rawValue). What covers that?",
            detail: String(format: "%.0f%% of tracked threats carry a %@ attack, so this comes up most games.",
                           worst.fieldShare * 100, worst.type.rawValue),
            options: options)
    }

    /// The specific things it cannot beat.
    private func answerQuestion() -> Question? {
        let profile = Forecast(store: store, format: format).profile(of: seed)
        let losses = profile.loses.prefix(3)
        guard !losses.isEmpty else { return nil }
        var options: [Option] = losses.map { row in
            Option(label: row.name,
                   detail: String(format: "Their %@ does %.0f%% to it; its best back is %.0f%%. %@ usage.",
                                  row.theirBest, row.theirPercent, row.myPercent,
                                  String(format: "%.0f%%", row.usage)),
                   recommended: row.usage >= 20) { brief in
                brief.mustAnswer.append(row.form)
            }
        }
        options.append(Option(label: "None of them specifically",
                              detail: "Let the search balance the six instead of aiming it.",
                              recommended: false) { _ in })
        return Question(
            id: "answer",
            prompt: "Which of these should the team answer?",
            detail: "Run against every tracked threat, these are the ones it loses to. A partner will be picked to beat whichever you choose.",
            options: options)
    }

    /// Whether to contest the field the format puts up.
    private func fieldQuestion() -> Question {
        let meta = MetaModel(store: store, format: format)
        let pressures = meta.fieldPressures.prefix(2)
        var options: [Option] = pressures.map { pressure in
            Option(label: "Set your own instead of \(pressure.label)",
                   detail: String(format: "%@ is up in about %.0f%% of games, set by %@. %@",
                                  pressure.label, pressure.probability * 100,
                                  pressure.setters.first?.name ?? "the field",
                                  pressure.consequences.first ?? ""),
                   recommended: pressure.probability >= 0.28) { brief in
                brief.wantRoles.insert("Owning the field")
            }
        }
        options.append(Option(label: "Play on theirs",
                              detail: "No slot spent on terrain or weather. Fine if none of it hurts this Pokémon.",
                              recommended: pressures.isEmpty) { _ in })
        return Question(
            id: "field",
            prompt: "Do you want the field, or theirs?",
            detail: "Terrain and weather change every turn of the game, not one of them.",
            options: options)
    }

    /// The second Mega question, which is really a question about Team Preview.
    private func megaQuestion() -> Question {
        Question(
            id: "mega",
            prompt: "One Mega, or two?",
            detail: "Only one can Mega Evolve per battle, and you bring four of six — so a second is a whole alternate team picked at Preview, not a wasted slot.",
            options: [
                Option(label: "Two Megas",
                       detail: "Gives two lines with their own four to bring. The second is chosen to cover what \(seed.formLabel) cannot.",
                       recommended: true) { $0.dualMega = true },
                Option(label: "Just \(seed.formLabel)",
                       detail: "Five slots free for support. Simpler to play, and every item slot does something.",
                       recommended: false) { $0.dualMega = false },
            ])
    }
}
