//  TeamPreviewView.swift
//  Team Preview: choose the four you bring, in order, while they choose theirs.
//
//  Your six down one side and theirs down the other, their likely four marked,
//  and against each of theirs how the one you just picked fares. The order you
//  pick in is the order you bring: the first two lead. The picks are the battle
//  screen's state, bound here; beginning the game goes back up, because that is
//  the transition into the battle and the animation that opens it.

import SwiftUI

struct TeamPreviewView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.snapshotMode) private var snapshotMode
    let myTeam: Team?
    let theirTeam: Team?
    let lobby: BattleView.Lobby
    let singles: Bool
    @Binding var bringing: [String]
    @Binding var focused: String?
    let onBegin: () -> Void
    /// A game between two people: the button says Ready, the page waits for
    /// the other player once you are, and says when they are.
    var beginLabel = "START THE BATTLE"
    var waiting: String? = nil
    var link: LANLink? = nil

    private var bringCount: Int { singles ? 3 : 4 }
    private var leadCount: Int { singles ? 1 : 2 }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let lean = tan(25 * CGFloat.pi / 180) * h / 2
            ZStack {
                Color(red: 0.05, green: 0.06, blue: 0.09)
                Slab(lean: lean, left: true)
                    .fill(LinearGradient(colors: [Palette.accent.opacity(0.50), Palette.accent.opacity(0.06)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Slab(lean: lean, left: false)
                    .fill(LinearGradient(colors: [Palette.bad.opacity(0.06), Palette.bad.opacity(0.50)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                SlantLines(lean: lean, spacing: 44).stroke(.white.opacity(0.05), lineWidth: 1)
                Path { p in
                    p.move(to: CGPoint(x: geo.size.width / 2 + lean, y: 0))
                    p.addLine(to: CGPoint(x: geo.size.width / 2 - lean, y: h))
                }
                .stroke(.white.opacity(0.35), lineWidth: 2)
                .shadow(color: .white.opacity(0.3), radius: 8)

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TEAM PREVIEW").font(.system(size: 26, weight: .black)).italic()
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                            Text("Choose the \(bringCount) you bring, in order. "
                                 + (singles ? "The first leads."
                                            : "The first two lead; the others come in behind.")
                                 + " They are choosing too: their likely four is marked, and each shows how the one you just picked fares against it.")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 620, alignment: .leading)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("BRINGING").font(.system(size: 9, weight: .heavy)).kerning(1.2)
                                .foregroundStyle(.white.opacity(0.6))
                            Text("\(bringing.count) of \(bringCount)")
                                .font(.system(size: 22, weight: .black, design: .rounded)).monospacedDigit()
                                .foregroundStyle(.white)
                        }
                    }

                    HStack(alignment: .top, spacing: 72) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("YOUR SIX").font(.system(size: 9, weight: .heavy)).kerning(1.2)
                                .foregroundStyle(.white.opacity(0.6))
                            ForEach(Array((myTeam?.slots ?? []).enumerated()), id: \.offset) {
                                _, slot in
                                previewRow(slot)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .trailing, spacing: 6) {
                            Text("THEIR SIX").font(.system(size: 9, weight: .heavy)).kerning(1.2)
                                .foregroundStyle(.white.opacity(0.6))
                            ForEach(Array((theirTeam?.slots ?? []).enumerated()), id: \.offset) {
                                _, slot in
                                opposingRow(slot)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 10) {
                        Text(bringing.isEmpty
                             ? "Nothing chosen yet. Click your Pokémon in the order they should come."
                             : bringing.enumerated().map { index, id in
                                "\(index + 1). \(label(id))" }.joined(separator: "   "))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(bringing.isEmpty ? 0.55 : 0.9))
                        Spacer()
                        previewButton("Suggest", symbol: "wand.and.stars") { autoPick() }
                        previewButton("Clear", symbol: "xmark") { bringing = []; focused = nil }
                        if let link { ReadyLine(link: link) }
                        if let waiting {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(waiting).font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 11)
                            .background(Capsule().fill(Palette.accent.opacity(0.35)))
                        } else {
                            Button { onBegin() } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "flag.2.crossed.fill")
                                    Text(beginLabel).font(.system(size: 13, weight: .heavy)).kerning(1.2)
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 22).padding(.vertical, 11)
                                .background(LinearGradient(colors: [Palette.accent, Palette.bad],
                                                           startPoint: .leading, endPoint: .trailing))
                                .clipShape(Capsule())
                                .opacity(bringing.count < bringCount ? 0.4 : 1)
                                .shadow(color: Palette.accent.opacity(bringing.count < bringCount ? 0 : 0.45), radius: 10, y: 4)
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.defaultAction)
                            .disabled(bringing.count < bringCount)
                        }
                    }
                }
                .padding(22)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .padding(14)
    }

    private func previewButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(.white.opacity(0.12)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// One of mine, in the order it is being brought.
    private func previewRow(_ slot: TeamSlot) -> some View {
        let form = slot.form(in: store.rulebook)
        let holdsStone = slot.megaEvolution(in: store.rulebook) != nil   // yours: you know
        let id = slot.formID
        let order = bringing.firstIndex(of: id).map { $0 + 1 }
        let isFocus = focused == id || (focused == nil && bringing.last == id)
        return Button {
            if let at = bringing.firstIndex(of: id) {
                bringing.remove(at: at)
                focused = bringing.last
            } else if bringing.count < bringCount {
                bringing.append(id)
                focused = id
            } else {
                focused = bringing.contains(id) ? id : focused
            }
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(order == nil ? Color.white.opacity(0.15)
                              : (order! <= leadCount ? Palette.accent : Color.white.opacity(0.35)))
                        .frame(width: 20, height: 20)
                    Text(order.map(String.init) ?? "")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                }
                if let form {
                    ZStack(alignment: .topTrailing) {
                        SpriteImage(form: form, side: 46).shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                        if holdsStone { MegaBadge(uncertain: false, form: form) }
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(form?.formLabel ?? id)
                        .font(.system(size: 12, weight: order == nil ? .regular : .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 3) {
                        ForEach(form?.pokeTypes ?? []) { TypeChip(type: $0, size: .small) }
                        if let order, order <= leadCount {
                            Text("LEADS").font(.system(size: 8, weight: .bold)).kerning(0.4)
                                .foregroundStyle(Palette.accent)
                        }
                    }
                }
                Spacer(minLength: 0)
                if isFocus, order != nil {
                    Image(systemName: "eye.fill").font(.system(size: 9))
                        .foregroundStyle(Palette.accent)
                        .help("Their side is showing how this one fares")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(order != nil ? Palette.accent.opacity(isFocus ? 0.42 : 0.26)
                                     : Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                isFocus && order != nil ? Color.white.opacity(0.8) : Color.white.opacity(0.14),
                lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// One of theirs, marked with how the Pokémon in focus fares against it.
    private func opposingRow(_ slot: TeamSlot) -> some View {
        let form = slot.form(in: store.rulebook)
        let battle = slot.battleForm(in: store.rulebook)
        // Theirs: not what it holds, which you cannot see, but whether the
        // species has a Mega at all.
        let couldMega = form.map { theirTeam.map(MegaGuess(store: store).possibleMegas)?.contains($0.id) ?? false } ?? false
        let reading = matchupMark(against: slot)
        // Where this one sits in the four they will most likely bring.
        let expected = lobby.theirPlan?.bring.firstIndex { $0.id == battle?.id }
        let likelyHome = lobby.theirPlan != nil && expected == nil
        return HStack(spacing: 9) {
            if let reading {
                HStack(spacing: 2) {
                    Image(systemName: reading.symbol)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(reading.tint)
                    if reading.shock {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.bad)
                    }
                }
                .help(reading.note)
                .frame(width: 34, alignment: .leading)
            } else {
                Color.clear.frame(width: 34, height: 1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(form?.formLabel ?? slot.formID)
                    .font(.system(size: 12, weight: expected == nil ? .regular : .semibold))
                    .foregroundStyle(.white.opacity(likelyHome ? 0.7 : 1))
                    .lineLimit(1)
                HStack(spacing: 3) {
                    if let expected {
                        Text(expected < leadCount ? "LIKELY LEADS" : "LIKELY BRINGS")
                            .font(.system(size: 8, weight: .bold)).kerning(0.4)
                            .foregroundStyle(expected < leadCount ? Palette.bad : Palette.warn)
                    } else if likelyHome {
                        Text("LIKELY HOME").font(.system(size: 8, weight: .bold)).kerning(0.4)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    ForEach(form?.pokeTypes ?? []) { TypeChip(type: $0, size: .small) }
                }
            }
            if let form {
                ZStack(alignment: .topTrailing) {
                    SpriteImage(form: form, side: 46).opacity(likelyHome ? 0.6 : 1)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                    if couldMega { MegaBadge(uncertain: true, form: form) }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.white.opacity(likelyHome ? 0.05 : 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(reading?.tint.opacity(0.55) ?? Color.white.opacity(0.14), lineWidth: 1))
    }

    /// How the Pokémon in focus fares against one of theirs.
    ///
    /// Read off the versus grid rather than off the type chart, so it knows
    /// that a Pokémon resisting your attack still loses if it cannot hurt you
    /// back. Nothing shows until something is picked, because there is nothing
    /// to compare against yet.
    private func matchupMark(against theirs: TeamSlot)
        -> (symbol: String, tint: Color, shock: Bool, note: String)? {
        guard let mine = myTeam, let theirTeam,
              let focusID = focused ?? bringing.last,
              let mineSlot = mine.slots.first(where: { $0.formID == focusID }),
              let mineForm = mineSlot.battleForm(in: store.rulebook),
              let theirForm = theirs.battleForm(in: store.rulebook) else { return nil }
        let grid = Matchup(mine: mine, theirs: theirTeam, rules: store.rulebook,
                           field: Field(isDoubles: !singles))
        guard let cell = grid.cell(mine: mineForm, theirs: theirForm) else { return nil }
        let against = "\(mineForm.formLabel) against \(theirForm.formLabel)"
        switch cell.outcome {
        case .win:
            return ("arrow.up.circle.fill", Palette.good, false,
                    "\(against): \(mineForm.formLabel) wins this one.")
        case .favoured:
            return ("arrow.up", Palette.good, false,
                    "\(against): the better side of it.")
        case .neutral:
            return ("minus", Palette.dim, false, "\(against): even.")
        case .against:
            return ("arrow.down", Palette.warn, false,
                    "\(against): the worse side of it.")
        case .loss:
            return ("arrow.down.circle.fill", Palette.bad, true,
                    "\(against): \(mineForm.formLabel) loses this badly. Bring an answer.")
        }
    }

    private func label(_ formID: String) -> String {
        if let slot = myTeam?.slots.first(where: { $0.formID == formID }),
           let form = slot.battleForm(in: store.rulebook) {
            return form.formLabel
        }
        return store.formsByID[formID]?.formLabel ?? formID
    }

    /// What the bring-four search would take, as a starting point.
    private func autoPick() {
        guard let mine = myTeam, let theirs = theirTeam else { return }
        let grid = Matchup(mine: mine, theirs: theirs, rules: store.rulebook,
                           field: Field(isDoubles: !singles))
        let picker = BringFour(matchup: grid, rules: store.rulebook, bring: bringCount)
        guard let plan = picker.plans.first else { return }
        // The plan names battle forms; the preview is keyed on what is
        // registered, which for a Mega is the base.
        bringing = plan.bring.compactMap { form in
            mine.slots.first { $0.battleForm(in: store.rulebook)?.id == form.id }?.formID
        }
    }
}

/// Whether the other player has their four, in a game between two people.
struct ReadyLine: View {
    @ObservedObject var link: LANLink

    var body: some View {
        Label(link.theirReady ? "\(link.theirName) is ready" : "\(link.theirName) is choosing...",
              systemImage: link.theirReady ? "checkmark.circle.fill" : "hourglass")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(link.theirReady ? Palette.good : .secondary)
    }
}
