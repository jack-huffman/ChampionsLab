//  tools/snapshot/main.swift
//  Render the main screens to PNG without launching the app.
//
//  Compiled against every app source except ChampionsLab.swift, whose @main
//  would collide with this one. Useful for eyeballing layout changes and for
//  checking the dark and light palettes actually both work.

import AppKit
import SwiftUI

// ImageRenderer cannot draw what the app draws, and it is worth knowing why
// before reaching for a shot to debug a layout. Two things it will not do:
// lazy content inside a ScrollView never materialises, so every list comes out
// empty; and AppKit-backed containers — NavigationSplitView, a Picker, a
// Toggle — come out as a yellow placeholder. That is what snapshotMode is for:
// the screens swap their ScrollView for a plain stack so a shot can show the
// whole list. A question about the real window has to be asked of the real
// window.
@MainActor
func render<V: View>(_ view: V, named name: String, size: CGSize, dark: Bool) {
    let host = view
        .environmentObject(Store.shared)
        .environment(\.snapshotMode, true)
        .frame(width: size.width, height: size.height)
        .background(Palette.canvas)
        .environment(\.colorScheme, dark ? .dark : .light)

    let renderer = ImageRenderer(content: host)
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("  ! could not render \(name)")
        return
    }
    let out = URL(fileURLWithPath: "build/shots/\(name).png")
    try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? png.write(to: out)
    print("  wrote \(out.path)")
}

/// A stand-in report, so the results layout can be checked without spending a
/// minute running the real audit.
func sampleParity() -> ParityAudit.Report {
    typealias F = ParityAudit.Finding
    return ParityAudit.Report(findings: [
        F(kind: .move, name: "Worry Seed", verdict: .noEffect,
          detail: "Changes the target's Ability to Insomnia.", usage: 37.1),
        F(kind: .move, name: "Switcheroo", verdict: .noEffect,
          detail: "The user and the target swap their held items.", usage: 37.0),
        F(kind: .move, name: "Thunderbolt", verdict: .byRule,
          detail: "Has a 10% chance of paralyzing the target.", usage: 29.7),
        F(kind: .move, name: "Protect", verdict: .implemented,
          detail: "Protects the user from most attacks for the turn.", usage: 71.4),
        F(kind: .move, name: "Sleep Talk", verdict: .notModelled,
          detail: "Calls another move at random; the search cannot price a move that becomes a different move.",
          usage: 4.2),
        F(kind: .ability, name: "Intimidate", verdict: .implemented,
          detail: "Changes the game: on entry, healthy.", usage: 41.0),
        F(kind: .ability, name: "Unburden", verdict: .noEffect, detail: "", usage: 37.0),
        F(kind: .item, name: "Rocky Helmet", verdict: .implemented,
          detail: "Damages the attacker on contact.", usage: 0),
        F(kind: .item, name: "Quick Claw", verdict: .noEffect,
          detail: "Sometimes lets the holder move first.", usage: 0),
    ], seconds: 68)
}

@MainActor
func renderAll() {
    let appearance = NSAppearance(named: .darkAqua)
    NSApplication.shared.appearance = appearance

    let store = Store.shared
    if let error = store.loadError {
        print("dataset error: \(error)")
        exit(1)
    }
    print("dataset: \(store.data.forms.count) forms")

    // A representative anti-meta team so the analysis screens have real content.
    var team = Team(name: "Terrain Control", format: "doubles")
    let picks = ["Rillaboom", "Mega Golisopod", "Incineroar", "Indeedee (Female)",
                 "Garchomp", "Gholdengo"]
    for label in picks {
        guard let form = store.form(named: label) else {
            print("  (missing \(label))")
            continue
        }
        var slot = TeamSlot(formID: form.id)
        slot.ability = form.abilities.first?.name ?? ""
        slot.sp = [12, 32, 0, 0, 0, 22]
        slot.moves = Array(store.moves(for: form).filter(\.isDamaging).prefix(3).map(\.id))
        team.slots.append(slot)
    }
    switch team.slots.count {
    case 0: print("  ! no team slots built")
    default: print("  team has \(team.slots.count) members")
    }
    team.slots.indices.forEach { index in
        team.slots[index].item = ["Terrain Extender", "Rocky Helmet", "Assault Vest",
                                  "Psychic Seed", "Choice Scarf", "Covert Cloak"][index]
    }

    render(OverviewView(), named: "overview-dark",
           size: CGSize(width: 1180, height: 2900), dark: true)
    render(OverviewView(), named: "overview-light",
           size: CGSize(width: 1180, height: 2900), dark: false)
    render(TeamReportView(team: team, onAdd: { _ in }), named: "analysis-dark",
           size: CGSize(width: 1000, height: 5200), dark: true)
    render(TeamReportView(team: team, onAdd: { _ in }), named: "analysis-light",
           size: CGSize(width: 1000, height: 2300), dark: false)
    // Versus screen against the Big Six, with a real opposing list.
    // A saved team as it opens: locked, read-only, no pickers.
    if let saved = store.teams.first(where: { $0.slots.count == 6 }) {
        var shown = saved
        shown.locked = true
        render(TeamEditorPreview(team: shown), named: "team-locked-dark",
               size: CGSize(width: 1000, height: 1700), dark: true)
        var editable = saved
        editable.locked = false
        render(TeamEditorPreview(team: editable), named: "team-editing-dark",
               size: CGSize(width: 1180, height: 2400), dark: true)
    }
    if let saved = store.teams.first(where: { $0.slots.count == 6 }) {
        render(AdvisorView(team: saved, onAdd: { _ in }), named: "assist-dark",
               size: CGSize(width: 1000, height: 2600), dark: true)
    }
let builderSeed = store.form(named: "Mega Baxcalibur")
    let builderPicks = Forecast(store: store, format: "doubles").picks(limit: 400)
    let generated = builderSeed.map {
        TeamBuilder(store: store).blueprints(seed: $0, picks: builderPicks)
    } ?? []
    render(BuilderView(preGenerated: generated, seedID: builderSeed?.id ?? ""),
           named: "builder-dark",
           size: CGSize(width: 1180, height: 900), dark: true)
    render(GuidedBuilderView(seedID: .constant(""), format: .constant("doubles")) { _ in },
           named: "guided-choose-dark",
           size: CGSize(width: 1100, height: 1500), dark: true)
    if let goli = store.data.forms.first(where: { $0.formLabel == "Mega Golisopod" }) {
        render(GuidedBuilderView(seedID: .constant(goli.id), format: .constant("doubles"),
                                 initialStage: .briefing) { _ in },
               named: "guided-brief-dark",
               size: CGSize(width: 1000, height: 800), dark: true)
        render(GuidedBuilderView(seedID: .constant(goli.id), format: .constant("doubles"),
                                 initialStage: .interview) { _ in },
               named: "guided-interview-dark",
               size: CGSize(width: 1000, height: 900), dark: true)
    }
    render(ZStack {
               Color.clear.frame(width: 700, height: 420)
               ProcessingOverlay(title: "Building teams",
                                 step: "Searching the Trick Room plan",
                                 fraction: 0.5) {}
           },
           named: "overlay-dark", size: CGSize(width: 700, height: 420), dark: true)
    // The Parity screen as it opens. The finished state needs a full audit,
    // which is a minute of work and far too slow to put in a snapshot run.
    render(ParityView(), named: "parity-dark",
           size: CGSize(width: 1180, height: 780), dark: true)
    render(ParityView(), named: "parity-light",
           size: CGSize(width: 1180, height: 780), dark: false)
    render(ParityView(preloaded: sampleParity()), named: "parity-results-dark",
           size: CGSize(width: 1180, height: 820), dark: true)

    render(ForecastView(), named: "forecast-top-dark",
           size: CGSize(width: 1180, height: 1150), dark: true)
    render(ForecastView(), named: "forecast-dark",
           size: CGSize(width: 1180, height: 4200), dark: true)
    render(MatchupView(team: team, initialOpponent: "big-six"), named: "versus-dark",
           size: CGSize(width: 1180, height: 2400), dark: true)
    // The calculator as it opens from a team slot's ƒ button.
    if let saved = store.teams.first(where: { $0.name == "Sun / Dual Mega" }),
       let zard = saved.slots.first(where: { $0.form(in: store.rulebook)?.name == "Charizard" }),
       let target = store.form(named: "Garchomp") {
        render(CalculatorView(preload: CalculatorPreload(slot: zard, rules: store.rulebook),
                              initialDefender: target.id),
               named: "calc-preloaded-dark",
               size: CGSize(width: 1180, height: 1200), dark: true)
    }
    render(CalculatorView(
            initialAttacker: store.form(named: "Mega Baxcalibur")?.id,
            initialDefender: store.form(named: "Incineroar")?.id,
            initialMove: store.data.moves.values.first { $0.name == "Glaive Rush" }?.id),
           named: "calc-dark",
           size: CGSize(width: 1180, height: 1100), dark: true)
    if let form = store.form(named: "Mega Golisopod") {
        render(FormDetail(form: form), named: "dex-detail-dark",
               size: CGSize(width: 620, height: 2400), dark: true)
    }
    if let playing = store.teams.first(where: { $0.slots.count >= 4 }),
       let against = store.data.metaTeams.first(where: { $0.name == "Big Six" }) {
        let theirs = store.opponentTeam(against)
        // Team Preview, with a four already chosen so the ordering shows.
        let grid = Matchup(mine: playing, theirs: theirs, rules: store.rulebook,
                           field: Field(isDoubles: true))
        let chosen = BringFour(matchup: grid, rules: store.rulebook).plans.first?.bring
            .compactMap { form in
                playing.slots.first { $0.battleForm(in: store.rulebook)?.id == form.id }?.formID
            } ?? []
        render(BattleView(openTeams: (mine: playing.id.uuidString, theirs: against.id),
                          previewing: chosen),
               named: "battle-preview-dark",
               size: CGSize(width: 1280, height: 860), dark: true)
        // Choosing the teams, with yours chosen and theirs still open.
        render(BattleView(openTeams: (mine: playing.id.uuidString, theirs: ""), arriving: .setup),
               named: "battle-setup-dark",
               size: CGSize(width: 1180, height: 760), dark: true)
        // And the two sixes facing each other.
        render(BattleView(openTeams: (mine: playing.id.uuidString, theirs: against.id),
                          arriving: .versus),
               named: "battle-versus-dark",
               size: CGSize(width: 1180, height: 860), dark: true)

        // And the field itself, a turn in. Lead with something holding a
        // stone, so the Mega Evolve toggle shows.
        var order = chosen
        let stone = playing.slots.first { $0.megaEvolution(in: store.rulebook) != nil }?.formID
        if let stone {
            order.removeAll { $0 == stone }
            order.insert(stone, at: 0)
            order = Array(order.prefix(4))
        }
        var board = Board.opening(mine: playing, bringing: order, theirs: theirs,
                                  rules: store.rulebook, singles: false)
        // Weather and terrain with their clocks running, so the field shows them.
        if board.field.weather == .none { board.field.weather = .rain; board.weatherTurns = 4 }
        if board.field.terrain == .none { board.field.terrain = .grassy; board.terrainTurns = 3 }
        // And stages on both sides, so the cards show what they carry.
        board.mine[0].build.boosts[Stat.spAttack.rawValue] = 2
        board.mine[1].build.boosts[Stat.defense.rawValue] = -2
        board.mine[1].build.boosts[Stat.speed.rawValue] = 1
        // theirs[0] deliberately carries nothing: no stat change, no condition.
        // That is the case the fixture used to miss, and the one that was
        // broken — a card with an empty stat column wore a black sheet. Leave
        // it bare so the shot keeps checking it.
        board.theirs[1].status = .burn
        // A real turn played out, so the log shows its reasons nested under
        // the thing they explain rather than as a column of equal boxes.
        let exchanged = TurnModel.resolve(
            board,
            mine: Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 0)),
            theirs: Play(left: .attack(move: 0, target: 0), right: .attack(move: 0, target: 0)),
            rolling: true)
        render(BattleView(playing: exchanged, logging: exchanged.story),
               named: "battle-log-dark",
               size: CGSize(width: 1180, height: 900), dark: true)
        // One of each side protecting, and a substitute up, so the sprite
        // markings show. Both are things you have to know before choosing a
        // move and were only readable out of the log.
        var guarded = board
        guarded.mine[1].isProtected = true
        guarded.theirs[0].isProtected = true
        guarded.theirs[1].substitute = 40
        render(BattleView(playing: guarded), named: "battle-protect-dark",
               size: CGSize(width: 1180, height: 900), dark: true)
        render(BattleView(playing: board), named: "battle-dark",
               size: CGSize(width: 1280, height: 860), dark: true)
        // And the Fight grid, which is what most turns are spent looking at.
        // With the engine's answer already in, so its badges show on the tiles.
        let engine = BattleEngine(rules: store.rulebook, nodes: BattleEngine.Nodes.screen)
        let thought = engine.think(board)
        var game = TurnGame(board: board)
        game.width = engine.beam + 2
        // A game a few turns in, marked: what each turn was worth against the
        // mix they were playing, and the line the engine wanted instead.
        var marked = TurnGame(board: board, believingTheirs: true)
        marked.width = 8
        let solvedTurn = marked.solve()
        let played = solvedTurn.myPlays.indices.contains(3) ? solvedTurn.myPlays[3] : solvedTurn.myPlays[0]
        let wanted = solvedTurn.lines.first
        render(BattleView(playing: board, showing: .menu, reviewing: [
            BattleView.TurnReview(turn: 1, yours: marked.describe(played, mine: true),
                                  theirs: marked.describe(solvedTurn.theirPlays[0], mine: false),
                                  played: -0.18, best: -0.02,
                                  bestLine: wanted.map { marked.describe($0.play, mine: true) } ?? "—",
                                  before: board, minePlay: played,
                                  theirPlay: solvedTurn.theirPlays[0],
                                  told: TurnModel.resolve(board, mine: played,
                                                          theirs: solvedTurn.theirPlays[0]).story),
            BattleView.TurnReview(turn: 2, yours: marked.describe(solvedTurn.myPlays[0], mine: true),
                                  theirs: marked.describe(solvedTurn.theirPlays[0], mine: false),
                                  played: 0.31, best: 0.31,
                                  bestLine: marked.describe(solvedTurn.myPlays[0], mine: true),
                                  before: board, minePlay: solvedTurn.myPlays[0],
                                  theirPlay: solvedTurn.theirPlays[0],
                                  told: TurnModel.resolve(board, mine: solvedTurn.myPlays[0],
                                                          theirs: solvedTurn.theirPlays[0]).story),
        ], thinking: (thought, solvedTurn)),
               named: "battle-review-dark",
               size: CGSize(width: 1280, height: 860), dark: true)
        render(BattleView(playing: board, showing: .fight, thinking: (thought, game.solve())),
               named: "battle-fight-dark",
               size: CGSize(width: 1280, height: 860), dark: true)
        // And choosing where a move goes.
        render(BattleView(playing: board, showing: .aiming(move: 1), thinking: (thought, game.solve())),
               named: "battle-aim-dark",
               size: CGSize(width: 1280, height: 860), dark: true)
    }
    // The turn explainer, on a turn that was actually resolved.
    if let board = store.teams.first(where: { $0.slots.count >= 4 }).flatMap({ mine -> Board? in
        guard let meta = store.data.metaTeams.first(where: { $0.name == "Big Six" }) else { return nil }
        return Board(mine: mine, theirs: store.opponentTeam(meta), rules: store.rulebook,
                     field: Field(isDoubles: true), alreadyEvolved: false)
    }) {
        var solver = TurnGame(board: board, believingTheirs: true)
        solver.width = 8
        let solution = solver.solve()
        let ours = solution.myPlays.indices.contains(3) ? solution.myPlays[3] : solution.myPlays[0]
        let theirs = solution.theirPlays[0]
        let explained = BattleView.TurnReview(
            turn: 1, yours: solver.describe(ours, mine: true),
            theirs: solver.describe(theirs, mine: false),
            played: -0.18, best: -0.02,
            bestLine: solution.lines.first.map { solver.describe($0.play, mine: true) } ?? "—",
            before: board, minePlay: ours, theirPlay: theirs,
            told: TurnModel.resolve(board, mine: ours, theirs: theirs).story)
        render(TurnExplainer(review: explained, rules: store.rulebook) {},
               named: "battle-explain-dark",
               size: CGSize(width: 620, height: 1500), dark: true)
    }

    // The move effects, laid out side by side at the moment each reads best.
    // The real ones happen over four tenths of a second inside a battle, which
    // is not a thing a still can catch, so this puts them on a grid instead.
    render(EffectSheet(), named: "battle-effects-dark", size: CGSize(width: 1100, height: 760), dark: true)
    render(WeatherSheet(), named: "battle-weather-dark", size: CGSize(width: 1100, height: 700), dark: true)


    // The Simulate tab, with a real run behind it. Small, because the shot is
    // about whether the findings read clearly, not about the numbers.
    if let playing = store.teams.first(where: { $0.slots.count >= 4 }) {
        var planner = SpreadPlanner(store: store)
        planner.field = Field(isDoubles: true)
        let field = SelfPlay.teams(from: store.data, rules: store.rulebook, planner: planner)
        let found = TeamLab.run(team: playing, against: field, rules: store.rulebook,
                                games: 60, nodes: BattleEngine.Nodes.turn)
        // Two earlier versions, invented, so the history card has something to
        // draw. In memory only — nothing here writes to simulations.json.
        var older = found
        older.wins = Int(Double(found.games) * 0.41)
        var oldest = found
        oldest.wins = Int(Double(found.games) * 0.37)
        var wasSlots = LabStore.slotLines(of: playing)
        if var first = wasSlots.first {
            first = first.replacingOccurrences(of: "|", with: "|X", options: [],
                                               range: first.range(of: "|"))
            wasSlots[0] = first
        }
        store.simulations[playing.id.uuidString] = [
            LabStore.Entry(teamID: playing.id.uuidString,
                           stamp: LabStore.stamp(of: playing), ran: Date(),
                           report: found, slots: LabStore.slotLines(of: playing)),
            LabStore.Entry(teamID: playing.id.uuidString, stamp: "was-1",
                           ran: Date().addingTimeInterval(-86_400),
                           report: older, slots: wasSlots),
            LabStore.Entry(teamID: playing.id.uuidString, stamp: "was-2",
                           ran: Date().addingTimeInterval(-3 * 86_400),
                           report: oldest, slots: Array(wasSlots.dropLast())),
        ]
        // The member sheet, which is where the depth went.
        if let carrying = found.byTrade.first {
            render(MemberDetail(form: carrying.form, report: found, team: playing) {},
                   named: "team-member-dark",
                   size: CGSize(width: 560, height: 1500), dark: true)
        }
        render(SimulationView(team: playing, seeded: found), named: "team-simulate-dark",
               size: CGSize(width: 900, height: 1700), dark: true)
    }

    // The Lines tab, with a real walk behind it. Shallow and few playouts,
    // because the shot is about whether the findings read.
    if let playing = store.teams.first(where: { $0.slots.count >= 4 }),
       let against = store.data.metaTeams.first(where: { $0.name == "Big Six" }) {
        var mine = playing; mine.slots = Array(playing.slots.prefix(4))
        var theirs = store.opponentTeam(against)
        theirs.slots = Array(theirs.slots.prefix(4))
        let walked = MatchupTree.explore(mine: mine, theirs: theirs, rules: store.rulebook,
                                         depth: 2, playouts: 6, playoutNodes: BattleEngine.Nodes.turn, replay: 5)
        render(TreeView(team: playing, seeded: walked), named: "team-lines-dark",
               size: CGSize(width: 1000, height: 2000), dark: true)
    }

    render(SpeedTiersView(), named: "speed-dark",
           size: CGSize(width: 1000, height: 900), dark: true)
    let dexSample = Array(store.data.forms.sorted { $0.dex < $1.dex }.prefix(24))
    render(LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)],
                     spacing: 10) {
               ForEach(Array(dexSample.enumerated()), id: \.offset) { index, form in
                   DexTile(form: form, isSelected: index == 3)
               }
           }
           .padding(12),
           named: "dex-tiles-dark",
           size: CGSize(width: 900, height: 560), dark: true)
}

MainActor.assumeIsolated { renderAll() }


// MARK: - The effect layers, on a grid

/// Four seats, the way the arena lays them out.
@MainActor
/// A move's recipe placed on a demo arena, ready to draw at an instant.
private func choreography(_ move: String, size: CGSize) -> TurnPlayback.Scene? {
    let table = Choreography.shared
    guard let recipe = table.recipe(forMove: move) else { return nil }
    let stage = MoveTimeline.Stage(arena: size) { seat in
        Seat.point(seat, w: size.width, h: size.height, singles: true)
    }
    let timeline = MoveTimeline.build(recipe, attacker: Seat(mine: true, slot: 0),
                                      targets: [Seat(mine: false, slot: 0)],
                                      sizes: table.sprites, stage: stage)
    return TurnPlayback.Scene(timeline: timeline, startedAt: Date(), ghosts: [:])
}

@MainActor
private func demoPlace(_ size: CGSize) -> (Seat) -> CGPoint {
    { seat in
        let x: CGFloat = seat.mine ? (seat.slot == 0 ? 0.17 : 0.35) : (seat.slot == 0 ? 0.65 : 0.83)
        let y: CGFloat = seat.mine ? (seat.slot == 0 ? 0.40 : 0.64) : (seat.slot == 0 ? 0.36 : 0.60)
        return CGPoint(x: size.width * x, y: size.height * y)
    }
}

private struct EffectCell<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Palette.surfaceRaised.opacity(0.4))
                    // Markers where the four Pokémon would be standing.
                    ForEach([Seat(mine: true, slot: 0), Seat(mine: true, slot: 1),
                             Seat(mine: false, slot: 0), Seat(mine: false, slot: 1)], id: \.self) { seat in
                        let at = demoPlace(geo.size)(seat)
                        Circle().strokeBorder(Palette.dim.opacity(0.35), lineWidth: 1)
                            .frame(width: 30, height: 30).position(at)
                    }
                    content
                }
            }
        }
    }
}

private struct EffectSheet: View {
    private func shot(_ name: String, category: String, type: String,
                      targets: [Seat]) -> Flourish {
        Flourish(id: 0,
                 action: Board.Action(byMine: true, slot: 0, move: name,
                                      category: category, type: type),
                 targets: targets)
    }

    var body: some View {
        let one = [Seat(mine: false, slot: 0)]
        let both = [Seat(mine: false, slot: 0), Seat(mine: false, slot: 1)]
        return VStack(alignment: .leading, spacing: 14) {
            Text("What a move looks like")
                .font(.system(size: 18, weight: .bold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
                      spacing: 14) {
                ForEach([0.30, 0.58, 0.85], id: \.self) { at in
                    EffectCell("Special, one target — Flamethrower, \(Int(at * 100))%") {
                        GeometryReader { geo in
                            BeamLayer(flourish: shot("Flamethrower", category: "Special", type: "Fire",
                                                     targets: one),
                                      progress: at, place: demoPlace(geo.size))
                        }
                    }
                    .frame(height: 210)
                }
                ForEach([0.45, 0.70], id: \.self) { at in
                    EffectCell("Special, both — Surf, \(Int(at * 100))%") {
                        GeometryReader { geo in
                            BeamLayer(flourish: shot("Surf", category: "Special", type: "Water",
                                                     targets: both),
                                      progress: at, place: demoPlace(geo.size))
                        }
                    }
                    .frame(height: 210)
                }
                ForEach([("Flamethrower", 0.35), ("Tackle", 0.45), ("Follow Me", 0.5)], id: \.0) { name, at in
                    EffectCell("Choreography — \(name), \(String(format: "%.2fs", at))") {
                        GeometryReader { geo in
                            if let scene = choreography(name, size: geo.size) {
                                ChoreographyLayer(scene: scene, at: at)
                            }
                        }
                    }
                    .frame(height: 210)
                }
                EffectCell("Special, missed — Thunder, 70%") {
                    GeometryReader { geo in
                        BeamLayer(flourish: shot("Thunder", category: "Special", type: "Electric",
                                                 targets: []),
                                  progress: 0.70, place: demoPlace(geo.size))
                    }
                }
                .frame(height: 210)
                ForEach([0.55, 0.80], id: \.self) { at in
                    EffectCell("Physical impact — Earthquake, \(Int(at * 100))%") {
                        GeometryReader { geo in
                            ImpactLayer(flourish: shot("Earthquake", category: "Physical",
                                                       type: "Ground", targets: both),
                                        progress: at, place: demoPlace(geo.size))
                        }
                    }
                    .frame(height: 210)
                }
                EffectCell("Status on self — Swords Dance, 60%") {
                    GeometryReader { geo in
                        AuraLayer(flourish: shot("Swords Dance", category: "Status", type: "Normal",
                                                 targets: []),
                                  progress: 0.60, place: demoPlace(geo.size))
                    }
                }
                .frame(height: 210)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
    }
}

private struct WeatherSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Weather and terrain")
                .font(.system(size: 18, weight: .bold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4),
                      spacing: 14) {
                ForEach([Weather.rain, .snow, .sand, .sun], id: \.self) { sky in
                    EffectCell("\(sky)") {
                        WeatherLayer(weather: sky)
                    }
                    .frame(height: 230)
                }
                ForEach([Terrain.grassy, .electric, .psychic, .misty], id: \.self) { floor in
                    EffectCell("\(floor) terrain") {
                        TerrainLayer(terrain: floor)
                    }
                    .frame(height: 230)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
    }
}
