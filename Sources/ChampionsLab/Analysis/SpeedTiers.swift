//  SpeedTiers.swift
//  The list every player keeps in their head, written down.
//
//  Speed is the first thing anybody checks and the last thing this app would
//  show you. The spread planner works out every number worth clearing — each
//  threat fully invested, its Choice Scarf number, what a weather ability does
//  to it — and then used all of it privately to build one spread. The ladder
//  itself is the thing a person actually wants on screen while building.
//
//  Two things make this more than a table of base Speeds. The numbers are what
//  a Pokemon actually moves at, so a Choice Scarf and a Swift Swim are on it at
//  their real values rather than their printed ones. And your own six is drawn
//  into the same ladder, at the Speed its selected spread gives it, so "what do
//  I outrun" is a thing you read off rather than work out.

import SwiftUI

struct SpeedTiersView: View {
    @EnvironmentObject private var store: Store
    @State private var format = "doubles"
    @State private var teamID: String = ""
    @State private var weather: Weather = .none
    @State private var terrain: Terrain = .none
    @State private var tailwind = false
    @Environment(\.snapshotMode) private var snapshotMode

    private var field: Field {
        Field(weather: weather, terrain: terrain, isDoubles: format == "doubles")
    }

    private var team: Team? {
        store.teams.first { $0.id.uuidString == teamID }
    }

    /// One number on the ladder.
    private struct Mark: Identifiable {
        let form: Form
        let speed: Int
        let label: String
        let note: String
        let usage: Double
        /// A member of the team being compared, rather than a threat.
        let isMine: Bool
        var id: String { "\(label)-\(speed)-\(isMine)" }
    }

    private var marks: [Mark] {
        var out: [Mark] = []

        for entry in store.data.usage
        where entry.formats.contains(format) && !entry.isProjected && entry.usage > 0 {
            guard let form = store.form(named: entry.name) else { continue }
            let physical = form.attack >= form.spAttack
            var sp = Array(repeating: 0, count: 6)
            sp[Stat.speed.rawValue] = ChampionsStats.spPerStat
            let fast = Combatant(form: form,
                                 ability: entry.abilityUsage?.first?.name
                                    ?? form.abilities.first?.name ?? "",
                                 item: "", sp: sp,
                                 alignment: Alignment.named(physical ? "Jolly" : "Timid"))
            out.append(Mark(form: form, speed: fast.speed(in: field),
                            label: form.formLabel, note: "max Speed",
                            usage: entry.usage, isMine: false))

            // The Scarf number, where the ladder says people run one. It is a
            // different Pokemon to play around.
            if (entry.itemUsage ?? []).contains(where: {
                $0.name == "Choice Scarf" && $0.percent >= 8 }) {
                var scarfed = fast
                scarfed.item = "Choice Scarf"
                out.append(Mark(form: form, speed: scarfed.speed(in: field),
                                label: form.formLabel, note: "Choice Scarf",
                                usage: entry.usage * 0.5, isMine: false))
            }
            // And what its weather ability does, when that weather is up.
            var weatherFast = fast
            weatherFast.ability = form.abilities.first { ability in
                ["Swift Swim", "Chlorophyll", "Sand Rush", "Slush Rush", "Surge Surfer"]
                    .contains(ability.name)
            }?.name ?? fast.ability
            if weatherFast.ability != fast.ability {
                let boosted = weatherFast.speed(in: field)
                if boosted > fast.speed(in: field) {
                    out.append(Mark(form: form, speed: boosted, label: form.formLabel,
                                    note: weatherFast.ability, usage: entry.usage * 0.6,
                                    isMine: false))
                }
            }
        }

        if let team {
            for slot in team.slots {
                guard let form = slot.battleForm(in: store),
                      let combatant = slot.combatant(in: store) else { continue }
                let base = combatant.speed(in: field)
                out.append(Mark(form: form, speed: tailwind ? base * 2 : base,
                                label: form.formLabel,
                                note: tailwind ? "yours, under Tailwind" : "yours",
                                usage: 0, isMine: true))
            }
        }
        return out.sorted { $0.speed > $1.speed }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if snapshotMode { ladder } else { ScrollView { ladder } }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("", selection: $format) {
                    ForEach(store.data.rules.formats) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190)

                Picker("", selection: $teamID) {
                    Text("No team").tag("")
                    ForEach(store.teams) { Text($0.name).tag($0.id.uuidString) }
                }
                .labelsHidden().frame(width: 190).controlSize(.small)

                Picker("", selection: $weather) {
                    ForEach(Weather.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 110).controlSize(.small)
                Picker("", selection: $terrain) {
                    ForEach(Terrain.allCases) { Text($0.rawValue + " Terrain").tag($0) }
                }.labelsHidden().frame(width: 150).controlSize(.small)

                Toggle("Your Tailwind", isOn: $tailwind)
                    .toggleStyle(.checkbox).controlSize(.small)
                Spacer()
            }
            Text("What each Pokémon actually moves at, not what its stat says: a Choice Scarf is half again, and Swift Swim or Chlorophyll double it once their weather is up. Threats are shown fully invested, because that is the version you have to be faster than.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private var ladder: some View {
        let rows = marks
        let fastest = rows.first?.speed ?? 1
        return LazyVStack(spacing: 3) {
            ForEach(rows) { mark in
                HStack(spacing: 10) {
                    Text("\(mark.speed)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                        .foregroundStyle(mark.isMine ? Palette.accent : Palette.dim)
                    SpriteImage(form: mark.form, side: 28)
                    Text(mark.label)
                        .font(.system(size: 12, weight: mark.isMine ? .semibold : .regular))
                        .lineLimit(1)
                    Text(mark.note)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    if mark.usage > 0 {
                        Text(String(format: "%.0f%%", mark.usage))
                            .font(.system(size: 10, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    GeometryReader { geo in
                        Capsule()
                            .fill(mark.isMine ? Palette.accent : Palette.hairline)
                            .frame(width: geo.size.width
                                   * min(1, Double(mark.speed) / Double(max(1, fastest))))
                    }
                    .frame(width: 120, height: 4)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(mark.isMine ? Palette.accent.opacity(0.14) : Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(10)
    }
}
