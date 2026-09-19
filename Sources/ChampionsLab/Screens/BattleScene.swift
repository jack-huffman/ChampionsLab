//  BattleScene.swift
//  The battle drawn as Showdown draws it.
//
//  Your two Pokemon at the front, seen from behind and drawn large; theirs at
//  the back, smaller, facing you; a statbar over each with its name, health,
//  condition and stages; and the moves' choreography playing in the same
//  scene coordinates the client wrote it in, so a fireball leaves a Pokemon
//  and lands on one without any translation between. The card the field used
//  to lay out is a click away on every statbar, so nothing it showed is lost.

import SwiftUI

/// A statbar that has been clicked, for the card behind it.
struct DetailSeat: Identifiable, Equatable {
    let seat: Seat
    var id: String { "\(seat.mine ? "m" : "t")\(seat.slot)" }
}

extension BattleFieldView {
    /// The scene as this arena lays it out, for drawing and for the playback.
    func stageFor(_ size: CGSize, board: Board) -> MoveTimeline.Stage {
        MoveTimeline.Stage(size: size, singles: board.activeCount == 1, pixel: usesPixelSprites)
    }

    /// Pixel sprites are the scene's own look; the illustrations stay for a
    /// still, which cannot fetch and cannot play an AppKit view anyway.
    var usesPixelSprites: Bool { spriteStyle == "pixel" && !snapshotMode }

    /// Back row first, so the front draws over it; within a row the client's
    /// own order, the further one behind.
    func seatsInDrawOrder(_ board: Board) -> [Seat] {
        var seats: [Seat] = []
        for slot in stride(from: min(board.activeCount, board.theirs.count) - 1, through: 0, by: -1) {
            seats.append(Seat(mine: false, slot: slot))
        }
        for slot in 0..<min(board.activeCount, board.mine.count) { seats.append(Seat(mine: true, slot: slot)) }
        return seats
    }

    func fighter(at seat: Seat, in board: Board) -> Fighter? {
        let side = seat.mine ? board.mine : board.theirs
        return side.indices.contains(seat.slot) ? side[seat.slot] : nil
    }

    // MARK: - The scene

    @ViewBuilder func battleScene(_ board: Board, size: CGSize, tint: Color,
                                  ground: Color? = nil,
                                  terrain: Terrain = .none) -> some View {
        let stage = stageFor(size, board: board)
        ZStack {
            sceneGround(stage: stage, tint: tint, ground: ground ?? tint, terrain: terrain)
            ForEach(seatsInDrawOrder(board), id: \.self) { seat in
                if let fighter = fighter(at: seat, in: board) {
                    scenePokemon(fighter, seat: seat, stage: stage, board: board)
                }
            }
            if let scene {
                ChoreographyLayer(scene: scene)
            }
            readouts(board, stage: stage)
        }
        .modifier(QuakeEffect(progress: moveClock, shakes: tracks?.shakes ?? [], duration: tracks?.duration ?? 1))
        // The playback places a recipe on the scene, so it has to know how
        // the scene is laid out -- and again whenever that changes.
        .onAppear { playback.stage(stage) }
        .onChange(of: size) { new in playback.stage(stageFor(new, board: board)) }
        .onChange(of: spriteStyle) { style in
            UserDefaults.standard.set(style, forKey: "battleSpriteStyle")
            playback.stage(stageFor(size, board: board))
        }
        .onChange(of: board.activeCount) { _ in playback.stage(stageFor(size, board: board)) }
    }

    /// The ground: a platform under each side, in perspective, in the field's
    /// colour, wide enough for both Pokemon standing on it. The client's
    /// backdrops are photographs it owns; this is ours.
    func sceneGround(stage: MoveTimeline.Stage, tint: Color,
                     ground: Color, terrain: Terrain = .none) -> some View {
        // A platform with terrain on it is lit from within and ringed twice:
        // the thick rim is what makes it read as a floor somebody has changed
        // rather than the same floor in another colour, which matters when the
        // colour is the part you cannot rely on.
        let standing = terrain != .none
        func platform(centre: CGPoint, width: CGFloat, height: CGFloat, strength: Double) -> some View {
            Ellipse()
                .fill(RadialGradient(
                    colors: [ground.opacity((standing ? 0.52 : 0.28) * strength),
                             ground.opacity((standing ? 0.24 : 0.10) * strength),
                             Palette.canvas.opacity(0.0)],
                    center: .center, startRadius: 0, endRadius: width / 2))
                .overlay(Ellipse().strokeBorder(
                    ground.opacity((standing ? 0.85 : 0.22) * strength),
                    lineWidth: standing ? 2.5 : 1))
                .overlay(
                    Ellipse().strokeBorder(ground.opacity(standing ? 0.30 * strength : 0),
                                           lineWidth: 10).blur(radius: 7))
                .frame(width: width, height: height)
                .position(centre)
        }
        // Under the seats, wherever the stage has put them.
        func under(_ mine: Bool) -> (centre: CGPoint, width: CGFloat) {
            let seats = stage.singles ? [Seat(mine: mine, slot: 0)] : [Seat(mine: mine, slot: 0), Seat(mine: mine, slot: 1)]
            let points = seats.map { stage.project(stage.home($0)) }
            let sprite = 96 * stage.scale(at: mine ? 0 : 200, pixelSprite: usesPixelSprites)
            let left = points.map(\.x).min()!, right = points.map(\.x).max()!
            let low = points.map(\.y).max()!
            return (CGPoint(x: (left + right) / 2, y: low + sprite * 0.3), right - left + sprite * 1.15)
        }
        let far = under(false), near = under(true)
        return ZStack {
            // The horizon, faint, where the far platform sits.
            LinearGradient(colors: [tint.opacity(0.10), .clear, tint.opacity(0.05)],
                           startPoint: .top, endPoint: .bottom)
            // The floor itself, under both platforms, so the change reaches
            // the whole ground and not only the two discs.
            if standing {
                LinearGradient(colors: [.clear, ground.opacity(0.07), ground.opacity(0.14)],
                               startPoint: .top, endPoint: .bottom)
                    .blendMode(.plusLighter)
            }
            platform(centre: far.centre, width: far.width, height: far.width * 0.18, strength: 0.8)
            platform(centre: near.centre, width: near.width, height: near.width * 0.16, strength: 1)
        }
        .allowsHitTesting(false)
    }

    // MARK: - A Pokemon

    /// The Pokemon at its seat: shadow, dome or substitute, the sprite, and
    /// the damage it just took, carried through a move's leans by the clock.
    func scenePokemon(_ fighter: Fighter, seat: Seat, stage: MoveTimeline.Stage, board: Board) -> some View {
        let home = stage.home(seat)
        let at = stage.project(home)
        let pixel = usesPixelSprites
        let side = 96 * stage.scale(at: home.z, pixelSprite: pixel)
        let out = !opening || shown.contains("\(seat.mine ? "m" : "t")\(seat.slot)")
        let hit = seat.mine ? struck.contains(seat.slot) : struckTheirs.contains(seat.slot)
        let asked = seat.mine && session.awaitingOrders(board) == seat.slot && !fighter.fainted
        return ZStack {
            if !fighter.fainted {
                Ellipse()
                    .fill(RadialGradient(colors: [.black.opacity(0.22), .clear],
                                         center: .center, startRadius: 1, endRadius: side * 0.3))
                    .frame(width: side * 0.6, height: side * 0.15)
                    .offset(y: side * 0.38)
            }
            if asked {
                Ellipse()
                    .strokeBorder(Palette.accent, lineWidth: 2)
                    .shadow(color: Palette.accent.opacity(0.8), radius: 8)
                    .frame(width: side * 0.86, height: side * 0.26)
                    .offset(y: side * 0.36)
            }
            let moved = playback.boosts[seat] ?? []
            let rising = moved.contains { $0.delta > 0 }, falling = moved.contains { $0.delta < 0 }
            // The game's own sign for a stage moving: the Pokemon lit in the
            // colour of it, arrows streaming up for a rise, down for a fall.
            // Orange up and blue down, a pair told apart by most eyes, and
            // the direction says it anyway.
            if rising || falling {
                Circle()
                    .fill(RadialGradient(colors: [(rising ? Self.riseTint : Self.fallTint).opacity(0.45), .clear],
                                         center: .center, startRadius: side * 0.1, endRadius: side * 0.55))
                    .frame(width: side, height: side)
                    .transition(.opacity)
            }
            fighterSprite(fighter.build.form, mine: seat.mine, side: side * 0.92)
                .offset(y: fighter.fainted ? side * 0.12 : (pixel ? 0 : bob))
                .opacity(fighter.fainted ? 0.2 : 1)
                .saturation(fighter.fainted ? 0 : 1)
                .scaleEffect(fighter.fainted ? 0.82 : (hit ? 1.08 : 1))
                .shadow(color: hit ? Palette.bad.opacity(0.6) : .clear, radius: 10)
                .animation(.spring(response: 0.32, dampingFraction: 0.5), value: hit)
                .animation(.easeOut(duration: 0.35), value: fighter.fainted)
            // The shield, in front of the Pokemon it covers and thin enough to
            // see it through; the substitute's ring the same.
            if guarding(fighter) {
                Circle()
                    .fill(RadialGradient(colors: [Palette.accent.opacity(0.02), Palette.accent.opacity(0.22)],
                                         center: .center, startRadius: side * 0.15, endRadius: side * 0.5))
                    .overlay(Circle().strokeBorder(Palette.accent.opacity(0.8), lineWidth: 1.5))
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5).padding(3))
                    .frame(width: side * 0.98, height: side * 0.98)
                    .transition(.scale.combined(with: .opacity))
            } else if fighter.substitute > 0, !fighter.fainted {
                Circle()
                    .strokeBorder(Palette.dim.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: side * 0.98, height: side * 0.98)
            }
            if rising { StatArrows(up: true, tint: Self.riseTint, side: side * 0.9).transition(.opacity) }
            if falling { StatArrows(up: false, tint: Self.fallTint, side: side * 0.9).transition(.opacity) }
        }
        .frame(width: side, height: side)
        // The game is over and this one is on the side that won: a crown,
        // hovering, riding the same bob the Pokemon does.
        .overlay(alignment: .top) {
            if session.won(board) == seat.mine, !fighter.fainted {
                Image(systemName: "crown.fill")
                    .font(.system(size: Swift.max(15, 14 * stage.k), weight: .black))
                    .foregroundStyle(LinearGradient(
                        colors: [Color(red: 1.0, green: 0.90, blue: 0.45),
                                 Color(red: 0.96, green: 0.68, blue: 0.13)],
                        startPoint: .top, endPoint: .bottom))
                    .shadow(color: Color(red: 1.0, green: 0.82, blue: 0.25).opacity(0.9), radius: 12)
                    .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                    .offset(y: -side * 0.42 + bob * 1.6)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            // What the step did to this one, stacked over it: the health
            // lost, the stages moved, the ability that went off.
            VStack(spacing: 3) {
                // Above the number it explains, and gone when it is.
                if playback.crits.contains(seat), (damage[seat] ?? 0) > 0 {
                    Text("CRITICAL")
                        .font(.system(size: max(9, 8 * stage.k), weight: .black, design: .rounded))
                        .kerning(0.9)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(LinearGradient(
                            colors: [Color(red: 1.0, green: 0.78, blue: 0.24),
                                     Color(red: 0.94, green: 0.30, blue: 0.14)],
                            startPoint: .top, endPoint: .bottom)))
                        .shadow(color: Color(red: 1.0, green: 0.55, blue: 0.15).opacity(0.9), radius: 9)
                        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                        .transition(.asymmetric(insertion: .scale(scale: 0.4).combined(with: .opacity),
                                                removal: .opacity))
                        .id(playback.hitNumber)
                }
                if let lost = damage[seat], lost > 0 {
                    Text("-\(lost)")
                        .font(.system(size: max(15, 13 * stage.k), weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(color: Palette.bad, radius: 6)
                        .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                        .transition(.asymmetric(insertion: .offset(y: 14).combined(with: .opacity),
                                                removal: .offset(y: -12).combined(with: .opacity)))
                        // Fresh for every blow of a flurry, so each one arrives.
                        .id(playback.hitNumber)
                }
                if let moved = playback.boosts[seat], !moved.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(moved, id: \.stat) { change in
                            Text("\(Stat(rawValue: change.stat)?.short ?? "") \(change.delta > 0 ? "+" : "")\(change.delta)")
                                .font(.system(size: max(10, 9 * stage.k), weight: .heavy, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(change.delta > 0 ? Self.riseTint : Self.fallTint))
                                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                        }
                    }
                    .transition(.asymmetric(insertion: .offset(y: 10).combined(with: .opacity),
                                            removal: .opacity))
                }
                if let status = playback.statusShown[seat] {
                    Text(status.rawValue.prefix(1).uppercased() + status.rawValue.dropFirst())
                        .font(.system(size: max(10, 9 * stage.k), weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(statusTint(status)))
                        .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                        .transition(.asymmetric(insertion: .scale(scale: 0.7).combined(with: .opacity), removal: .opacity))
                }
                if let fired = playback.abilities[seat], !fired.isEmpty {
                    ForEach(fired, id: \.self) { name in
                        HStack(spacing: 4) {
                            Image(systemName: "wand.and.stars").font(.system(size: max(9, 8 * stage.k), weight: .bold))
                            Text(name).font(.system(size: max(10, 9 * stage.k), weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(red: 0.08, green: 0.09, blue: 0.13).opacity(0.92)))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(.white.opacity(0.7), lineWidth: 1))
                        .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                    }
                    .transition(.asymmetric(insertion: .scale(scale: 0.7).combined(with: .opacity),
                                            removal: .opacity))
                }
            }
            .offset(y: -6)
            .allowsHitTesting(false)
        }
        .modifier(carried(seat))
        .opacity(out ? 1 : 0)
        .scaleEffect(out ? 1 : 0.2)
        .position(at)
        .allowsHitTesting(false)
    }

    /// The colours of a stage rising and falling, chosen to be told apart
    /// by most kinds of colour vision; the arrows' direction says it too.
    static let riseTint = Color(red: 1.0, green: 0.56, blue: 0.16)
    static let fallTint = Color(red: 0.42, green: 0.50, blue: 1.0)

    /// The Pokemon itself. Showdown's pixel sprite -- its back for your side,
    /// its front for theirs -- when that style is on and the sprite has
    /// arrived; the illustration otherwise, turned to face across the field
    /// on your side, and always in a still.
    @ViewBuilder func fighterSprite(_ form: Form, mine: Bool, side: CGFloat) -> some View {
        if usesPixelSprites, let frames = pixels.frames(for: form, back: mine) {
            PixelSpriteView(frames: frames).frame(width: side, height: side)
        } else {
            SpriteImage(form: form, side: side)
                .scaleEffect(x: mine ? -1 : 1, y: 1)
        }
    }

    // MARK: - The readouts

    /// The four Pokemon's readouts, kept out of the scene: yours stacked in
    /// the top-left corner, on your side of the field and above your Pokemon
    /// rather than on their feet; theirs in the bottom-right, on theirs.
    /// Each carries the Pokemon's own icon so the panel and the sprite read
    /// as one, and both stacks run the way the picture does, left to right.
    /// Name, condition, health, and every stat change as a chip that says the
    /// number. A click opens the field's card, with the Speed reading, the
    /// likely item and everything else it used to show.
    func readouts(_ board: Board, stage: MoveTimeline.Stage) -> some View {
        func stack(_ mine: Bool) -> some View {
            let slots = mine ? Array(0..<min(board.activeCount, board.mine.count)) : Seat.farSlotsLeftToRight(board)
            return VStack(alignment: mine ? .leading : .trailing, spacing: 8) {
                ForEach(slots, id: \.self) { slot in
                    let seat = Seat(mine: mine, slot: slot)
                    if let fighter = fighter(at: seat, in: board) {
                        statbar(fighter, seat: seat, stage: stage, board: board)
                    }
                }
            }
        }
        return ZStack {
            stack(true)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            stack(false)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    func statbar(_ fighter: Fighter, seat: Seat, stage: MoveTimeline.Stage, board: Board) -> some View {
        let width: CGFloat = 200
        let health = fighter.share
        let bar: Color = health > 0.5 ? Palette.good : (health > 0.2 ? Palette.warn : Palette.bad)
        let out = !opening || shown.contains("\(seat.mine ? "m" : "t")\(seat.slot)")
        let asked = seat.mine && session.awaitingOrders(board) == seat.slot && !fighter.fainted
        let changed = changedStats(fighter)
        let showing = Binding(get: { detail?.seat == seat }, set: { if !$0, detail?.seat == seat { detail = nil } })
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SpriteImage(form: fighter.build.form, side: 22)
                    .saturation(fighter.fainted ? 0 : 1)
                Text(fighter.build.form.formLabel)
                    .font(.system(size: 11, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                if fighter.pendingMega != nil {
                    Text("M").font(.system(size: 8, weight: .heavy)).frame(width: 14, height: 14)
                        .background(Palette.warn).foregroundStyle(.white).clipShape(Circle())
                } else if fighter.build.form.isMega {
                    Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(Palette.warn)
                }
                Spacer(minLength: 0)
                if fighter.status != .none {
                    Text(Self.shortStatus(fighter.status))
                        .font(.system(size: 8, weight: .heavy)).kerning(0.3)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(statusTint(fighter.status), in: RoundedRectangle(cornerRadius: 3))
                }
            }
            HStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.hairline).frame(height: 7)
                    GeometryReader { geo in
                        Capsule()
                            .fill(LinearGradient(colors: [bar.opacity(0.75), bar], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(fighter.fainted ? 0 : 3, geo.size.width * health))
                    }
                    .frame(height: 7)
                }
                .frame(height: 7)
                .animation(.easeOut(duration: 0.55), value: fighter.hp)
                Text("\(fighter.hp)/\(fighter.maxHP)")
                    .font(.system(size: 10, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
            if !changed.isEmpty || fighter.isConfused {
                HStack(spacing: 4) { stageChips(fighter, changed: changed) }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(width: width, alignment: .leading)
        .background(Palette.cardOnField.opacity(fighter.fainted ? 0.5 : 0.92))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(asked ? Palette.accent : .white.opacity(0.12), lineWidth: asked ? 1.5 : 1))
        .shadow(color: asked ? Palette.accent.opacity(0.55) : .black.opacity(0.3), radius: asked ? 8 : 5, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture { detail = DetailSeat(seat: seat) }
        .popover(isPresented: showing, arrowEdge: seat.mine ? .trailing : .leading) {
            fighterCard(fighter, mine: seat.mine, slot: seat.slot, field: board.field,
                        tailwind: seat.mine ? board.myTailwind > 0 : board.theirTailwind > 0,
                        trickRoom: board.trickRoom > 0)
                .padding(10)
        }
        .help("Click for the card: Speed on the field, the likely item, stages.")
        .opacity(out ? 1 : 0)
    }

    /// A stat change as a chip that says the number: Atk -1, SpA +2. Green up,
    /// red down; confusion beside them, since it is the other thing a
    /// Pokemon carries that changes what its next move does.
    @ViewBuilder func stageChips(_ fighter: Fighter, changed: [Stat]) -> some View {
        ForEach(changed, id: \.self) { stat in
            let stage = fighter.build.boosts[stat.rawValue]
            Text("\(stat.short) \(stage > 0 ? "+" : "")\(stage)")
                .font(.system(size: 9, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background((stage > 0 ? Palette.good : Palette.bad).opacity(0.85), in: Capsule())
        }
        if fighter.isConfused {
            Text("Confused")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Palette.warn.opacity(0.85), in: Capsule())
        }
    }

    static func shortStatus(_ status: Ailment) -> String {
        switch status {
        case .burn: return "BRN"
        case .paralysis: return "PAR"
        case .poison: return "PSN"
        case .badPoison: return "TOX"
        case .sleep: return "SLP"
        case .freeze: return "FRZ"
        case .none: return ""
        }
    }
}
