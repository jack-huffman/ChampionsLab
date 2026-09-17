//  VersusPageView.swift
//  The lobby: where the battle screen opens, and where a game starts from.
//
//  The two sixes against each other, before anyone has picked a four -- or
//  either side still open, asking for a team. A side is chosen by clicking
//  it: yours from your saved teams, theirs from the published lists or your
//  other teams. Once both are in, what you would bring, what they would, what
//  each side has reason to fear, and the verdict across the top. Everything
//  it shows is worked out by the battle screen as the Lobby; this draws it,
//  and the things it can do -- choose a side, start -- go back up.

import SwiftUI

struct VersusPageView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.snapshotMode) private var snapshotMode
    let myTeam: Team?
    let theirTeam: Team?
    let lobby: BattleView.Lobby
    let myTeamID: String
    let opponentID: String
    let singles: Bool
    @Binding var startHover: Bool
    let onChooseMine: (String) -> Void
    let onChooseTheirs: (String) -> Void
    let onStart: () -> Void
    /// Which side's chooser is open, under that side's name.
    @State private var choosingMine = false
    @State private var choosingTheirs = false

    private var format: String { singles ? "singles" : "doubles" }
    private var bringCount: Int { singles ? 3 : 4 }
    private var leadCount: Int { singles ? 1 : 2 }

    var body: some View {
        VStack(spacing: 14) {
            VersusBanner(mine: myTeam.map { mine in
                             bannerSide(mine, plan: lobby.myPlan, title: "YOUR TEAM",
                                        tag: "\(mine.slots.count) Pokémon · \(format)",
                                        tint: Palette.accent) },
                         theirs: theirTeam.map { theirs in
                             bannerSide(theirs, plan: lobby.theirPlan, title: "THEIR TEAM",
                                        tag: theirTag, tint: Palette.bad) },
                         score: lobby.verdict?.score ?? 0,
                         verdict: edgeWords(lobby.verdict?.score ?? 0),
                         onChoose: { mine in
                             if mine { choosingMine = true } else { choosingTheirs = true }
                         })
                .frame(height: 400)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1))
                // The choosers hang off the corners the names sit in.
                .overlay(alignment: .topLeading) {
                    Color.clear.frame(width: 300, height: 56).padding(18)
                        .popover(isPresented: $choosingMine, arrowEdge: .bottom) {
                            chooser(.mine)
                        }
                }
                .overlay(alignment: .topTrailing) {
                    Color.clear.frame(width: 300, height: 56).padding(18)
                        .popover(isPresented: $choosingTheirs, arrowEdge: .bottom) {
                            chooser(.theirs)
                        }
                }

            if myTeam != nil, theirTeam != nil {
                HStack(alignment: .top, spacing: 14) {
                    yourSideCard
                    theirSideCard
                }

                HStack {
                    Spacer()
                    Button {
                        onStart()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "flag.2.crossed.fill")
                                .rotationEffect(.degrees(startHover ? -12 : 0))
                                .scaleEffect(startHover ? 1.15 : 1)
                            Text("START BATTLE").font(.system(size: 14, weight: .heavy))
                                .kerning(startHover ? 2.2 : 1.2)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28).padding(.vertical, 13)
                        .background(
                            // The two sides' colours meet in the button; on hover
                            // the seam slides, the way the divider above leans.
                            LinearGradient(colors: [Palette.accent, Palette.bad],
                                           startPoint: startHover ? .topLeading : .leading,
                                           endPoint: startHover ? .bottomTrailing : .trailing))
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(startHover ? 0.55 : 0), lineWidth: 1.5))
                        .shadow(color: Palette.accent.opacity(startHover ? 0.6 : 0.4),
                                radius: startHover ? 18 : 10, y: startHover ? 6 : 4)
                        .shadow(color: Palette.bad.opacity(startHover ? 0.45 : 0),
                                radius: 18, y: 6)
                        .scaleEffect(startHover ? 1.06 : 1)
                        .animation(.spring(response: 0.32, dampingFraction: 0.55), value: startHover)
                    }
                    .buttonStyle(.plain)
                    .onHover { startHover = $0 }
                    .keyboardShortcut(.defaultAction)
                    .help("On to Team Preview: choose the \(bringCount) you bring and their order, while they choose theirs.")
                    Spacer()
                }
            } else {
                lobbyHint
            }
        }
        .padding(20)
    }

    /// What the page is for, while a side is still open.
    private var lobbyHint: some View {
        VStack(spacing: 6) {
            Text(myTeam == nil && theirTeam == nil ? "Pick a team for each side."
                 : myTeam == nil ? "Pick your team." : "Pick an opponent.")
                .font(.system(size: 14, weight: .semibold))
            Text("Click a side of the banner to choose. The engine reads the matchup as soon as both are in, and the battle starts from here.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(.top, 8)
    }

    private func chooser(_ side: TeamChooser.Side) -> some View {
        TeamChooser(side: side, myTeamID: myTeamID, opponentID: opponentID, singles: singles) { id in
            choosingMine = false; choosingTheirs = false
            if side == .mine { onChooseMine(id) } else { onChooseTheirs(id) }
        }
        .environmentObject(store)
        .frame(width: 640, height: 600)
    }

    private func bannerSide(_ team: Team, plan: BringFour.Plan?, title: String, tag: String,
                            tint: Color) -> VersusBanner.Side {
        let all = team.slots.compactMap { $0.battleForm(in: store.rulebook) }
        // The predicted four first, leads leading; the two left home last.
        let ordered: [Form]
        if let plan {
            ordered = plan.bring + all.filter { form in !plan.bring.contains { $0.id == form.id } }
        } else {
            ordered = all
        }
        let mine = team.id == myTeam?.id
        return VersusBanner.Side(title: title, name: team.name, tag: tag,
                                 forms: ordered.map { MegaGuess(store: store).registered($0, in: team) },
                                 megas: mine ? MegaGuess(store: store).stoneHolders(team) : MegaGuess(store: store).possibleMegas(team),
                                 megasUncertain: !mine,
                                 leadCount: plan == nil ? 0 : leadCount, tint: tint)
    }

    private var theirTag: String {
        if let meta = store.data.metaTeams.first(where: { $0.id == opponentID }) {
            if meta.projected { return "projected · \(meta.archetype)" }
            if let record = meta.record {
                return ([record] + [meta.placement].compactMap { $0 }).joined(separator: " · ")
            }
            return meta.archetype
        }
        return "\(theirTeam?.slots.count ?? 0) Pokémon · \(theirTeam?.format ?? format)"
    }

    private var yourSideCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Your side", subtitle: "What the engine would bring, and why")
                if let plan = lobby.myPlan, let mine = myTeam {
                    fourRow(plan.bring.map { MegaGuess(store: store).registered($0, in: mine) }, megas: MegaGuess(store: store).stoneHolders(mine),
                            leads: leadCount, tint: Palette.accent)
                    bullets(Array(plan.reasons.prefix(2)) + Array(plan.warnings.prefix(1)),
                            tint: Palette.accent)
                    if !lobby.myFears.isEmpty {
                        Label("Nothing on your six beats their \(names(lobby.myFears)). That is the matchup.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Your six are at or under the limit, so everyone comes.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var theirSideCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Through their eyes",
                              subtitle: "What they see when they look at your six")
                if let plan = lobby.theirPlan, let theirs = theirTeam {
                    Text("They will most likely bring")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    fourRow(plan.bring.map { MegaGuess(store: store).registered($0, in: theirs) }, megas: MegaGuess(store: store).possibleMegas(theirs),
                            uncertain: true, leads: leadCount, tint: Palette.bad)
                    bullets(plan.reasons.prefix(2).map(fromTheirChair), tint: Palette.bad)
                    if !lobby.theirFears.isEmpty {
                        Label("Nothing on their six beats your \(names(lobby.theirFears)) — expect them to play around it, not into it.",
                              systemImage: "eye.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.good)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !lobby.theirExpectation.isEmpty {
                        Text("They cannot see which four you bring or what anyone holds. From your six they will expect \(names(lobby.theirExpectation)).")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Their six are at or under the limit, so everyone comes.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func fourRow(_ forms: [Form], megas: Set<String> = [], uncertain: Bool = false,
                         leads: Int, tint: Color) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(forms.enumerated()), id: \.offset) { index, form in
                VStack(spacing: 2) {
                    ZStack(alignment: .topLeading) {
                        SpriteImage(form: form, side: 52)
                        Text("\(index + 1)")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(index < leads ? tint : Palette.dim)
                            .clipShape(Circle())
                        if megas.contains(form.id) {
                            MegaBadge(uncertain: uncertain, form: form)
                                .frame(maxWidth: .infinity, alignment: .topTrailing)
                                .frame(width: 52)
                        }
                    }
                    Text(form.formLabel)
                        .font(.system(size: 10, weight: index < leads ? .semibold : .regular))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if index < leads {
                        Text("LEAD").font(.system(size: 7, weight: .heavy)).kerning(0.5)
                            .foregroundStyle(tint)
                    }
                }
                .frame(width: 72)
            }
            Spacer(minLength: 0)
        }
    }

    private func bullets(_ lines: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(tint.opacity(0.5)).frame(width: 4, height: 4).padding(.top, 5)
                    Text(line).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func names(_ forms: [Form]) -> String {
        let labels = forms.map(\.formLabel)
        if labels.count <= 1 { return labels.first ?? "" }
        return labels.dropLast().joined(separator: ", ") + " and " + labels.last!
    }

    /// A reason written for the side that made the plan, read from the other
    /// chair: their "your" is your "their", and the other way round.
    private func fromTheirChair(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(of: "Your ", with: "\u{1}")
        out = out.replacingOccurrences(of: "your ", with: "\u{2}")
        out = out.replacingOccurrences(of: "Their ", with: "Your ")
        out = out.replacingOccurrences(of: "their ", with: "your ")
        out = out.replacingOccurrences(of: "\u{1}", with: "Their ")
        out = out.replacingOccurrences(of: "\u{2}", with: "their ")
        out = out.replacingOccurrences(of: " you left home", with: " they left home")
        out = out.replacingOccurrences(of: "off you", with: "off them")
        return out
    }
}
