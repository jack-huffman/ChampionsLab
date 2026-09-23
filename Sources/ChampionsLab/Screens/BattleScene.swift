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
    /// Which of Showdown's two sets the battle is drawn in.
    ///
    /// A snapshot draws them too. It used to be held to the illustrations on
    /// the grounds that a fetched picture cannot be compared against last
    /// week's -- but nothing compares these to anything: they are rendered
    /// for a look at the screens, and a shot of a battle drawn in art nobody
    /// sees any more is a shot of an app that does not exist. The renderer
    /// falls back to the illustration on its own where a sprite has not
    /// arrived, so a machine with no network still gets a picture.
    var look: PixelSprites.Style {
        PixelSprites.Style.chosen(spriteStyle)
    }
    /// Kept for the geometry, which is laid out differently for a sprite than
    /// for an illustration whichever of Showdown's sets it came from.
    var usesPixelSprites: Bool { look != .illustrated }

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
            // The balls, over the platforms and under everything that is said.
            //
            // Two things throw one: the opening, which is sequenced a seat at
            // a time and says when each ball leaves the hand, and a switch
            // mid-turn, which the playback notices by a slot changing hands.
            ForEach(seatsInDrawOrder(board), id: \.self) { seat in
                let key = "\(seat.mine ? "m" : "t")\(seat.slot)"
                let home = stage.home(seat)
                let side = 96 * stage.scale(at: home.z, pixelSprite: usesPixelSprites)
                // Going: whoever was standing here before this step, drawn by
                // the effect because the board has already given the slot away.
                if let leftID = playback.departing[seat], recalled[seat] != leftID,
                   let left = store.formsByID[leftID] {
                    RecallEffect(centre: stage.project(home), side: side, mine: seat.mine) {
                        recalled[seat] = leftID
                    } sprite: {
                        // The same sprite the field had a moment ago: its back
                        // on your side, in whichever of Showdown's sets the
                        // battle is set to.
                        fighterSprite(left, mine: seat.mine, side: side * 0.92,
                                      shiny: wasShiny(leftID, mine: seat.mine, board: board))
                    }
                    .id("recall-\(key)-\(leftID)")
                }
                // Winding a move up, which is not throwing one.
                if playback.charging.contains(seat) {
                    ChargeGlow(centre: stage.project(home), side: side)
                        .id("charge-\(key)-\(playback.hitNumber)")
                }
                // Becoming something else, which is not arriving: a Mega
                // Evolution gets the light rather than the ball.
                if playback.transforming.contains(seat),
                   let fighter = fighter(at: seat, in: board), !fighter.fainted {
                    MegaEvolveEffect(centre: stage.project(home), side: side) {
                        BattleAudio.shared.cry(fighter.build.form)
                    }
                    .id("mega-\(key)-\(fighter.build.form.id)")
                }
                // And coming, once there is room for it.
                let coming = opening ? shown.contains(key)
                                     : (playback.arriving.contains(seat)
                                        && (playback.departing[seat] == nil
                                            || recalled[seat] == playback.departing[seat]))
                if coming, let fighter = fighter(at: seat, in: board), !fighter.fainted {
                    SendOutEffect(centre: stage.project(home), side: side, fromMine: seat.mine) {
                        BattleAudio.shared.cry(fighter.build.form)
                        // The ball is open, so the Pokemon may come out of it.
                        // Showdown starts the sprite on the same beat.
                        emerged.insert(seat)
                    }
                    .id("ball-\(key)-\(fighter.build.form.id)")
                    if fighter.build.shiny, opening ? landed.contains(key) : true {
                        ShinySparkle(centre: stage.project(home), side: side)
                            .id("shine-\(key)-\(fighter.build.form.id)")
                    }
                }
            }
            // The screens, standing in front of the side each protects, in
            // the client's own order and at its own depths -- so a side
            // running two of them shows both.
            ForEach([true, false], id: \.self) { mine in
                let screens = mine ? board.myScreens : board.theirScreens
                let up: [(BattleScreen.Kind, Int)] = [
                    (.auroraVeil, screens.auroraVeil), (.reflect, screens.reflect),
                    (.safeguard, screens.safeguard), (.lightScreen, screens.lightScreen),
                ].filter { $0.1 > 0 }
                ForEach(up, id: \.0.rawValue) { kind, _ in
                    let at = wall(kind, mine: mine, stage: stage)
                    BattleScreen(kind: kind, centre: at.centre,
                                 width: at.width, height: at.height)
                        .id("screen-\(mine ? "m" : "t")-\(kind.rawValue)")
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
        // A new set of arrivals is a new set of balls to wait for. Without
        // this the second time a Pokemon came out at a seat it was already
        // marked as having come out, and skipped straight to standing there.
        .onChange(of: playback.arriving) { _ in emerged = [] }
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
        // Still being recalled: the slot belongs to whoever is coming in, but
        // the one going out is still on screen and this one waits its turn.
        let waiting = playback.departing[seat] != nil
            && recalled[seat] != playback.departing[seat]
        // Out of its ball, or still inside it.
        //
        // The opening waited for `landed` and the rest of the game waited for
        // nothing, so a Pokemon switched in mid-battle stood there at full
        // size while its own ball was still in flight towards it -- and then
        // the ball arrived and burst on top of it. Both now wait for the ball
        // to open.
        let arriving = !opening && playback.arriving.contains(seat)
        let out = (opening ? landed.contains("\(seat.mine ? "m" : "t")\(seat.slot)")
                           : (!arriving || emerged.contains(seat)))
            && !waiting
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
            fighterSprite(fighter.build.form, mine: seat.mine, side: side * 0.92,
                          shiny: fighter.build.shiny)
                .offset(y: fighter.fainted ? side * 0.12 : (pixel ? 0 : bob))
                .opacity(fighter.fainted ? 0.2 : 1)
                .saturation(fighter.fainted ? 0 : 1)
                .scaleEffect(fighter.fainted ? 0.82 : (hit ? 1.08 : 1))
                .shadow(color: hit ? Palette.bad.opacity(0.6) : .clear, radius: 10)
                .animation(.spring(response: 0.32, dampingFraction: 0.5), value: hit)
                .animation(.easeOut(duration: 0.35), value: fighter.fainted)
                // A Pokemon cries twice in its life on the field: once when
                // it is sent out, once when it goes down. Showdown plays both
                // from the same place, and the second is what makes a faint
                // land as a loss rather than a sprite quietly fading out.
                // The value only arrives here when it changes, so becoming
                // true is the moment of going down and nothing else.
                .onChange(of: fighter.fainted) { down in
                    if down { BattleAudio.shared.cry(fighter.build.form) }
                }
            // The shield, in front of the Pokemon it covers and thin enough to
            // see it through; the substitute's ring the same.
            if guarding(fighter) {
                // The client's own panel, not a bubble in the app's accent:
                // #DD88DD on #AA66AA, a hundred by seventy of its units, and
                // it flares every time it turns something away.
                ProtectShield(width: side * 1.05, height: side * 0.74,
                              flares: playback.blocked.contains(seat) ? playback.hitNumber : 0)
                    .offset(y: -side * 0.06)
                    // It has to be seen coming down. A Protect lasts the turn
                    // and no longer, and the panel simply stopped existing on
                    // the next board -- which on screen is not a shield
                    // dropping, it is a shield that was never there. Out the
                    // way it came in: fading as it shrinks.
                    .transition(.asymmetric(insertion: .opacity,
                                            removal: .scale(scale: 0.85).combined(with: .opacity)))
            } else if fighter.substitute > 0, !fighter.fainted {
                Circle()
                    .strokeBorder(Palette.dim.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: side * 0.98, height: side * 0.98)
            }
            if rising { StatArrows(up: true, tint: Self.riseTint, side: side * 0.9).transition(.opacity) }
            if falling { StatArrows(up: false, tint: Self.fallTint, side: side * 0.9).transition(.opacity) }
        }
        // Hidden here rather than at the end, which is the whole of an
        // Intimidate that nobody saw: the overlays below are attached after
        // this, so what is being *said* about a Pokemon stays on screen while
        // the Pokemon itself is still inside its ball. Putting the opacity on
        // the outside took the ability's name and the stat arrows down with
        // the sprite, and a switch-in takes the best part of a second.
        // Showdown's animSummon, which is a shape rather than a fade. The
        // Pokemon starts at nothing, just under where it will stand; it grows
        // as it rises, goes up past its own feet, and drops back into them.
        // The client spends four tenths of a second on the rise and three on
        // the settle, and a spring underdamped enough to overshoot is the
        // same curve written the way SwiftUI writes one.
        //
        // It used to be a scale from a fifth to full with no animation on it
        // at all, which is not a curve, it is a cut.
        .opacity(out ? 1 : 0)
        .scaleEffect(out ? 1 : 0.01)
        .offset(y: out ? 0 : side * 0.16)
        .animation(reduceMotion ? .easeOut(duration: 0.12)
                                : .spring(response: 0.42, dampingFraction: 0.58), value: out)
        // The shield's own coming and going. A transition only plays when the
        // change that causes it is animated, and a new board simply arriving
        // is not an animation -- so the panel popped out of existence at the
        // end of the turn instead of dropping.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: guarding(fighter))
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
                // Where the number would have been. A move that does nothing
                // and a move that was never aimed here look the same on a
                // field that says nothing, and one of them is a decision
                // somebody got wrong.
                if playback.missed.contains(seat) {
                    Text("MISS")
                        .font(.system(size: max(9, 8 * stage.k), weight: .black, design: .rounded))
                        .kerning(0.9)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color(red: 0.60, green: 0.44, blue: 0.26)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                        .transition(.asymmetric(insertion: .scale(scale: 0.5).combined(with: .opacity),
                                                removal: .opacity))
                        .id(playback.hitNumber)
                }
                if playback.untouched.contains(seat) {
                    Text("IMMUNE")
                        .font(.system(size: max(9, 8 * stage.k), weight: .black, design: .rounded))
                        .kerning(0.9)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color(red: 0.36, green: 0.42, blue: 0.52)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                        .transition(.asymmetric(insertion: .scale(scale: 0.5).combined(with: .opacity),
                                                removal: .opacity))
                        .id(playback.hitNumber)
                }
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
                            Text("\(Stage(rawValue: change.stat)?.short ?? "") \(change.delta > 0 ? "+" : "")\(change.delta)")
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
                // An item that did something, with its own picture on it.
                // Abilities wear a wand; an item wears itself, which is the
                // fastest way to tell the two apart at a glance.
                if let used = playback.items[seat], !used.isEmpty {
                    ForEach(used, id: \.self) { name in
                        HStack(spacing: 4) {
                            ItemIcon(name: name, side: max(11, 10 * stage.k))
                            Text(name).font(.system(size: max(10, 9 * stage.k), weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(red: 0.13, green: 0.10, blue: 0.06).opacity(0.94)))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color(red: 0.93, green: 0.72, blue: 0.32).opacity(0.85),
                                          lineWidth: 1))
                        .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                    }
                    .transition(.asymmetric(insertion: .scale(scale: 0.7).combined(with: .opacity),
                                            removal: .opacity))
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
        .position(at)
        .allowsHitTesting(false)
    }

    /// Whether the one that just left was registered shiny. It is on the
    /// bench now, so it is found by the form it is: the only way it would be
    /// wrong is a team carrying the same Pokemon twice, which the species
    /// clause forbids.
    func wasShiny(_ formID: String, mine: Bool, board: Board) -> Bool {
        (mine ? board.mine : board.theirs)
            .first { $0.build.form.id == formID }?.build.shiny ?? false
    }

    /// The colours of a stage rising and falling, chosen to be told apart
    /// by most kinds of colour vision; the arrows' direction says it too.
    static let riseTint = Color(red: 1.0, green: 0.56, blue: 0.16)
    static let fallTint = Color(red: 0.42, green: 0.50, blue: 1.0)

    /// The Pokemon itself. Showdown's pixel sprite -- its back for your side,
    /// its front for theirs -- when that style is on and the sprite has
    /// arrived; the illustration otherwise, turned to face across the field
    /// on your side, and always in a still.
    @ViewBuilder func fighterSprite(_ form: Form, mine: Bool, side: CGFloat,
                                    shiny: Bool = false) -> some View {
        // The sprite for this side, and only ever that side's: ours seen from
        // behind, theirs facing us.
        //
        // There used to be a fallback here -- no back sprite, so borrow the
        // front -- on the theory that it covered the moment before a fetch
        // landed. It covered rather more than that. Sixteen of this game's
        // eighty-two Megas have no back sprite anywhere on Showdown, not
        // animated and not still, because they are Megas this game invented:
        // Mega Baxcalibur, Mega Staraptor, the three Z Megas, Mega Golisopod
        // and ten more. For those the borrowed front was not a stand-in for
        // a second, it was the sprite, for the whole game -- a Pokemon of
        // yours standing on your side of the field looking straight at you.
        //
        // Showdown does not do this. Its index records which *facings* a set
        // has, it skips a set whose entry for that facing is missing, and it
        // goes on to the Gen 5 still keeping the `-back` on the directory. It
        // never once substitutes a front for a back. Neither does this now:
        // where Showdown has no back, the app's own render stands in, and
        // that one is mirrored to face across the field.
        let facing = pixels.frames(for: form, back: mine, shiny: shiny, style: look)
        if let frames = facing {
            // At its own size, not squeezed into everybody's box. A Joltik is
            // small and a Staraptor has a wingspan, and the client draws them
            // that way.
            //
            // Anchored by its feet, which is the half that letting them differ
            // in size made necessary: a seat is a point on the ground, a view
            // is centred on the point it is given, and a sprite half again as
            // tall as the box therefore hung a quarter of the box below the
            // floor. Every big Pokemon was standing through the platform it
            // was meant to be standing on. Lifting it by half the difference
            // puts its bottom edge back where the shadow is.
            PixelSpriteView(frames: frames)
                .frame(width: side * frames.relative, height: side * frames.relative)
                .offset(y: -(frames.relative - 1) / 2 * side)
        } else {
            SpriteImage(form: form, side: side, shiny: shiny)
                .scaleEffect(x: mine ? -1 : 1, y: 1)
        }
    }

    /// Where a side's screen stands, and how big.
    ///
    /// The client hangs one sprite per side at the side's own anchor, a
    /// hundred by fifty of its units, with `z` pulled toward the viewer by
    /// fourteen to twenty-three depending on which screen it is. Here the
    /// anchor is the middle of the two seats on that side, which is the same
    /// place; the depth comes off the kind so the four stack rather than
    /// overlap into one muddy colour.
    func wall(_ kind: BattleScreen.Kind, mine: Bool,
              stage: MoveTimeline.Stage) -> (centre: CGPoint, width: CGFloat, height: CGFloat) {
        let seats = [Seat(mine: mine, slot: 0), Seat(mine: mine, slot: 1)]
        let homes = seats.map { stage.home($0) }
        let x = (homes[0].x + homes[1].x) / 2
        let y = (homes[0].y + homes[1].y) / 2
        // Toward the viewer from the Pokemon it covers, which is `behind(-n)`
        // in the client: nearer on your side of the field and nearer on
        // theirs too, because a screen is between the Pokemon and whatever is
        // being thrown at them.
        let z = homes[0].z - kind.depth
        let at = stage.project(SIMD3(x, y - 14, z))
        let unit = stage.scale(at: z)
        return (at, 118 * unit, 34 * unit)
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
                // No sprite: the Pokemon it names is standing on the field a
                // few inches below, drawn ten times the size. What the card
                // can say that the field cannot is what it *is* -- and after
                // a Soak or a Mega Evolution that is not what the dex printed,
                // so these are the types it has right now.
                Text(fighter.build.form.formLabel)
                    .font(.system(size: 11, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                HStack(spacing: 2) {
                    ForEach(fighter.types) { TypeIcon(type: $0, side: 13) }
                }
                .saturation(fighter.fainted ? 0 : 1)
                .opacity(fighter.fainted ? 0.5 : 1)
                // Only what it has become. Holding a stone is not a state
                // worth a badge on every card: the deck already offers the
                // toggle to the one Pokemon that can use it, and the marker
                // said the same thing a second time in a smaller place.
                if fighter.build.form.isMega {
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
