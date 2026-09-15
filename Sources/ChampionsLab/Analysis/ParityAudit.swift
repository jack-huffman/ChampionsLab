//  ParityAudit.swift
//  What the battle model actually implements, decided by experiment.
//
//  Champions will keep releasing: new Pokémon, new Megas, new items, new
//  abilities. A list of "what we support" written by hand goes stale the day
//  after it is written, so this does not keep one. It takes whatever is in the
//  dex today and finds out, by trying:
//
//  * a **move** is used, and the board is compared before and after;
//  * an **ability** is given to a Pokémon and the same turn is played with and
//    without it, across the situations an ability can matter in — walking in,
//    being hit, hitting, and the end of a turn in each weather;
//  * an **item** is held, and the same comparison is made.
//
//  Anything that changes nothing in any of them is something the model does
//  not implement. That can be wrong in one direction — a rule that only shows
//  up in a position the battery does not set up will read as missing — which
//  is why the report says "found no effect" rather than "unimplemented", and
//  why `notModelled` carries the handful that are deliberately out of scope,
//  with the reason.
//
//  It runs off the main thread and reports progress as it goes.

import Foundation

struct ParityAudit: Sendable {

    /// One thing in the dex, and whether the model reacted to it.
    struct Finding: Sendable, Identifiable, Hashable {
        enum Kind: String, Sendable, CaseIterable {
            case move, ability, item
            var plural: String { self == .ability ? "abilities" : rawValue + "s" }
        }
        enum Verdict: String, Sendable {
            /// The battery played it and the game came out differently. This is
            /// the only verdict that is proof.
            case implemented
            /// The battery could not make it fire, but the model does read its
            /// text into a rule it is known to apply. A 10% paralysis lands
            /// here: the audit does not roll dice, so it never sees it happen,
            /// but the model does carry it.
            case byRule
            /// Nothing happened and nothing parsed. The model does not know
            /// what this does.
            case noEffect
            /// Deliberately out of scope, with a reason.
            case notModelled

            var isCovered: Bool { self == .implemented || self == .byRule }
            var label: String {
                switch self {
                case .implemented: return "Proven"
                case .byRule: return "Parsed"
                case .noEffect: return "Not proven"
                case .notModelled: return "Out of scope"
                }
            }
        }
        let kind: Kind
        let name: String
        let verdict: Verdict
        /// What it says it does, or why it is out of scope.
        let detail: String
        /// How often the heaviest user of it is seen, as a share of games.
        let usage: Double
        var id: String { "\(kind.rawValue):\(name)" }
    }

    /// How far along, and what it is doing — in three parts, because a bar
    /// that only moves tells you nothing about whether to trust the answer.
    /// `phase` is the pass, `explains` is what that pass proves, and `note` is
    /// the thing it has in its hands right now.
    public struct Progress: Sendable {
        public let phase: String
        public let explains: String
        public let note: String
        public let done: Int
        public let total: Int
        public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    }

    /// Every pass, in order, as one run with one progress count. The screen and
    /// the command line both go through here so they cannot drift apart.
    public static func full(rules: Rulebook, usage: [UsageEntry], items: [Item],
                            progress: @Sendable (Progress) -> Void = { _ in }) -> Report {
        let started = Date()
        let report = run(rules: rules, usage: usage, items: items, progress: progress)
        return Report(findings: report.findings.sorted { $0.usage > $1.usage },
                      seconds: Date().timeIntervalSince(started))
    }

    /// A control: a name the model has never heard of must come back as
    /// having no effect. If it does not, the battery is finding differences
    /// that are not there and every number it prints is worthless.
    /// Why the battery believes one name is or is not implemented. The app's
    /// Parity screen shows this when a row is opened, and `--why` prints it.
    public static func explain(_ name: String, rules: Rulebook) -> String {
        let bench = Bench(rules: rules)
        var lines: [String] = []
        if let move = rules.moves.values.first(where: { $0.name == name }) {
            lines.append("move    \(bench.reactsTo(move: move) ? "implemented" : "no effect found")")
        }
        lines.append("ability \(bench.evidence(ability: name) ?? "no effect found")")
        lines.append("item    \(bench.evidence(item: name) ?? "no effect found")")
        return lines.joined(separator: "\n")
    }

    /// Which of these moves the battle model does nothing at all with.
    ///
    /// One bench for the lot, and the move battery only: `explain` builds a
    /// fresh bench and runs all three batteries per name, which is fine for a
    /// person at a command line and far too slow for a test.
    public static func movesThatDoNothing(_ names: [String], rules: Rulebook) -> [String] {
        let bench = Bench(rules: rules)
        return names.filter { name in
            guard let move = rules.moves.values.first(where: { $0.name == name }) else { return true }
            return !bench.reactsTo(move: move)
        }
    }

    public static func controlFailure(rules: Rulebook) -> String? {
        let bench = Bench(rules: rules)
        if let why = bench.evidence(ability: "Nonexistent Ability") {
            return "a made-up ability changed the game: \(why)"
        }
        if let why = bench.evidence(item: "Nonexistent Item") {
            return "a made-up item changed the game: \(why)"
        }
        return nil
    }

    struct Report: Sendable {
        let findings: [Finding]
        let seconds: Double
        func of(_ kind: Finding.Kind) -> [Finding] { findings.filter { $0.kind == kind } }
        func count(_ kind: Finding.Kind, _ verdict: Finding.Verdict) -> Int {
            findings.filter { $0.kind == kind && $0.verdict == verdict }.count
        }
    }

    /// Things the model does not carry, and will not, with the reason. Kept
    /// short and specific: each line is a decision, not an excuse.
    public static let notModelled: [String: String] = [
        "Pressure": "Power Points are not tracked at all — a battle here is decided long before anything runs out of them.",
        "Spite": "Power Points are not tracked at all.",
        "Imprison": "Power Points are not tracked at all.",
        "Sleep Talk": "Calls another move at random; the search cannot price a move that becomes a different move.",
        "Metronome": "Calls a move at random out of every move in the game.",
        "Assist": "Calls a move at random from the rest of the team.",
        "Mirror Move": "Calls back whatever it was hit by.",
        "Copycat": "Calls back the last move used by anybody.",
        "Me First": "Calls the move the target has not used yet.",

        // Abilities whose whole effect is telling the player something. The
        // model has no player to tell, and an engine that already searches the
        // position knows all of it anyway.
        "Frisk": "Reveals the opponent's held item, which the search can already see.",
        "Forewarn": "Reveals the opponent's strongest move, which the search can already see.",
        "Anticipation": "Warns that the opponent has something dangerous, which the search already knows.",
        "Illuminate": "Stops the holder's accuracy being lowered, and accuracy stages are not modelled.",
        "Supersweet Syrup": "Lowers the opposing side's evasion, and evasion stages are not modelled.",
        "Pickup": "Finds an item after the battle is over.",
        "Cursed Body": "Disables a move by spending its Power Points, which are not tracked.",
        "Rivalry": "Turns on the two Pokémon's genders, which the dataset does not carry.",
        "Gluttony": "Brings a pinch berry forward to half health. Only the Sitrus is modelled, and it already fires there.",
    ]

    // MARK: - Running it

    public static func run(rules: Rulebook, usage: [UsageEntry], items itemList: [Item] = [],
                           progress: @Sendable (Progress) -> Void = { _ in }) -> Report {
        let started = Date()
        var findings: [Finding] = []

        // How often each Pokémon is seen, so a gap can be weighed.
        var usageOf: [String: Double] = [:]
        for entry in usage {
            if let form = rules.forms.first(where: { $0.formLabel == entry.name || $0.name == entry.name }) {
                usageOf[form.id] = max(usageOf[form.id] ?? 0, entry.usage)
            }
        }
        func weight(carriers: [Form]) -> Double {
            carriers.compactMap { usageOf[$0.id] }.max() ?? 0
        }

        let legalMoves = rules.moves.values.filter(\.learnable).sorted { $0.name < $1.name }
        let abilities = Set(rules.forms.flatMap { $0.abilities.map(\.name) }).sorted()
        let seenItems = itemList.filter(\.seenInGame).sorted { $0.name < $1.name }
        let total = legalMoves.count + abilities.count + seenItems.count
        // One bench for the whole run: building it sorts the entire move table.
        let bench = Bench(rules: rules)

        // -- moves ------------------------------------------------------------
        for (index, move) in legalMoves.enumerated() {
            if Task.isCancelled { break }
            if index % 25 == 0 {
                progress(Progress(
                    phase: "Using every move",
                    explains: "Each move is played, and the same turn is played without it. "
                            + "Anything the move did is the difference between the two boards.",
                    note: move.name, done: index, total: total))
            }
            let carriers = rules.forms.filter { $0.moves.contains(move.id) }
            if let why = notModelled[move.name] {
                findings.append(Finding(kind: .move, name: move.name, verdict: .notModelled,
                                        detail: why, usage: weight(carriers: carriers)))
                continue
            }
            // Behaviour first, because behaviour is proof. Only when the
            // battery cannot make a move fire does the parse get a say.
            let verdict: Finding.Verdict = bench.reactsTo(move: move) ? .implemented
                : (move.parsesIntoARule ? .byRule : .noEffect)
            findings.append(Finding(kind: .move, name: move.name, verdict: verdict,
                                    detail: String(move.effect.prefix(140)),
                                    usage: weight(carriers: carriers)))
        }

        // -- abilities --------------------------------------------------------
        for (index, name) in abilities.enumerated() {
            if Task.isCancelled { break }
            if index % 10 == 0 {
                progress(Progress(
                    phase: "Trying every ability",
                    explains: "Every weather, terrain, attack type and provocation is played "
                            + "twice: once with the ability and once with none at all.",
                    note: name, done: legalMoves.count + index, total: total))
            }
            let carriers = rules.forms.filter { $0.abilities.contains { $0.name == name } }
            if let why = notModelled[name] {
                findings.append(Finding(kind: .ability, name: name, verdict: .notModelled,
                                        detail: why, usage: weight(carriers: carriers)))
                continue
            }
            let why = bench.evidence(ability: name)
            findings.append(Finding(kind: .ability, name: name,
                                    verdict: why == nil ? .noEffect : .implemented,
                                    detail: why.map { "Changes the game: \($0)." } ?? "",
                                    usage: weight(carriers: carriers)))
        }

        // -- items -------------------------------------------------------------
        for (index, item) in seenItems.enumerated() {
            if Task.isCancelled { break }
            if index % 10 == 0 {
                progress(Progress(
                    phase: "Holding every item",
                    explains: "The same turns again, with the item in hand and with empty hands, "
                            + "including one position where it has already been used up.",
                    note: item.name,
                    done: legalMoves.count + abilities.count + index, total: total))
            }
            // A Mega Stone's whole effect is letting something Mega Evolve,
            // which the battle does elsewhere and the team builder enforces.
            let stone = item.effect.contains("Mega Evolve")
            let why = stone ? "the team builder grants the evolution" : bench.evidence(item: item.name)
            findings.append(Finding(kind: .item, name: item.name,
                                    verdict: why == nil ? .noEffect : .implemented,
                                    detail: stone ? "Lets its holder Mega Evolve."
                                                  : String(item.effect.prefix(140)),
                                    usage: 0))
        }

        progress(Progress(phase: "Done", explains: "", note: "",
                          done: total, total: total))
        return Report(findings: findings.sorted { $0.usage > $1.usage },
                      seconds: Date().timeIntervalSince(started))
    }
}

// MARK: - The bench the audit runs on

/// A fixed pair of boards to try things on, and the comparisons that decide
/// whether the model noticed.
///
/// The probe moves matter as much as the boards: an ability that only answers
/// Fire will never show itself if the only attack on the bench is a Tackle, so
/// the user carries one move of each of the common types, a contact move and a
/// non-contact one, and the battery tries them all.
private struct Bench {
    let rules: Rulebook
    let mine: Team
    let theirs: Team
    /// A plain damaging move of every type in both categories, so a rule that
    /// only answers Fire, or only answers special attacks, has something to
    /// answer. Ordinary power on purpose: sorting for the weakest move first
    /// picked Flail, Grass Knot and Night Shade, whose damage the calculator
    /// works out from weight or HP rather than from power. They dealt 2 points,
    /// so a 50% boost rounded away to nothing and every pinch ability in the
    /// game — Overgrow, Blaze, Torrent, Swarm — read as missing.
    let typed: [Move]
    /// The handful used in the turn loop, where every extra move costs a full
    /// resolve: a contact attack, a special attack, and a spread move.
    let probes: [Move]
    /// What the other side can do to provoke a reaction: a contact hit, a stat
    /// drop, a burn, a paralysis, a flinch, a confusion, and a Protect.
    ///
    /// Chosen by what they do rather than by name. Naming them picked Growl,
    /// which no Champions Pokémon can legally learn and whose dex entry is
    /// blank, so the drop never happened and Defiant, Competitive and every
    /// other ability waiting on a stat drop read as missing.
    let provocations: [Move]
    /// A status move of the user's own, so a rule about status moves --
    /// Prankster, Magic Bounce, Soundproof -- has something to act on.
    let ourStatus: [Move]
    /// Everything the user's lead actually does in the turn loop, in the order
    /// its move list holds them, so a play's move index means what it says.
    var acting: [Move] { probes + ourStatus }

    /// What the other side throws, in its own move-list order: first the
    /// provocations, then one attack of every type. The typed attacks are what
    /// let an absorbing rule show -- Justified wants a Dark move, Flash Fire a
    /// Fire one, Levitate a Ground one -- and without them a whole family of
    /// abilities had nothing to react to.
    var theirMoves: [Move] { provocations + oneOfEachType }
    var theirPlays: [Play] {
        theirMoves.indices.map { Play(left: .attack(move: $0, target: 0), right: .pass) }
    }
    var theirPlayNames: [String] { theirMoves.map(\.name) }
    /// One attack per type, for the other side to throw.
    let oneOfEachType: [Move]
    /// For each attacking type, a type it is super effective against. A resist
    /// berry only halves a super-effective hit, and the bench's own typing made
    /// every one of them inert: Dark into a Psychic-and-Fighting Gallade comes
    /// out neutral, so a Colbur Berry had nothing to halve.
    let weakTo: [String: PokeType]

    /// The surest flinch there is, not merely the first one. A 30% chance never
    /// fires for an audit that does not roll dice, and Fake Out — the only
    /// certain one — states its flinch outright rather than as a chance.
    private static func surestFlinch(among legal: [Move]) -> Move? {
        func flinchChance(_ move: Move) -> Int {
            for effect in move.secondaries {
                if case .flinch = effect.kind { return effect.chance }
            }
            return move.effect.hasPrefix("Makes the target flinch") ? 100 : 0
        }
        return legal.filter { flinchChance($0) > 0 }
            .max { flinchChance($0) < flinchChance($1) }
    }

    init(rules: Rulebook) {
        self.rules = rules
        func move(_ name: String) -> Move? { rules.moves.values.first { $0.name == name } }

        // Only moves something in this format can actually learn. An audit of
        // Champions that probes with Bouncy Bubble is auditing a different game.
        let legal = rules.moves.values.filter(\.learnable).sorted { $0.name < $1.name }

        // A move of each type and category, preferring a plain one: the audit
        // wants the type to be the only thing that varies. The power band keeps
        // out every move whose damage does not come from its power.
        var byTypeAndKind: [String: Move] = [:]
        for candidate in legal
        where candidate.isDamaging && (60...120).contains(candidate.power)
            && candidate.accuracy >= 90 {
            guard let type = PokeType(loose: candidate.type) else { continue }
            let key = "\(type.rawValue)/\(candidate.category)"
            if byTypeAndKind[key] == nil { byTypeAndKind[key] = candidate }
        }
        typed = PokeType.allCases.flatMap { type in
            ["Physical", "Special"].compactMap { byTypeAndKind["\(type.rawValue)/\($0)"] }
        }
        var seenTypes = Set<String>()
        oneOfEachType = typed.filter { seenTypes.insert($0.type).inserted }
        var weak: [String: PokeType] = [:]
        for move in typed {
            guard weak[move.type] == nil, let attacking = PokeType(loose: move.type) else { continue }
            weak[move.type] = PokeType.allCases.first {
                TypeChart.multiplier(attacking, into: $0) > 1
            }
        }
        weakTo = weak.compactMapValues { $0 }
        probes = ([typed.first { $0.makesContact },
                   typed.first { $0.category == "Special" },
                   typed.first(where: \.isSpread),
                   typed.first]
            .compactMap { $0 })
        // Each picked for what it does, so a new release's moves slot in on
        // their own and a renamed one does not quietly disable a whole battery.
        let status = legal.filter { !$0.isDamaging }
        func first(_ test: (Move) -> Bool) -> Move? { status.first(where: test) }
        ourStatus = [first { !$0.rules.targetDrops.isEmpty },
                     first { !$0.rules.selfBoosts.isEmpty },
                     first { $0.isSound },
                     // A screen, so a rule about how long screens last has one.
                     first { $0.name == "Reflect" || $0.name == "Light Screen" }]
            .compactMap { $0 }
        provocations = [
            legal.first { $0.makesContact && $0.isDamaging && $0.accuracy >= 95 },
            first { !$0.rules.targetDrops.isEmpty },
            first { $0.effect.hasPrefix("Burns the target") },
            first { $0.effect.hasPrefix("Paralyzes the target") },
            // The surest flinch there is, not merely the first one. A 30%
            // chance never fires for an audit that does not roll dice, and
            // Fake Out — the only certain one — states its flinch outright
            // rather than as a chance, so it is not a parsed secondary at all.
            Self.surestFlinch(among: legal),
            first { $0.rules.confuses },
            first { $0.name == "Protect" },
            first { $0.name == "Follow Me" || $0.name == "Rage Powder" },
        ].compactMap { $0 }

        let versatile = rules.forms.max { $0.moves.count < $1.moves.count }?.formLabel ?? ""
        func team(_ rows: [(String, [Move])]) -> Team {
            var out = Team(); out.format = "doubles"
            out.slots = rows.compactMap { name, moves in
                guard let form = rules.forms.first(where: { $0.formLabel == name }) else { return nil }
                var slot = TeamSlot(formID: form.id)
                slot.ability = form.abilities.first?.name ?? ""
                // Holding something, because several rules are about losing it.
                // With empty hands Unburden has nothing to spend and Symbiosis
                // nothing to pass, and both read as missing.
                slot.item = "Sitrus Berry"
                slot.moves = moves.map(\.id)
                var sp = Array(repeating: 0, count: 6)
                sp[Stat.attack.rawValue] = 32; sp[Stat.speed.rawValue] = 32; sp[Stat.hp.rawValue] = 2
                slot.sp = sp; slot.alignmentName = "Adamant"
                return slot
            }
            return out
        }
        let partner = rules.forms.first { $0.formLabel == "Milotic" }?.formLabel ?? versatile
        let bench = rules.forms.first { $0.formLabel == "Whimsicott" }?.formLabel ?? versatile
        // A Dark type on the other side, because several rules turn on one.
        let dark = rules.forms.first { $0.formLabel == "Kingambit" }?.formLabel ?? versatile
        let ordinary = rules.forms.first { $0.formLabel == "Garchomp" }?.formLabel ?? versatile
        mine = team([(versatile, probes + ourStatus + typed),
                     (partner, provocations), (bench, typed)])
        // mine[0].moves opens with `acting`, so a Play's move index lines up.
        let thrown = provocations + oneOfEachType
        theirs = team([(ordinary, thrown), (dark, thrown)])
    }

    private func board() -> Board {
        var out = Board(mine: mine, theirs: theirs, rules: rules,
                        field: Field(isDoubles: true), alreadyEvolved: false)
        // Dented, so healing has somewhere to go, and with a berry's worth of
        // room so a berry can be eaten.
        out.mine[0].hp = out.mine[0].maxHP / 2
        out.mine[1].hp = out.mine[1].maxHP / 2
        out.theirs[0].hp = out.theirs[0].maxHP / 2
        return out
    }

    /// Everything a rule could change about a board, as one string.
    ///
    /// `traits` is the ability and the item themselves. A move that swaps them
    /// — Trick, Skill Swap — has to be seen to do it, so the move battery
    /// counts them; the ability and item batteries must not, because there the
    /// trait is the thing being varied and counting it would call every
    /// ability in the game implemented.
    private func fingerprint(_ b: Board, traits: Bool = true) -> String {
        var out = ""
        for side in [b.mine, b.theirs] {
            for f in side {
                out += "\(f.hp)/\(f.status.rawValue)/\(f.build.boosts)/\(f.confusedFor)/\(f.isProtected)"
                out += "/\(f.flinched)/\(f.charging ?? -1)/\(f.encoredFor)/\(f.tauntedFor)/\(f.hidden)"
                out += "/\(f.drawingFire)/\(f.build.itemSpent)"
                if traits { out += "/\(f.build.item)/\(f.build.ability)" }
                out += "/\(f.seededFrom ?? -1)/\(f.critStage)/\(f.build.form.id)"
                out += "/\(f.substitute)/\(f.infatuatedWith ?? -1)/\(f.tormented)/\(f.cannotEscape)"
                out += "/\(f.aquaRing)/\(f.stockpile)/\(f.goesNext)/\(f.charged)"
                out += "/\(f.build.typeOverride ?? [])"
                out += "/\((f.build.statOverride ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" })"
                out += "/\(f.asleepFor)/\(f.protectStreak)/\(f.lastMoveFailed)/\(f.seen)"
                out += "/\(f.build.status.rawValue)|"
            }
        }
        out += "\(b.field.weather)\(b.field.terrain)\(b.myTailwind)\(b.theirTailwind)\(b.trickRoom)"
        out += "\(b.magicRoom)\(b.wonderRoom)\(b.weatherTurns)\(b.terrainTurns)"
        for side in [b.myScreens, b.theirScreens] {
            out += "/\(side.reflect)/\(side.lightScreen)/\(side.auroraVeil)"
            out += "/\(side.wideGuard)/\(side.quickGuard)/\(side.safeguard)"
            out += "/\(side.spikes)/\(side.toxicSpikes)/\(side.stealthRock)"
            out += "/\(side.wishAmount)/\(side.wishTurns)"
        }
        return out
    }

    private func outcome(_ b: Board, mine play: Play, theirs answer: Play,
                         traits: Bool = true) -> String {
        let after = TurnModel.resolve(b, mine: play, theirs: answer, rolling: false)
        return fingerprint(after, traits: traits) + "||" + after.story.joined(separator: "¶")
    }

    // MARK: Moves

    func reactsTo(move: Move) -> Bool {
        var b = board()
        b.mine[0].moves = [move] + b.mine[0].moves
        // Someone down on the bench, for the moves that bring one back.
        var fallen = b
        if fallen.mine.count > 2 { fallen.mine[2].hp = 0 }
        // Asleep, for the moves that only work then.
        var sleeping = b
        sleeping.mine[0].status = .sleep
        sleeping.mine[0].asleepFor = 3
        // On one health point, so the next hit is lethal. Endure and Focus
        // Sash exist only for this moment and are invisible without it.
        var doomed = b
        doomed.mine[0].hp = 1
        doomed.mine[1].hp = 1

        let using = Play(left: .attack(move: 0, target: 0), right: .pass)
        let passing = Play(left: .pass, right: .pass)
        // Their answers: nothing, a single-target attack, a Protect, and a
        // spread move — without that last one Wide Guard has nothing to turn
        // away and reads as missing.
        let spread = theirMoves.firstIndex(where: \.isSpread)
        let answers = [Play(left: .pass, right: .pass),
                       Play(left: .attack(move: 0, target: 0), right: .pass),
                       Play(left: .protectSelf(move: provocations.count - 1), right: .pass)]
            + (spread.map { [Play(left: .attack(move: $0, target: 0), right: .pass)] } ?? [])
        for position in [b, fallen, sleeping, doomed] {
            for answer in answers {
                // The same turn twice: once using it, once not. Anything the
                // move did is the difference between them, and nothing the
                // other side did can be mistaken for it.
                let used = TurnModel.resolve(position, mine: using, theirs: answer, rolling: false)
                let skipped = TurnModel.resolve(position, mine: passing, theirs: answer, rolling: false)
                if fingerprint(used) != fingerprint(skipped) { return true }
            }
        }
        return false
    }

    /// Play the same turns with and without the thing, in every situation it
    /// could matter, and see whether any of them come out differently.
    ///
    /// The situations are the ones a rule can hide in: every weather and
    /// terrain, every type of attack in both directions, health at full, at
    /// half and on one point, an item already spent, screens in the air, and a
    /// provocation from the other side — a stat drop, a burn, a flinch, a
    /// confusion. A rule that answers none of those is one the model does not
    /// have.
    /// `baseline` strips the trait being tested off the reference side — the
    /// experiment is the rule against *nothing*, not against whatever the
    /// bench Pokémon happened to be born with. Getting that wrong made every
    /// ability in the game read as implemented, which is what the control is
    /// there to catch.
    /// Returns the name of the first situation that came out differently, or
    /// nil if none of them did. Naming it rather than returning a bare yes lets
    /// the report say what evidence it found, and lets the control say what
    /// went wrong when it fails.
    private func firstDifference(_ baseline: (inout Combatant) -> Void,
                                 _ change: (inout Combatant) -> Void) -> String? {
        let idle = Play(left: .pass, right: .pass)

        // The arithmetic first: it is much the cheapest, and it catches every
        // rule that only changes a number.
        var reference = board()
        baseline(&reference.mine[0].build)
        var altered = reference.mine[0].build
        change(&altered)
        for weather in [Weather.none, .rain, .sun, .sand, .snow] {
            for terrain in [Terrain.none, .grassy, .electric, .psychic, .misty] {
                var field = reference.field
                field.weather = weather; field.terrain = terrain
                // Once more with the holder weak to the move, which is the
                // only condition a resist berry fires under.
                for move in typed {
                    guard let weak = weakTo[move.type] else { continue }
                    var plainWeak = reference.mine[0].build, alteredWeak = altered
                    plainWeak.typeOverride = [weak]; alteredWeak.typeOverride = [weak]
                    let them = reference.theirs[0].build
                    if DamageCalc.calculate(attacker: them, defender: plainWeak, move: move, field: field).maxDamage
                        != DamageCalc.calculate(attacker: them, defender: alteredWeak, move: move, field: field).maxDamage {
                        return "damage taken from a super-effective \(move.name)"
                    }
                }
                for move in typed {
                    // Health, a graveyard and a failed move: three states a
                    // damage rule can turn on that a fresh board never has.
                    // Supreme Overlord counts the fallen and was invisible
                    // without the second of them.
                    for state in [(low: false, fallen: 0, failed: false),
                                  (low: true, fallen: 0, failed: false),
                                  (low: false, fallen: 2, failed: false),
                                  (low: false, fallen: 0, failed: true)] {
                        let low = state.low
                        var plainOne = reference.mine[0].build, alteredOne = altered
                        plainOne.lowHP = low; alteredOne.lowHP = low
                        plainOne.atFullHP = !low; alteredOne.atFullHP = !low
                        plainOne.fallenAllies = state.fallen; alteredOne.fallenAllies = state.fallen
                        plainOne.lastMoveFailed = state.failed; alteredOne.lastMoveFailed = state.failed
                        let them = reference.theirs[0].build
                        if DamageCalc.calculate(attacker: plainOne, defender: them, move: move, field: field).maxDamage
                            != DamageCalc.calculate(attacker: alteredOne, defender: them, move: move, field: field).maxDamage { return "damage dealt, \(move.name) in \(weather)/\(terrain)" }
                        if DamageCalc.calculate(attacker: them, defender: plainOne, move: move, field: field).maxDamage
                            != DamageCalc.calculate(attacker: them, defender: alteredOne, move: move, field: field).maxDamage { return "damage taken, \(move.name) in \(weather)/\(terrain)" }
                    }
                }
                var spent = reference.mine[0].build, spentAltered = altered
                spent.itemSpent = true; spentAltered.itemSpent = true
                if spent.speed(in: field) != spentAltered.speed(in: field) { return "speed with the item spent, in \(weather)/\(terrain)" }
                if reference.mine[0].build.speed(in: field) != altered.speed(in: field) { return "speed in \(weather)/\(terrain)" }
            }
        }

        // Then the turns, in two passes. Crossing every situation with every
        // field would be nine times the work for almost nothing, because the
        // arithmetic above already swept weather and terrain for anything that
        // changes a number. So: every situation on a neutral field, then the
        // fields against a small set of situations.
        // The two cheapest telling plays, reused for both field sweeps.
        let fieldPlays: [Play] = [idle] + acting.indices.prefix(2).map {
            Play(left: .attack(move: $0, target: 0), right: .pass)
        }
        func staged(_ shape: Shape, _ weather: Weather, _ terrain: Terrain) -> (Board, Board)? {
            var plain = board()
            baseline(&plain.mine[0].build)
            plain.field.weather = weather; plain.field.terrain = terrain
            plain.weatherTurns = weather == .none ? 0 : 5
            plain.terrainTurns = terrain == .none ? 0 : 5
            var one = shape.applied(to: plain)
            var two = one
            change(&two.mine[0].build)
            one.sendOutLeads(); two.sendOutLeads()
            if fingerprint(one, traits: false) != fingerprint(two, traits: false)
                || one.story != two.story { return nil }
            return (one, two)
        }

        for shape in Shape.allCases {
            guard let (one, two) = staged(shape, .none, .none) else {
                return "on entry, \(shape)"
            }
            // Their partner drawing fire, so a rule about ignoring redirection
            // has something to ignore.
            let redirect = theirMoves.firstIndex { $0.name == "Follow Me" || $0.name == "Rage Powder" }
            let withRedirect = redirect.map {
                [Play(left: .pass, right: .attack(move: $0, target: 0))]
            } ?? []
            for (index, answer) in (theirPlays + withRedirect).enumerated() {
                for (probe, probeMove) in ([nil] + acting.indices.map { $0 }).enumerated() {
                    _ = probe
                    let ours = probeMove.map { Play(left: .attack(move: $0, target: 0), right: .pass) }
                        ?? idle
                    if outcome(one, mine: ours, theirs: answer, traits: false)
                        != outcome(two, mine: ours, theirs: answer, traits: false) {
                        let what = probeMove.map { "using \(acting[$0].name)" } ?? "waiting"
                        let against = index < theirPlayNames.count
                            ? theirPlayNames[index] : "a partner drawing fire"
                        return "\(what) into \(against), \(shape)"
                    }
                }
            }
            // A second turn on the back of the first. Cud Chew brings its berry
            // up at the end of the turn *after* it ate it, Harvest and Speed
            // Boost compound, and a single turn can see none of that.
            if shape == .aboutToEatABerry || shape == .healthy {
                for answer in [idle, theirPlays[0]] {
                    let oneAfter = TurnModel.resolve(one, mine: idle, theirs: answer, rolling: false)
                    let twoAfter = TurnModel.resolve(two, mine: idle, theirs: answer, rolling: false)
                    if outcome(oneAfter, mine: idle, theirs: answer, traits: false)
                        != outcome(twoAfter, mine: idle, theirs: answer, traits: false) {
                        return "over two turns, \(shape)"
                    }
                }
            }

            // Walking out, which is the whole of Regenerator and Natural Cure.
            if one.mine.count > 2 {
                let away = Play(left: .swap(to: 2), right: .pass)
                for answer in [idle, theirPlays[0]] {
                    if outcome(one, mine: away, theirs: answer, traits: false)
                        != outcome(two, mine: away, theirs: answer, traits: false) {
                        return "switching out, \(shape)"
                    }
                }
            }
        }

        // And the fields, against the situations most likely to hide a
        // weather or terrain rule.
        for weather in [Weather.rain, .sun, .sand, .snow] where true {
            guard let (one, two) = staged(.dented, weather, .none) else {
                return "on entry in \(weather)"
            }
            for answer in [idle] + theirPlays.prefix(provocations.count) {
                for ours in fieldPlays {
                    if outcome(one, mine: ours, theirs: answer, traits: false)
                        != outcome(two, mine: ours, theirs: answer, traits: false) {
                        return "a turn in \(weather)"
                    }
                }
            }
        }
        for terrain in [Terrain.grassy, .electric, .psychic, .misty] {
            guard let (one, two) = staged(.dented, .none, terrain) else {
                return "on entry in \(terrain)"
            }
            for answer in [idle] + theirPlays.prefix(provocations.count) {
                for ours in fieldPlays {
                    if outcome(one, mine: ours, theirs: answer, traits: false)
                        != outcome(two, mine: ours, theirs: answer, traits: false) {
                        return "a turn on \(terrain) terrain"
                    }
                }
            }
        }
        return nil
    }

    /// The shapes a position can be in, beyond the field: what a rule might be
    /// waiting for.
    private enum Shape: CaseIterable {
        case healthy, dented, onOnePoint, targetOnOnePoint, itemSpent, screensUp
        case alliesFallen, aboutToEatABerry, foeHoldingABerry, alreadyBurned
        case grassOnThisSide, tongueTied

        func applied(to board: Board) -> Board {
            var out = board
            switch self {
            case .healthy: break
            case .dented:
                out.mine[0].hp = out.mine[0].maxHP * 3 / 5
            case .onOnePoint:
                out.mine[0].hp = 1
            case .targetOnOnePoint:
                out.theirs[0].hp = 1
            case .itemSpent:
                // Whatever it is holding, already used up: what Unburden and
                // Symbiosis are waiting for. The item itself is not replaced,
                // because for the item battery it is the thing being tested.
                out.mine[0].build.itemSpent = true
                out.mine[1].build.item = "Leftovers"
            case .screensUp:
                out.theirScreens.reflect = 5
                out.theirScreens.lightScreen = 5
            case .alliesFallen:
                // Supreme Overlord and Last Respects count the graveyard.
                out.mine[0].build.fallenAllies = 2
            case .aboutToEatABerry:
                // Low enough that a pinch berry fires this turn, which is the
                // one moment Unburden, Cud Chew, Ripen and Cheek Pouch exist
                // for. The ally holds one too, for Symbiosis to hand over.
                out.mine[0].hp = max(1, out.mine[0].maxHP / 5)
                out.mine[1].build.item = "Sitrus Berry"
            case .foeHoldingABerry:
                // Unnerve stops the other side eating; it needs something to
                // stop.
                out.theirs[0].build.item = "Sitrus Berry"
                out.theirs[0].hp = max(1, out.theirs[0].maxHP / 5)
            case .alreadyBurned:
                out.mine[0].status = .burn
            case .tongueTied:
                // Taunted and held to its last move: what a Mental Herb is for.
                out.mine[0].tauntedFor = 3
                out.mine[0].encoredFor = 3
            case .grassOnThisSide:
                // Flower Veil only covers Grass types, and the bench has none,
                // so the rule had nobody to protect.
                out.mine[0].build.typeOverride = [.grass]
                out.mine[1].build.typeOverride = [.grass]
            }
            return out
        }
    }

    func evidence(ability: String) -> String? {
        firstDifference({ $0.ability = "" }, { $0.ability = ability })
    }

    func evidence(item: String) -> String? {
        // Only the item itself changes. Clearing `itemSpent` here would undo
        // the spent-item shape and make that flag the difference, which is
        // what the control caught.
        firstDifference({ $0.item = "" }, { $0.item = item })
    }
}
