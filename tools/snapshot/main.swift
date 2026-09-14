//  tools/snapshot/main.swift
//  Render the main screens to PNG without launching the app.
//
//  Compiled against every app source except ChampionsLab.swift, whose @main
//  would collide with this one. Useful for eyeballing layout changes and for
//  checking the dark and light palettes actually both work.

import AppKit
import SwiftUI

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
    render(TeamAnalysisView(team: team), named: "analysis-dark",
           size: CGSize(width: 1000, height: 2300), dark: true)
    render(TeamAnalysisView(team: team), named: "analysis-light",
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
    render(ForecastView(), named: "forecast-top-dark",
           size: CGSize(width: 1180, height: 1150), dark: true)
    render(ForecastView(), named: "forecast-dark",
           size: CGSize(width: 1180, height: 4200), dark: true)
    render(MatchupView(team: team, initialOpponent: "big-six"), named: "versus-dark",
           size: CGSize(width: 1180, height: 2400), dark: true)
    // The calculator as it opens from a team slot's ƒ button.
    if let saved = store.teams.first(where: { $0.name == "Sun / Dual Mega" }),
       let zard = saved.slots.first(where: { $0.form(in: store)?.name == "Charizard" }),
       let target = store.form(named: "Garchomp") {
        render(CalculatorView(preload: CalculatorPreload(slot: zard, store: store),
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
        let grid = Matchup(mine: playing, theirs: theirs, store: store,
                           field: Field(isDoubles: true))
        let chosen = BringFour(matchup: grid, store: store).plans.first?.bring
            .compactMap { form in
                playing.slots.first { $0.battleForm(in: store)?.id == form.id }?.formID
            } ?? []
        render(BattleView(openTeams: (mine: playing.id.uuidString, theirs: against.id),
                          previewing: chosen),
               named: "battle-preview-dark",
               size: CGSize(width: 1180, height: 760), dark: true)

        // And the field itself, a turn in.
        var four = playing
        four.slots = chosen.compactMap { id in playing.slots.first { $0.formID == id } }
        var board = Board(mine: four.slots.isEmpty ? playing : four, theirs: theirs,
                          store: store, field: Field(isDoubles: true),
                          alreadyEvolved: false)
        board.activeCount = 2
        render(BattleView(playing: board), named: "battle-dark",
               size: CGSize(width: 1180, height: 1500), dark: true)
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
