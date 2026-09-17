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

    @ViewBuilder func battleScene(_ board: Board, size: CGSize, tint: Color) -> some View {
        let stage = stageFor(size, board: board)
        ZStack {
            sceneGround(stage: stage, tint: tint)
            ForEach(seatsInDrawOrder(board), id: \.self) { seat in
                if let fighter = fighter(at: seat, in: board) {
                    scenePokemon(fighter, seat: seat, stage: stage, board: board)
                }
            }
            if let scene {
                ChoreographyLayer(scene: scene)
            }
            ForEach(seatsInDrawOrder(board), id: \.self) { seat in
                if let fighter = fighter(at: seat, in: board) {
                    statbar(fighter, seat: seat, stage: stage, board: board)
                }
            }
        }
        .modifier(QuakeEffect(progress: moveClock, shakes: tracks?.shakes ?? [], duration: tracks?.duration ?? 1))
        // The playback places a recipe on the scene, so it has to know how
        // the scene is laid out -- and again whenever that changes.
        .onAppear { playback.stage(stage) }
        .onChange(of: size) { new in playback.stage(stageFor(new, board: board)) }
        .onChange(of: spriteStyle) { _ in playback.stage(stageFor(size, board: board)) }
        .onChange(of: board.activeCount) { _ in playback.stage(stageFor(size, board: board)) }
    }

    /// The ground: a platform under each side, in perspective, in the field's
    /// colour. The client's backdrops are photographs it owns; this is ours.
    func sceneGround(stage: MoveTimeline.Stage, tint: Color) -> some View {
        let k = stage.k, o = stage.origin
        func platform(centre: CGPoint, width: CGFloat, height: CGFloat, strength: Double) -> some View {
            Ellipse()
                .fill(RadialGradient(colors: [tint.opacity(0.28 * strength), tint.opacity(0.10 * strength),
                                              Palette.canvas.opacity(0.0)],
                                     center: .center, startRadius: 0, endRadius: width / 2))
                .overlay(Ellipse().strokeBorder(tint.opacity(0.22 * strength), lineWidth: 1))
                .frame(width: width, height: height)
                .position(centre)
        }
        return ZStack {
            // The horizon, faint, where the far platform sits.
            LinearGradient(colors: [tint.opacity(0.10), .clear, tint.opacity(0.05)],
                           startPoint: .top, endPoint: .bottom)
            platform(centre: CGPoint(x: o.x + (stage.singles ? 430 : 412) * k, y: o.y + 150 * k),
                     width: (stage.singles ? 150 : 230) * k, height: 46 * k, strength: 0.8)
            platform(centre: CGPoint(x: o.x + (stage.singles ? 210 : 238) * k, y: o.y + 272 * k),
                     width: (stage.singles ? 230 : 340) * k, height: 70 * k, strength: 1)
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
                    .fill(RadialGradient(colors: [.black.opacity(0.42), .clear],
                                         center: .center, startRadius: 1, endRadius: side * 0.36))
                    .frame(width: side * 0.78, height: side * 0.2)
                    .offset(y: side * 0.36)
            }
            if asked {
                Ellipse()
                    .strokeBorder(Palette.accent, lineWidth: 2)
                    .shadow(color: Palette.accent.opacity(0.8), radius: 8)
                    .frame(width: side * 0.86, height: side * 0.26)
                    .offset(y: side * 0.36)
            }
            if guarding(fighter) {
                Circle()
                    .fill(RadialGradient(colors: [Palette.accent.opacity(0.04), Palette.accent.opacity(0.28)],
                                         center: .center, startRadius: side * 0.15, endRadius: side * 0.5))
                    .overlay(Circle().strokeBorder(Palette.accent.opacity(0.75), lineWidth: 1.5))
                    .frame(width: side * 0.98, height: side * 0.98)
                    .transition(.scale.combined(with: .opacity))
            } else if fighter.substitute > 0, !fighter.fainted {
                Circle()
                    .strokeBorder(Palette.dim.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: side * 0.98, height: side * 0.98)
            }
            fighterSprite(fighter.build.form, mine: seat.mine, side: side * 0.92)
                .offset(y: fighter.fainted ? side * 0.12 : (pixel ? 0 : bob))
                .opacity(fighter.fainted ? 0.2 : 1)
                .saturation(fighter.fainted ? 0 : 1)
                .scaleEffect(fighter.fainted ? 0.82 : (hit ? 1.08 : 1))
                .shadow(color: hit ? Palette.bad.opacity(0.6) : .clear, radius: 10)
                .animation(.spring(response: 0.32, dampingFraction: 0.5), value: hit)
                .animation(.easeOut(duration: 0.35), value: fighter.fainted)
        }
        .frame(width: side, height: side)
        .overlay(alignment: .top) {
            if let lost = damage[seat], lost > 0 {
                Text("-\(lost)")
                    .font(.system(size: max(15, 13 * stage.k), weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: Palette.bad, radius: 6)
                    .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                    .offset(y: -6)
                    .transition(.asymmetric(insertion: .offset(y: 14).combined(with: .opacity),
                                            removal: .offset(y: -12).combined(with: .opacity)))
                    .allowsHitTesting(false)
            }
        }
        .modifier(carried(seat))
        .opacity(out ? 1 : 0)
        .scaleEffect(out ? 1 : 0.2)
        .position(at)
        .allowsHitTesting(false)
    }

    /// The Pokemon itself. Showdown's pixel sprite -- its back for your side,
    /// its front for theirs -- when that style is on and the sprite has
    /// arrived; the illustration otherwise, turned to face across the field
    /// on your side, and always in a still.
    @ViewBuilder func fighterSprite(_ form: Form, mine: Bool, side: CGFloat) -> some View {
        if usesPixelSprites, let image = pixels.image(for: form, back: mine) {
            PixelSpriteView(image: image).frame(width: side, height: side)
        } else {
            SpriteImage(form: form, side: side)
                .scaleEffect(x: mine ? -1 : 1, y: 1)
        }
    }

    // MARK: - The statbar

    /// Name, condition, stages and health over each Pokemon, where the client
    /// puts it: eighty units left of the sprite and seventy-odd above, the
    /// far row's a little higher. A click opens the field's card, with the
    /// Speed reading, the likely item and everything else it used to show.
    func statbar(_ fighter: Fighter, seat: Seat, stage: MoveTimeline.Stage, board: Board) -> some View {
        let k = stage.k
        let at = stage.project(stage.home(seat))
        // The client's placement, then the second slot's bar staggered higher
        // and pushed outward: in a double battle the two sprites stand seventy
        // units apart, which is less than a bar is wide.
        let above = 73.0 + (seat.mine ? 20.0 - 7.0 * Double(seat.slot) : 30.0 + 17.0 * Double(seat.slot))
            + 24.0 * Double(seat.slot)
        let outward: CGFloat = seat.slot == 1 ? (seat.mine ? 1 : -1) * 44 * k : 0
        let width: CGFloat = 150, height: CGFloat = 42
        let grow = min(1.15, max(0.85, k))
        let health = fighter.share
        let bar: Color = health > 0.5 ? Palette.good : (health > 0.2 ? Palette.warn : Palette.bad)
        let out = !opening || shown.contains("\(seat.mine ? "m" : "t")\(seat.slot)")
        let asked = seat.mine && session.awaitingOrders(board) == seat.slot && !fighter.fainted
        let changed = changedStats(fighter)
        let showing = Binding(get: { detail?.seat == seat }, set: { if !$0, detail?.seat == seat { detail = nil } })
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
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
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline).frame(height: 6)
                GeometryReader { geo in
                    Capsule()
                        .fill(LinearGradient(colors: [bar.opacity(0.75), bar], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(fighter.fainted ? 0 : 3, geo.size.width * health))
                }
                .frame(height: 6)
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.55), value: fighter.hp)
            HStack(spacing: 4) {
                Text("\(fighter.hp)/\(fighter.maxHP)")
                    .font(.system(size: 9, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !changed.isEmpty || fighter.isConfused {
                    stages(fighter, changed: changed)
                }
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .frame(width: width, height: height)
        .background(Palette.cardOnField.opacity(fighter.fainted ? 0.55 : 0.94))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(asked ? Palette.accent : .white.opacity(0.14), lineWidth: asked ? 1.5 : 1))
        .shadow(color: asked ? Palette.accent.opacity(0.6) : .black.opacity(0.3), radius: asked ? 7 : 5, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture { detail = DetailSeat(seat: seat) }
        .popover(isPresented: showing, arrowEdge: seat.mine ? .top : .bottom) {
            fighterCard(fighter, mine: seat.mine, slot: seat.slot, field: board.field,
                        tailwind: seat.mine ? board.myTailwind > 0 : board.theirTailwind > 0,
                        trickRoom: board.trickRoom > 0)
                .padding(10)
        }
        .help("Click for the card: Speed on the field, the likely item, stages.")
        .scaleEffect(grow, anchor: .center)
        .opacity(out ? 1 : 0)
        .position(x: at.x - 80 * k + outward + width * grow / 2,
                  y: at.y - above * k + height * grow / 2)
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
