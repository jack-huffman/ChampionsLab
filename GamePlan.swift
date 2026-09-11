//  GamePlan.swift
//  The three questions every team has to answer before it is finished.
//
//  A score out of 100 tells you a team is good. It does not tell you how to
//  play it, and it does not tell you what happens when the thing across from
//  you is faster, or inverts the Speed order, or puts up a terrain your plan
//  did not account for. Those three come up in most games and a team that has
//  no answer to one of them loses to it every time rather than sometimes.
//
//  So each generated six answers them in plain terms, naming the member and the
//  move that does the work. Where there is no answer it says so — an honest
//  "nothing here does this" is worth more than a confident sentence, because it
//  is the one that tells you what to change.
//
//  Everything is read off what the slots actually have selected, not what they
//  could learn.

import Foundation

@MainActor
struct GamePlanner {
    let store: Store
    let team: Team
    var format = "doubles"

    struct Answer: Identifiable {
        enum Standing {
            case solid      // a real, selected answer
            case partial    // something, but not enough on its own
            case none       // nothing here does this

            var label: String {
                switch self {
                case .solid:   return "Covered"
                case .partial: return "Partial"
                case .none:    return "No answer"
                }
            }
        }

        let question: String
        let standing: Standing
        /// The plan, in the order you would actually do it.
        let steps: [String]
        /// What to add if the answer is thin.
        let fix: String?
        var id: String { question }
    }

    // MARK: - What the team has

    private struct Member {
        let slot: TeamSlot
        let form: Form
        let moves: Set<String>
        let learnable: Set<String>
        let ability: String
        let speed: Int
    }

    private var members: [Member] {
        team.slots.compactMap { slot in
            guard let form = slot.battleForm(in: store),
                  let combatant = slot.combatant(in: store) else { return nil }
            return Member(slot: slot, form: form,
                          moves: Set(slot.moves.compactMap { store.move($0)?.name }),
                          learnable: Set(form.moves.compactMap { store.move($0)?.name }),
                          ability: combatant.ability,
                          speed: combatant.stat(.speed))
        }
    }

    /// Members running any of these moves, named.
    private func who(_ names: Set<String>, in members: [Member]) -> [(Member, String)] {
        members.compactMap { member in
            guard let hit = names.intersection(member.moves).sorted().first else { return nil }
            return (member, hit)
        }
    }

    private func couldRun(_ names: Set<String>, in members: [Member]) -> [(Member, String)] {
        members.compactMap { member in
            guard names.isDisjoint(with: member.moves),
                  let hit = names.intersection(member.learnable).sorted().first else { return nil }
            return (member, hit)
        }
    }

    /// "A", "A and B", "A, B and C" — so the sentences read like sentences.
    private func joined(_ items: [String]) -> String {
        switch items.count {
        case 0:  return ""
        case 1:  return items[0]
        case 2:  return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    /// Member plus the move doing the work, for when the move is not already
    /// named in the sentence.
    private func list(_ pairs: [(Member, String)], limit: Int = 3) -> String {
        joined(pairs.prefix(limit).map { "\($0.0.form.formLabel)'s \($0.1)" })
    }

    /// Just the Pokémon, for when the sentence already says the move.
    private func names(_ pairs: [(Member, String)], limit: Int = 3) -> String {
        joined(pairs.prefix(limit).map { $0.0.form.formLabel })
    }

    private func verb(_ pairs: [(Member, String)], _ singular: String,
                      _ plural: String) -> String {
        pairs.count == 1 ? singular : plural
    }

    // MARK: - The three answers

    var answers: [Answer] { [againstFaster, againstTrickRoom, againstField] }

    // MARK: Faster teams

    private var againstFaster: Answer {
        let members = self.members
        let question = "How do we play against faster teams?"

        let tailwind = who(["Tailwind"], in: members)
        let trickRoom = who(["Trick Room"], in: members)
        let drops = who(["Icy Wind", "Electroweb", "Rock Tomb", "Bulldoze", "String Shot"],
                        in: members)
        let paralysis = who(["Thunder Wave", "Glare", "Nuzzle", "Stun Spore"], in: members)
        // Fake Out is counted as denial below, not as an attack — it deals
        // nothing and listing it twice read as two separate answers.
        let priority = members.compactMap { member -> (Member, String)? in
            let fast = member.slot.moves
                .compactMap { store.move($0) }
                .filter { $0.priority > 0 && $0.isDamaging && $0.power >= 40
                          && $0.name != "Fake Out" }
                .max { $0.priority < $1.priority }
            return fast.map { (member, $0.name) }
        }
        let denial = who(["Fake Out", "Follow Me", "Rage Powder", "Quash"], in: members)

        // How the six sits against the numbers the format actually presents.
        let benchmarks = Forecast(store: store, format: format).speedLandscape
        let bar = benchmarks.prefix(5).map(\.speed).min() ?? 0
        let aboveBar = members.filter { $0.speed >= bar }.count

        var steps: [String] = []
        if !tailwind.isEmpty {
            steps.append("Match them: \(names(tailwind)) \(verb(tailwind, "sets", "set")) Tailwind. It does not cancel theirs — both sides can have it up at once — so this buys parity rather than an edge.")
        }
        if !trickRoom.isEmpty {
            steps.append("Or invert them: \(names(trickRoom)) \(verb(trickRoom, "sets", "set")) Trick Room. This is the real counter to a Tailwind team — their doubled Speed makes them move even later under it.")
        }
        if !drops.isEmpty {
            steps.append("Chip their Speed with \(list(drops)). A stage down is ×2/3, so a Tailwind team drops from twice Speed to about 1.33× — it blunts the boost rather than racing it, and it sticks after their four turns run out.")
        }
        if !paralysis.isEmpty {
            steps.append("\(list(paralysis)) \(verb(paralysis, "halves", "halve")) a target's Speed for the rest of the game, which outlasts any Tailwind.")
        }
        if !priority.isEmpty {
            steps.append("When you are behind on Speed anyway, \(list(priority)) \(verb(priority, "ignores", "ignore")) the question entirely.")
        }
        if !denial.isEmpty {
            steps.append("\(list(denial)) \(verb(denial, "takes", "take")) their first turn away while you set up.")
        }
        if bar > 0 {
            steps.append(aboveBar == 0
                ? "Nothing on this six reaches \(bar), the fifth-fastest number in the format, so you are behind on raw stats in most games."
                : "\(aboveBar) of \(members.count) \(aboveBar == 1 ? "already sits" : "already sit") at or above \(bar), the fifth-fastest number in the format.")
        }

        let hasControl = !tailwind.isEmpty || !trickRoom.isEmpty
        let hasSomething = hasControl || !drops.isEmpty || !paralysis.isEmpty || !priority.isEmpty
        let standing: Answer.Standing = hasControl ? .solid : (hasSomething ? .partial : .none)

        var fix: String?
        if !hasControl {
            let candidates = couldRun(["Tailwind", "Trick Room", "Icy Wind", "Electroweb"],
                                      in: members)
            fix = candidates.isEmpty
                ? "No speed control at all. Add a Tailwind setter, or Icy Wind on any slot that can spare one."
                : "One move slot away — " + list(candidates) + " would give this six real speed control."
        }
        return Answer(question: question, standing: standing, steps: steps, fix: fix)
    }

    // MARK: Trick Room

    private var againstTrickRoom: Answer {
        let members = self.members
        let question = "How do we counter Trick Room?"
        let share = MetaModel(store: store, format: format).tactics
            .first { $0.name == "Trick Room" }?.share

        let taunt = who(["Taunt"], in: members)
        let pranksterTaunt = taunt.filter { $0.0.ability == "Prankster" }
        let encore = who(["Encore"], in: members)
        let imprison = who(["Imprison"], in: members)
        let ours = who(["Trick Room"], in: members)
        let fakeOut = who(["Fake Out"], in: members)
        // Under Trick Room the slow move first, so a slow six is not in trouble.
        let slow = members.filter { $0.speed <= 110 }

        var steps: [String] = []
        if let share {
            steps.append(String(format: "%.0f%% of tracked teams carry it, so this comes up roughly one game in %d.",
                                share * 100, max(2, Int((1 / share).rounded()))))
        }
        if !pranksterTaunt.isEmpty {
            steps.append("Cleanest line: \(names(pranksterTaunt)) has Prankster Taunt, which goes first and stops the setter before it acts. It fails into Dark types, so check what is across from you.")
        } else if !taunt.isEmpty {
            steps.append("Taunt the setter with \(names(taunt)) — but without Prankster you have to outspeed it, which is the whole problem, since Trick Room setters are slow on purpose.")
        }
        if !fakeOut.isEmpty {
            steps.append("\(names(fakeOut)) \(verb(fakeOut, "has", "have")) Fake Out, which flinches the setter and denies the turn outright. Trick Room is priority −7, so Fake Out always lands first.")
        }
        if !encore.isEmpty {
            steps.append("\(names(encore))'s Encore on the setter the turn after it goes up forces it to click Trick Room again, which cancels it — the setter undoes its own turn.")
        }
        if !ours.isEmpty {
            steps.append("\(names(ours)) \(verb(ours, "can", "can")) re-use Trick Room to cancel theirs, which turns their setup turn into a wasted one.")
        }
        if !imprison.isEmpty && !ours.isEmpty {
            steps.append("\(names(imprison))'s Imprison with Trick Room on the same side seals it off entirely — they simply cannot click it.")
        }
        steps.append(slow.count >= 4
            ? "Even if it goes up, \(slow.count) of \(members.count) here are slow enough to function under it, so it is not a losing position."
            : "Only \(slow.count) of \(members.count) \(slow.count == 1 ? "works" : "work") under it, so letting it go up hands them the turn order for five turns.")

        let hard = !pranksterTaunt.isEmpty || !fakeOut.isEmpty || (!imprison.isEmpty && !ours.isEmpty)
        let soft = !taunt.isEmpty || !encore.isEmpty || !ours.isEmpty || slow.count >= 4
        let standing: Answer.Standing = hard ? .solid : (soft ? .partial : .none)

        var fix: String?
        if !hard {
            let candidates = couldRun(["Taunt", "Encore", "Fake Out"], in: members)
            fix = candidates.isEmpty
                ? "Nothing here stops the setup turn. Taunt, Encore or a Fake Out on the setter is the usual answer."
                : "One move slot away — " + list(candidates) + " would stop the setup turn."
        }
        return Answer(question: question, standing: standing, steps: steps, fix: fix)
    }

    // MARK: Weather and terrain

    private var againstField: Answer {
        let members = self.members
        let question = "How do we counter weather and terrain?"
        let meta = MetaModel(store: store, format: format)
        let control = meta.fieldControl(of: team)

        let removal = who(["Steel Roller", "Defog"], in: members)
        let setters = members.filter { member in
            ["Grassy Surge", "Psychic Surge", "Electric Surge", "Misty Surge",
             "Drought", "Drizzle", "Sand Stream", "Snow Warning"].contains(member.ability)
        }

        var steps: [String] = []
        for entry in control.prefix(4) {
            let odds = String(format: "%.0f%%", entry.pressure.probability * 100)
            if entry.isSelected, let answer = entry.answer {
                steps.append("\(entry.pressure.label) — up in about \(odds) of games. \(answer).")
            } else if let answer = entry.answer {
                // Only a move is "a slot away"; an ability it already has is not.
                let suffix = answer.contains("could run") ? " — one move slot away." : "."
                steps.append("\(entry.pressure.label) — up in about \(odds) of games. Nothing selected changes it, but \(answer)\(suffix)")
            } else {
                steps.append("\(entry.pressure.label) — up in about \(odds) of games, and nothing here changes it. You play those games on their field.")
            }
        }
        if !setters.isEmpty {
            let setterList = joined(setters.map { "\($0.form.formLabel) (\($0.ability))" })
            steps.append("Your own \(setterList) \(setters.count == 1 ? "re-sets" : "re-set") on every switch-in, so you can take the field back by pivoting rather than spending a turn on it.")
        }
        if !removal.isEmpty {
            steps.append("\(list(removal)) \(verb(removal, "clears", "clear")) terrain outright rather than replacing it — useful when you do not want any terrain up, including your own.")
        }

        let covered = control.filter(\.isSelected)
            .reduce(0.0) { $0 + $1.pressure.probability }
        let total = control.reduce(0.0) { $0 + $1.pressure.probability }
        let fraction = total > 0 ? covered / total : 0
        let standing: Answer.Standing = fraction >= 0.6 ? .solid : (fraction > 0 ? .partial : .none)

        var fix: String?
        if standing != .solid {
            let unanswered = control.filter { !$0.isSelected }
                .max { $0.pressure.probability < $1.pressure.probability }
            if let unanswered {
                fix = unanswered.answer.map {
                    "The biggest gap is \(unanswered.pressure.label) — \($0)."
                } ?? "The biggest gap is \(unanswered.pressure.label), and nothing on this six can change it. A Surge ability or a terrain move would."
            }
        }
        return Answer(question: question, standing: standing, steps: steps, fix: fix)
    }
}
