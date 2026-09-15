//  Tools/reading/main.swift
//  How well the engine reads an opponent, against people who actually played.
//
//      ./Tools/reading.sh              every replay with a full team preview
//      ./Tools/reading.sh --games 200  a smaller sample
//
//  The engine plays a two-board solve: your half on the real board, their half
//  on the board as they can see it, with your unseen back two replaced by the
//  pair it thinks you most likely kept. Everything downstream of that — what it
//  expects them to do, what it thinks a turn is worth — rests on the guess.
//
//  Nothing measured it. The guess is made by scoring every possible four the
//  way *our own matchup grid* would score it and softmaxing, which is a
//  reasonable theory of how a person chooses and was never once checked against
//  a person choosing.
//
//  A replay settles it. Team preview shows all six of both teams, and the
//  switches that follow show which four each side actually brought. So: give
//  the engine both sixes and the two leads, ask which pair it expects behind
//  them, and compare against the pair that actually came.
//
//  Three numbers, each answering something different:
//
//    exact      the engine's single likeliest pair was the pair
//    either     at least one of the two it named actually came
//    weighted   the probability it assigned to the true pair, averaged. This
//               is the one that matters, because the search does not bet on
//               its top guess — it spreads its worlds across the likely ones.
//
//  A coin flip is worth knowing: with four unseen and two brought there are six
//  pairs, so naming one at random is 17% exact and 67% either.

import AppKit
import Foundation

struct Replay: Decodable {
    let id: String
    let rating: Int?
    let teams: [String: [String]]
    let brought: [String: [String]]
}

struct Corpus: Decodable {
    let games: [Replay]
}

func argument(_ flag: String) -> String? {
    guard let at = CommandLine.arguments.firstIndex(of: flag),
          at + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[at + 1]
}

@MainActor func run() {
    let store = Store.shared
    if let error = store.loadError { print("dataset error: \(error)"); exit(1) }
    let rules = store.rulebook

    // `--from` reads a different corpus, which is how a measurement built from
    // one set of games gets checked on a set it has never seen.
    let path = FileManager.default.currentDirectoryPath + "/"
        + (argument("--from") ?? "data/replays.json")
    guard let blob = FileManager.default.contents(atPath: path),
          let corpus = try? JSONDecoder().decode(Corpus.self, from: blob) else {
        print("no data/replays.json — run `make replays` first")
        exit(1)
    }

    /// A replay names a species; the dex knows forms. Showdown writes a
    /// regional form as "Indeedee-F" and a Mega as "Froslass-Mega", which are
    /// the display names with the spaces taken out.
    func form(named raw: String) -> Form? {
        func key(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let wanted = key(raw)
        if let exact = rules.forms.first(where: { key($0.formLabel) == wanted }) { return exact }
        // "Indeedee-F" is our "Indeedee (Female)"; "Rotom-Heat" our "Rotom (Heat)".
        let parts = raw.split(separator: "-", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            let base = key(parts[0]), tag = key(parts[1])
            let candidates = rules.forms.filter { key($0.name) == base || key($0.species) == base }
            if let match = candidates.first(where: { key($0.formLabel).contains(tag) }) { return match }
            if tag == "f", let match = candidates.first(where: { key($0.formLabel).contains("female") }) {
                return match
            }
            if tag == "m", let match = candidates.first(where: { key($0.formLabel).contains("male") }) {
                return match
            }
        }
        return rules.forms.first { key($0.name) == wanted }
    }

    /// A team of six, built plainly. A replay does not publish items, spreads
    /// or abilities, so every side is given the same ordinary build — which is
    /// the same handicap both the engine and the guess are under.
    func team(_ names: [String]) -> Team? {
        var out = Team()
        out.format = "doubles"
        out.slots = names.compactMap { name -> TeamSlot? in
            guard let form = form(named: name) else { return nil }
            var slot = TeamSlot(formID: form.id)
            slot.ability = form.abilities.first?.name ?? ""
            slot.item = form.stone ?? "Leftovers"
            slot.moves = Array(form.moves.prefix(4))
            var sp = Array(repeating: 0, count: 6)
            sp[Stat.hp.rawValue] = 20
            sp[(form.attack >= form.spAttack ? Stat.attack : Stat.spAttack).rawValue] = 23
            sp[Stat.speed.rawValue] = 23
            slot.sp = sp
            slot.alignmentName = form.attack >= form.spAttack ? "Adamant" : "Modest"
            return slot
        }
        return out.slots.count == names.count ? out : nil
    }

    let limit = Int(argument("--games") ?? "") ?? Int.max
    var asked = 0, exact = 0, either = 0
    var weighted = 0.0
    var unresolved = 0

    for game in corpus.games {
        if asked >= limit { break }
        // Both sides are asked about, because each is a reading of the other.
        for (us, them) in [("p1", "p2"), ("p2", "p1")] {
            guard let ourSix = game.teams[us], ourSix.count == 6,
                  let theirSix = game.teams[them], theirSix.count == 6,
                  let theirFour = game.brought[them], theirFour.count == 4,
                  let ourFour = game.brought[us], ourFour.count >= 2,
                  let ours = team(ourSix), let theirs = team(theirSix)
            else { unresolved += 1; continue }

            // What they actually led with, and what they actually kept back.
            let leadNames = Array(theirFour.prefix(2))
            let benchNames = Set(theirFour.dropFirst(2))
            guard let leads = leadNames.compactMap({ form(named: $0) }) as [Form]?,
                  leads.count == 2 else { unresolved += 1; continue }

            // Asked directly, conditioned on the leads they actually sent out.
            // Going through `Board.opening` would condition it on the leads the
            // engine *assumed* they would send, which is a different question
            // and made this read below chance the first time I measured it.
            //
            // A registered slot and the form it fights as differ for a stone
            // holder, so the lead ids are matched through the same mapping the
            // guess itself uses.
            var leadIDs = Set<String>()
            for slot in theirs.slots {
                guard let registered = slot.form(in: rules),
                      let battle = slot.battleForm(in: rules) else { continue }
                if leads.contains(where: { $0.id == battle.id || $0.id == registered.id }) {
                    leadIDs.insert(registered.id)
                }
            }
            guard leadIDs.count == 2 else { unresolved += 1; continue }

            let guesses = Board.benchGuesses(
                for: theirs, against: ours, opposite: ours,
                leadIDs: leadIDs, behind: 2,
                rules: rules, field: Field(isDoubles: true))
            guard !guesses.isEmpty else { unresolved += 1; continue }
            asked += 1

            func namesOf(_ guess: Board.BenchGuess) -> Set<String> {
                Set(guess.fighters.map(\.build.form.formLabel))
            }
            let truth = Set(benchNames.compactMap { form(named: $0)?.formLabel })
            if namesOf(guesses[0]) == truth { exact += 1 }
            if !namesOf(guesses[0]).isDisjoint(with: truth) { either += 1 }
            weighted += guesses.first { namesOf($0) == truth }?.chance ?? 0
        }
    }

    print("== how well the engine reads the four they bring ==\n")
    guard asked > 0 else {
        print("  nothing to read: \(unresolved) replays could not be resolved to forms")
        return
    }
    print("  \(asked) readings, \(unresolved) replays skipped\n")
    print(String(format: "  exact     %5.1f%%   the pair it named was the pair          (chance: 17%%)",
                 Double(exact) / Double(asked) * 100))
    print(String(format: "  either    %5.1f%%   one of the two it named actually came   (chance: 67%%)",
                 Double(either) / Double(asked) * 100))
    print(String(format: "  weighted  %5.1f%%   what it gave the true pair, averaged    (chance: 17%%)",
                 weighted / Double(asked) * 100))
    print()
    print("  The weighted figure is the one to move. The search does not bet on")
    print("  its top guess; it spreads its worlds across the likely pairs, so")
    print("  what it gave the pair that actually came is what it played against.")
}

MainActor.assumeIsolated { run() }
