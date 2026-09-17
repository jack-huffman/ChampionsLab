//  BattleFieldView.swift
//  The battle, on screen: the arena, the cards, the bench, and the panels.
//
//  Everything you look at while a game is on. The two sides' cards with their
//  health, stages and status, leaning into physical moves and flinching when
//  hit; the field's weather and terrain and their clocks; the benches; the side
//  panel with the engine's read, theirs, the review and the log; and, while the
//  leads are coming out, the opening card. Below it the deck or the replacement
//  picker takes over, and above it the stepper scrubs the turn that just played.
//
//  It reads the session for the game and the playback for the turn in flight.
//  The four things it reads from the screen around it are the opening
//  animation -- the flash, who has come out, what is being called out -- and
//  whether this is singles, which decides where the seats are. The one thing it
//  can do to the screen, once a game is over, is go back to Team Preview, and
//  that goes back up.

import SwiftUI

struct BattleFieldView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.snapshotMode) private var snapshotMode
    @ObservedObject var session: BattleSession
    @ObservedObject var playback: TurnPlayback
    let opening: Bool
    let startFlash: Bool
    let shown: Set<String>
    let callout: String?
    let singles: Bool
    let onBackToPreview: () -> Void

    typealias TurnReview = BattleSession.TurnReview
    typealias Panel = BattleSession.Panel
    @State private var bob: CGFloat = 0
    private var board: Board? { get { session.board } nonmutating set { session.board = newValue } }
    private var log: [String] { get { session.log } nonmutating set { session.log = newValue } }
    private var thinking: Bool { get { session.thinking } nonmutating set { session.thinking = newValue } }
    private var mySide: [String] { get { session.mySide } nonmutating set { session.mySide = newValue } }
    private var theirSide: [String] { get { session.theirSide } nonmutating set { session.theirSide = newValue } }
    private var searchNote: String { get { session.searchNote } nonmutating set { session.searchNote = newValue } }
    private var finished: String? { get { session.finished } nonmutating set { session.finished = newValue } }
    private var history: [(board: Board, log: [String], turn: Int)] { get { session.history } nonmutating set { session.history = newValue } }
    private var review: [BattleSession.TurnReview] { get { session.review } nonmutating set { session.review = newValue } }
    private var explaining: BattleSession.TurnReview? { get { session.explaining } nonmutating set { session.explaining = newValue } }
    private var sending: [Int] { get { session.sending } nonmutating set { session.sending = newValue } }
    private var panel: BattleSession.Panel { get { session.panel } nonmutating set { session.panel = newValue } }
    private var replay: [Board.Step] { get { playback.replay } nonmutating set { playback.replay = newValue } }
    private var at: Int { get { playback.at } nonmutating set { playback.at = newValue } }
    private var replayBoard: Board? { get { playback.replayBoard } nonmutating set { playback.replayBoard = newValue } }
    private var flourish: Flourish? { get { playback.flourish } nonmutating set { playback.flourish = newValue } }
    private var flourishFrom: Date { get { playback.flourishFrom } nonmutating set { playback.flourishFrom = newValue } }
    private var damage: [Seat: Int] { get { playback.damage } nonmutating set { playback.damage = newValue } }
    private var lunging: Seat? { get { playback.lunging } nonmutating set { playback.lunging = newValue } }
    private var lungeBy: CGSize { get { playback.lungeBy } nonmutating set { playback.lungeBy = newValue } }
    private var struck: Set<Int> { get { playback.struck } nonmutating set { playback.struck = newValue } }
    private var struckTheirs: Set<Int> { get { playback.struckTheirs } nonmutating set { playback.struckTheirs = newValue } }

    var body: some View {
        if let board { field(board) } else { openingCard.padding(14) }
    }

    private func field(_ live: Board) -> some View {
        // Mid-replay the field shows the moment being described, not where the
        // turn ended up.
        let board = replay.indices.contains(at)
            ? rewound(replayBoard ?? live, to: replay[at]) : live
        // Half the window is the field, half is what you are doing about it,
        // and the deck on the left is as tall as the readings on the right.
        // A turn should never need scrolling to play.
        return GeometryReader { geo in
            let gap: CGFloat = 12
            let banner: CGFloat = finished == nil ? 0 : 40
            let half = (geo.size.height - gap - (banner > 0 ? banner + gap : 0)) / 2
            VStack(alignment: .leading, spacing: gap) {
                if let finished {
                    Card(padding: 10) { Label(finished, systemImage: "flag.checkered")
                        .font(.system(size: 14, weight: .semibold)) }
                        .frame(height: banner)
                }
                arena(board).frame(height: half)
                HStack(alignment: .top, spacing: gap) {
                    Group {
                        if opening { openingCard }
                        else if !replay.isEmpty { TurnStepper(session: session, playback: playback) }
                        else if !sending.isEmpty, finished == nil { ReplacementView(session: session, board: board) }
                        else if finished == nil { CommandDeckView(session: session, playback: playback, board: board) }
                        else { afterGame }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    // Two fifths of the width. It was a fixed 340 points,
                    // which on a wide window left the engine's reasoning in a
                    // narrow column wrapping every other word while the
                    // orders beside it had room to spare. A floor keeps it
                    // readable if the window is dragged narrow.
                    sidePanel
                        .frame(width: Swift.max(340, geo.size.width * 0.4))
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(height: half)
            }
        }
        .padding(14)
        // Leaving the screen stops the turn being played out. The parity audit
        // taught this one: a detached task that outlived the view it belonged
        // to is what made the app stutter, and it was invisible because the
        // work was correct — it was just still going.
        .onAppear {
            guard bob == 0 else { return }
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) {
                bob = -3.5
            }
        }
        .onDisappear { playback.reset() }
    }
    /// While the leads come out and their abilities go off.
    private var openingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Battle start",
                              subtitle: "Both sides send out their leads. Abilities go off in Speed order — the slower weather is the one that stays.")
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(callout ?? (shown.isEmpty ? "Go!" : "Sending out…"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    /// The game is over; what is left to do is look back or go again.
    private var afterGame: some View {
        let worst = review.filter { $0.lost > 0.05 }.sorted { $0.lost > $1.lost }
        let lost = review.reduce(0) { $0 + $1.lost }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Game over", subtitle: finished ?? "")
                if review.isEmpty {
                    Text("No turns to look back on.").font(.system(size: 11)).foregroundStyle(.tertiary)
                } else if worst.isEmpty {
                    Label(String(format: "Every turn on the engine's line. Nothing left on the table across %d turns.", review.count),
                          systemImage: "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.good)
                } else {
                    Text(String(format: "%.2f left on the table across %d turns. The ones that cost the most:", lost, review.count))
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(worst.prefix(3)) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(String(format: "−%.2f", entry.lost))
                                .font(.system(size: 11, weight: .heavy, design: .rounded)).monospacedDigit()
                                .foregroundStyle(Palette.warn)
                                .frame(width: 44, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Turn \(entry.turn): you \(entry.yours)")
                                    .font(.system(size: 11))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("the engine wanted \(entry.bestLine)")
                                    .font(.system(size: 10)).foregroundStyle(Palette.accent)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Button("Play it again") { session.rewind(to: entry.turn) }
                                .controlSize(.small)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button("Back to Team Preview") { onBackToPreview() }.controlSize(.small)
                    Button("Undo the last turn") { session.undo() }.controlSize(.small)
                        .disabled(history.isEmpty)
                    Button("Every turn") { panel = .review }.controlSize(.small)
                        .disabled(review.isEmpty)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    /// The readings, one at a time: what the engine makes of your turn, what
    /// it believes they are weighing, and what has happened so far.
    private var sidePanel: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(Panel.allCases, id: \.self) { choice in
                        Button { panel = choice } label: {
                            Text(choice.rawValue)
                                .font(.system(size: 11, weight: panel == choice ? .semibold : .medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(panel == choice ? Palette.accent.opacity(0.16) : Color.clear)
                                .foregroundStyle(panel == choice ? AnyShapeStyle(Palette.accent)
                                                                 : AnyShapeStyle(.secondary))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                    if !searchNote.isEmpty, panel == .engine {
                        Text(searchNote).font(.system(size: 9)).foregroundStyle(.quaternary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                Divider()
                MaybeScroll {
                    VStack(alignment: .leading, spacing: 7) {
                        switch panel {
                        case .engine:
                            reading(mySide, Palette.accent,
                                    empty: thinking ? "Searching…" : "Press Think, or give orders: the engine searches when a turn begins.")
                        case .theirs:
                            reading(theirSide, Palette.warn,
                                    empty: "What they are probably weighing, and what they cannot see.")
                        case .review:
                            reviewPanel
                        case .log:
                            EmptyView()
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .opacity(panel == .log ? 0 : 1)
                .frame(maxHeight: panel == .log ? 0 : nil)
                if panel == .log { logPanel }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    /// Every turn of the game, marked. While a game is running it reads in
    /// order; once it is over the worst turns come first, because that is what
    /// there is to learn from. Clicking one takes the game back to it.
    @ViewBuilder
    private var reviewPanel: some View {
        if review.isEmpty {
            Text("Nothing to review yet. Every turn you play is marked here: what you did, what it was worth, and what the engine would have done instead.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let lost = review.reduce(0) { $0 + $1.lost }
            let ordered = finished == nil ? review : review.sorted { $0.lost > $1.lost }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(String(format: "%.2f", lost))
                        .font(.system(size: 15, weight: .heavy, design: .rounded)).monospacedDigit()
                        .foregroundStyle(lost > 0.5 ? Palette.warn : Palette.good)
                    Text("left on the table across \(review.count) turn\(review.count == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .help("The sum of what each turn cost against the line the engine wanted. Nought is perfect play by its own lights.")
                ForEach(ordered) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Button { session.rewind(to: entry.turn) } label: { reviewRow(entry) }
                            .buttonStyle(.plain)
                            .help("Take the game back to turn \(entry.turn) and play it differently")
                        HStack(spacing: 6) {
                            Button {
                                explaining = entry
                            } label: {
                                Label("Explain this turn", systemImage: "text.magnifyingglass")
                                    .font(.system(size: 10))
                            }
                            .controlSize(.small)
                            .help("Why everything happened in the order and the size it did")
                            Spacer(minLength: 0)
                        }
                        .padding(.bottom, 2)
                    }
                }
            }
        }
    }
    private func reviewRow(_ entry: TurnReview) -> some View {
        let bad = entry.lost > 0.05
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("TURN \(entry.turn)")
                    .font(.system(size: 9, weight: .heavy)).kerning(0.5)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text(bad ? String(format: "−%.2f", entry.lost) : "on the line")
                    .font(.system(size: 10, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(bad ? Palette.warn : Palette.good))
            }
            Text(entry.yours).font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Text("they \(entry.theirs)").font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if bad {
                Text("wanted: \(entry.bestLine)")
                    .font(.system(size: 10)).foregroundStyle(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(bad ? Palette.warn.opacity(0.4) : Palette.hairline, lineWidth: 1))
    }
    /// What has happened, oldest at the top and the latest at the bottom where
    /// a conversation puts it, with each turn ruled off from the last. It
    /// follows the newest line on its own.
    /// One thing that happened, with whatever the model had to say about it.
    ///
    /// The turn model already marks a detail by opening the line with two
    /// spaces — "  A critical hit!", "  Spread: x0.75" — and the log used to
    /// render every line as its own identical rounded box, so a turn read as
    /// nine separate events of equal weight. They are one event and its
    /// reasons, and now they look like it.
    private struct LogEntry: Identifiable {
        let id: Int
        let headline: String
        let details: [String]
        let isDivider: Bool
    }

    private var logEntries: [LogEntry] {
        var out: [LogEntry] = []
        for (index, line) in log.enumerated() {
            if line.hasPrefix(BattleSession.dividerMark) {
                out.append(LogEntry(id: index,
                                    headline: String(line.dropFirst()).uppercased(),
                                    details: [], isDivider: true))
                continue
            }
            let detail = line.hasPrefix("  ")
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            // A detail with nothing above it to belong to still has to appear.
            if detail, let last = out.last, !last.isDivider {
                // A spread move works each target out separately, so the same
                // reason arrives once per target: "Spread: x0.75" twice, the
                // terrain halving it twice. Said once is enough.
                guard !last.details.contains(text) else { continue }
                out[out.count - 1] = LogEntry(id: last.id, headline: last.headline,
                                              details: last.details + [text],
                                              isDivider: false)
            } else {
                out.append(LogEntry(id: index, headline: text, details: [], isDivider: false))
            }
        }
        return out
    }
    private var logPanel: some View {
        let entries = logEntries
        let latest = entries.last { !$0.isDivider }?.id
        // The last *entry*, not the last line: a detail line is folded into
        // the entry above it and no longer carries an id of its own, so
        // scrolling to `log.count - 1` would sometimes aim at nothing.
        let bottom = entries.last?.id ?? 0
        let body = VStack(alignment: .leading, spacing: 5) {
            if entries.isEmpty {
                Text("Nothing has happened yet.").font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            ForEach(entries) { entry in
                if entry.isDivider {
                    HStack(spacing: 8) {
                        Rectangle().fill(Palette.hairline).frame(height: 1)
                        Text(entry.headline)
                            .font(.system(size: 9, weight: .heavy)).kerning(1.2)
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                        Rectangle().fill(Palette.hairline).frame(height: 1)
                    }
                    .padding(.vertical, 6)
                    .id(entry.id)
                } else {
                    let live = entry.id == latest
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.headline)
                            .font(.system(size: 11, weight: live ? .semibold : .regular))
                            .foregroundStyle(live ? AnyShapeStyle(.primary)
                                                  : AnyShapeStyle(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                        // The reasons, hung under the thing they explain.
                        ForEach(Array(entry.details.enumerated()), id: \.offset) { _, detail in
                            HStack(alignment: .top, spacing: 6) {
                                Rectangle()
                                    .fill(live ? Palette.accent.opacity(0.45) : Palette.hairline)
                                    .frame(width: 2)
                                Text(detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.leading, 2)
                        }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(live ? Palette.accent.opacity(0.12)
                                     : Palette.surfaceRaised.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .id(entry.id)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)

        return Group {
            if snapshotMode {
                body
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        body
                    }
                    .onAppear { proxy.scrollTo(bottom, anchor: .bottom) }
                    .onChange(of: log.count) { _ in
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(bottom, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
    @ViewBuilder
    private func reading(_ lines: [String], _ tint: Color, empty: String) -> some View {
        if lines.isEmpty {
            Text(empty).font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            HStack(alignment: .top, spacing: 6) {
                Circle().fill(tint.opacity(0.5)).frame(width: 4, height: 4)
                    .padding(.top, 5)
                Text(line).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func guarding(_ fighter: Fighter) -> Bool {
        Self.guarding(fainted: fighter.fainted, isProtected: fighter.isProtected,
                            protectedLast: fighter.protectedLast,
                            duringPlayback: playback.task != nil)
    }
    /// Whether to draw the shield, as a rule rather than as a line inside a
    /// view — this has been wrong in both directions now and is worth pinning.
    ///
    /// A Protect covers the turn it was used on and comes down at the end of
    /// it, so `isProtected` is false by the time the board is handed back.
    /// While the turn is being played out, though, the shield has to be on
    /// screen or a move visibly bounces off nothing — and that is what
    /// `protectedLast` is for. The moment playback ends it must stop counting,
    /// or the shield stays drawn over a Pokémon that is open again.
    static func guarding(fainted: Bool, isProtected: Bool, protectedLast: Bool,
                         duringPlayback: Bool) -> Bool {
        guard !fainted else { return false }
        return isProtected || (duringPlayback && protectedLast)
    }
    /// How far a card leans when it is throwing a physical move: a short step
    /// toward whoever it is hitting, and back.
    private func lunge(_ seat: Seat) -> CGSize {
        lunging == seat ? lungeBy : .zero
    }
    /// Weather thinning out as its clock runs down, so the last turn of a rain
    /// looks like the last turn of a rain. Zero turns left means it was handed
    /// a field and told to hold it, which is full strength.
    private func fade(_ turns: Int) -> Double {
        switch turns {
        case 0:  return 1
        case 1:  return 0.45
        case 2:  return 0.75
        default: return 1
        }
    }
    private func arena(_ board: Board) -> some View {
        let tint: Color = {
            switch board.field.weather {
            case .sun:  return Color(red: 0.95, green: 0.62, blue: 0.20)
            case .rain: return Color(red: 0.30, green: 0.55, blue: 0.90)
            case .sand: return Color(red: 0.80, green: 0.68, blue: 0.36)
            case .snow: return Color(red: 0.62, green: 0.82, blue: 0.92)
            case .none:
                switch board.field.terrain {
                case .grassy:   return Color(red: 0.40, green: 0.74, blue: 0.38)
                case .electric: return Color(red: 0.93, green: 0.82, blue: 0.25)
                case .psychic:  return Color(red: 0.86, green: 0.38, blue: 0.60)
                case .misty:    return Color(red: 0.80, green: 0.56, blue: 0.86)
                case .none:     return Palette.accent
                }
            }
        }()
        let lit = board.field.weather != .none || board.field.terrain != .none
        let singlesGame = board.activeCount == 1
        return GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let lean = h * 0.18
            ZStack {
                // The room the battle happens in, behind everything else. It
                // thins out as the weather runs down, so a rain about to stop
                // looks like one.
                TerrainLayer(terrain: board.field.terrain,
                             strength: fade(board.terrainTurns))
                WeatherLayer(weather: board.field.weather,
                             strength: fade(board.weatherTurns))
                // The line down the middle, leaning the way the versus page does.
                SlantLines(lean: lean, spacing: 72)
                    .stroke(tint.opacity(lit ? 0.09 : 0.05), lineWidth: 1)
                Path { p in
                    p.move(to: CGPoint(x: w / 2 + lean, y: 0))
                    p.addLine(to: CGPoint(x: w / 2 - lean, y: h))
                }
                .stroke(tint.opacity(lit ? 0.5 : 0.28), lineWidth: 1.5)
                Text("VS").font(.system(size: 11, weight: .heavy)).kerning(1)
                    .foregroundStyle(tint.opacity(0.85))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Palette.surface)
                    .clipShape(Capsule())
                    .position(x: w / 2, y: h / 2)

                // Yours: first up and left, second diagonally down and in.
                ForEach(0..<min(board.activeCount, board.mine.count), id: \.self) { slot in
                    let out = !opening || shown.contains("m\(slot)")
                    fighterCard(board.mine[slot], mine: true, slot: slot, field: board.field,
                                tailwind: board.myTailwind > 0, trickRoom: board.trickRoom > 0)
                        .opacity(out ? 1 : 0)
                        .scaleEffect(out ? 1 : 0.4)
                        .offset(lunge(Seat(mine: true, slot: slot)))
                        .position(x: w * Seat.fraction(Seat(mine: true, slot: slot),
                                                                 singles: singlesGame).x,
                                  y: h * Seat.fraction(Seat(mine: true, slot: slot),
                                                                 singles: singlesGame).y)
                }
                // Theirs: first up and left of their side, second down and right.
                ForEach(0..<min(board.activeCount, board.theirs.count), id: \.self) { slot in
                    let out = !opening || shown.contains("t\(slot)")
                    fighterCard(board.theirs[slot], mine: false, slot: slot, field: board.field,
                                tailwind: board.theirTailwind > 0, trickRoom: board.trickRoom > 0)
                        .opacity(out ? 1 : 0)
                        .scaleEffect(out ? 1 : 0.4)
                        .offset(lunge(Seat(mine: false, slot: slot)))
                        .position(x: w * Seat.fraction(Seat(mine: false, slot: slot),
                                                                 singles: singlesGame).x,
                                  y: h * Seat.fraction(Seat(mine: false, slot: slot),
                                                                 singles: singlesGame).y)
                }
                sideState(board, mine: true).position(x: w * 0.25, y: 18)
                sideState(board, mine: false).position(x: w * 0.75, y: 18)
                // The move being used, over the cards: a beam for a special,
                // a burst where a physical one lands, a ring for a status move.
                // Driven off a start date rather than a per-frame @State, so
                // the arena is not rebuilt sixty times a second.
                if let flourish {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { slice in
                        let progress = min(1, max(0, slice.date.timeIntervalSince(flourishFrom)
                                                     / TurnPlayback.flourishSeconds))
                        let place: (Seat) -> CGPoint = {
                            Seat.point($0, w: w, h: h, singles: singlesGame)
                        }
                        ZStack {
                            if flourish.isSpecial {
                                BeamLayer(flourish: flourish, progress: progress, place: place)
                            } else if flourish.isPhysical {
                                ImpactLayer(flourish: flourish, progress: progress, place: place)
                            } else if !flourish.isSwitch {
                                AuraLayer(flourish: flourish, progress: progress, place: place)
                            }
                        }
                    }
                    .allowsHitTesting(false)
                }
                if startFlash {
                    Text("BATTLE START")
                        .font(.system(size: 44, weight: .black)).italic().kerning(2)
                        .foregroundStyle(.white)
                        .shadow(color: tint.opacity(0.9), radius: 24)
                        .shadow(color: .black.opacity(0.7), radius: 6, y: 3)
                        .transition(.scale(scale: 1.6).combined(with: .opacity))
                        .position(x: w / 2, y: h / 2)
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    fieldState(board)
                    if let callout {
                        Text(callout)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(tint.opacity(0.9)))
                            .shadow(color: tint.opacity(0.6), radius: 12, y: 4)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .id(callout)
                    }
                }
                .padding(.top, 10)
            }
            .overlay(alignment: .topLeading) {
                Text("YOURS").font(.system(size: 9, weight: .bold)).kerning(0.6)
                    .foregroundStyle(.tertiary).padding(14)
            }
            .overlay(alignment: .bottomLeading) { bench(board, mine: true).padding(12) }
            .overlay(alignment: .topTrailing) { bench(board, mine: false).padding(12) }
            .overlay(alignment: .bottom) { terrainState(board).padding(.bottom, 10) }
        }
        .background(
            LinearGradient(colors: [tint.opacity(lit ? 0.18 : 0.07),
                                    tint.opacity(lit ? 0.05 : 0.02)],
                           startPoint: .top, endPoint: .bottom)
        )
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(tint.opacity(lit ? 0.45 : 0.18), lineWidth: 1))
        .animation(.easeInOut(duration: 0.4), value: board.field.weather)
        .animation(.easeInOut(duration: 0.4), value: board.field.terrain)
    }
    /// The Pokémon waiting behind a side. Yours are yours to see; theirs are
    /// what has shown itself, question marks for what has not, and the odds
    /// on who is behind them.
    private func bench(_ board: Board, mine: Bool) -> some View {
        let team = mine ? board.mine : board.theirs
        let hiding = !mine && board.hidesTheirBench
        return VStack(alignment: mine ? .leading : .trailing, spacing: 4) {
            if !mine {
                Text("THEIRS").font(.system(size: 9, weight: .bold)).kerning(0.6)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 4) {
                ForEach(Array(team.dropFirst(board.activeCount).enumerated()), id: \.offset) {
                    _, fighter in
                    if hiding && !fighter.seen && !fighter.fainted {
                        // One of the two they brought behind, not yet shown.
                        // What it is stays their business until it walks on.
                        VStack(spacing: 2) {
                            ZStack {
                                Circle().strokeBorder(Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                                    .frame(width: 30, height: 30)
                                Text("?").font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(.tertiary)
                            }
                            Text("hidden").font(.system(size: 8)).foregroundStyle(.tertiary)
                        }
                        .frame(width: 52)
                        .help("They brought something here, but it has not come out yet. The engine plays against the likeliest versions rather than peeking.")
                    } else {
                        // A bench slot said only what it was. Whether it is
                        // healthy, hurt or already gone is the thing you need
                        // when deciding what to send, and it was in the party
                        // screen two clicks away.
                        VStack(spacing: 2) {
                            ZStack {
                                SpriteImage(form: fighter.build.form, side: 30)
                                    .opacity(fighter.fainted ? 0.25 : 1)
                                    .saturation(fighter.fainted ? 0 : 1)
                                if fighter.fainted {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 13, weight: .heavy))
                                        .foregroundStyle(Palette.bad.opacity(0.85))
                                }
                            }
                            if !fighter.fainted {
                                Capsule()
                                    .fill(Palette.hairline)
                                    .frame(width: 30, height: 3)
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(fighter.share > 0.5 ? Palette.good
                                                  : fighter.share > 0.2 ? Palette.warn : Palette.bad)
                                            .frame(width: Swift.max(2, 30 * fighter.share), height: 3)
                                    }
                            }
                            Text(fighter.build.form.formLabel)
                                .font(.system(size: 8)).lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundStyle(fighter.fainted ? .tertiary : .secondary)
                        }
                        .frame(width: 52)
                        .help(fighter.fainted ? "\(fighter.build.form.formLabel) has fainted."
                              : "\(fighter.build.form.formLabel), \(fighter.hp) of \(fighter.maxHP).")
                    }
                }
            }
            if hiding {
                // Who is probably back there, from their six and the two they
                // led with. Weighed the way they would weigh it: by what hurts.
                HStack(spacing: 5) {
                    Text("probably").font(.system(size: 8, weight: .semibold)).kerning(0.3)
                        .foregroundStyle(.tertiary)
                    ForEach(Array(board.theirBenchCandidates.prefix(4).enumerated()), id: \.offset) {
                        _, candidate in
                        HStack(spacing: 3) {
                            SpriteImage(form: candidate.fighter.build.form, side: 16)
                            Text(String(format: "%.0f%%", candidate.chance * 100))
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(candidate.chance >= 0.5 ? AnyShapeStyle(.primary)
                                                                         : AnyShapeStyle(.secondary))
                        }
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Palette.surface)
                        .clipShape(Capsule())
                        .help("\(candidate.fighter.build.form.formLabel): \(Int((candidate.chance * 100).rounded()))% likely to be one of the two behind")
                    }
                }
            }
        }
    }
    /// A colour for each condition, so the word on the name is recognisable
    /// before it is read.
    private func statusTint(_ status: Ailment) -> Color {
        switch status {
        case .burn:      return Color(red: 0.93, green: 0.45, blue: 0.28)
        case .paralysis: return Color(red: 0.95, green: 0.78, blue: 0.20)
        case .poison, .badPoison: return Color(red: 0.72, green: 0.42, blue: 0.85)
        case .sleep:     return Color(red: 0.55, green: 0.60, blue: 0.75)
        case .freeze:    return Color(red: 0.45, green: 0.75, blue: 0.95)
        case .none:      return Palette.dim
        }
    }
    /// The stat changes, as arrows, up the right-hand edge of the card.
    ///
    /// One row per stat in the order they are thought about — Attack, Special
    /// Attack, Defense, Special Defense, Speed — and one arrow per stage, so
    /// two arrows is two stages and there is nothing to read. It used to be
    /// coloured capsules stacked under the name, three to a row, which took as
    /// much room as the Pokémon and had to be parsed rather than seen.
    ///
    /// Confusion stays a word, because it is not a stat and has nowhere to
    /// point. The condition has moved to the end of the name.
    /// Which stats have moved, in the order they are read. Speed last: it is
    /// the one that decides the turn, so it reads at the bottom where the eye
    /// finishes.
    private func changedStats(_ fighter: Fighter) -> [Stat] {
        [.attack, .spAttack, .defense, .spDefense, .speed].filter {
            fighter.build.boosts.indices.contains($0.rawValue)
                && fighter.build.boosts[$0.rawValue] != 0
        }
    }
    private func stages(_ fighter: Fighter, changed: [Stat]) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            ForEach(changed, id: \.rawValue) { stat in
                let stage = fighter.build.boosts[stat.rawValue]
                let up = stage > 0
                HStack(spacing: 1) {
                    Text(stat.short)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    ForEach(0..<min(abs(stage), 6), id: \.self) { _ in
                        Image(systemName: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(up ? Palette.good : Palette.bad)
                    }
                }
                .help("\(stat.short) \(up ? "raised" : "lowered") by \(abs(stage)) stage"
                      + "\(abs(stage) == 1 ? "" : "s") — ×\(String(format: "%.2f", stageMultiplier(stage)))")
            }
            if fighter.isConfused {
                Text("confused")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Color(red: 0.75, green: 0.45, blue: 0.85))
                    .help("Confused for up to \(fighter.confusedFor) more turn"
                          + "\(fighter.confusedFor == 1 ? "" : "s"): one action in three goes "
                          + "into its own face. Switching out clears it.")
            }
        }
    }
    private func stageMultiplier(_ stage: Int) -> Double {
        stage >= 0 ? Double(2 + stage) / 2 : 2 / Double(2 - stage)
    }
    /// The board as it stood at one step of the turn.
    private func rewound(_ board: Board, to step: Board.Step) -> Board {
        var out = board
        for index in out.mine.indices where index < step.myHP.count {
            out.mine[index].hp = step.myHP[index]
            if let form = store.formsByID[step.myForms[index]],
               form.id != out.mine[index].build.form.id {
                out.mine[index].build.form = form
            }
            if index < step.myBoosts.count { out.mine[index].build.boosts = step.myBoosts[index] }
            if index < step.myStatus.count { out.mine[index].status = step.myStatus[index] }
            if index < step.myConfused.count { out.mine[index].confusedFor = step.myConfused[index] ? max(1, out.mine[index].confusedFor) : 0 }
        }
        for index in out.theirs.indices where index < step.theirHP.count {
            out.theirs[index].hp = step.theirHP[index]
            if let form = store.formsByID[step.theirForms[index]],
               form.id != out.theirs[index].build.form.id {
                out.theirs[index].build.form = form
            }
            if index < step.theirBoosts.count { out.theirs[index].build.boosts = step.theirBoosts[index] }
            if index < step.theirStatus.count { out.theirs[index].status = step.theirStatus[index] }
            if index < step.theirConfused.count { out.theirs[index].confusedFor = step.theirConfused[index] ? max(1, out.theirs[index].confusedFor) : 0 }
        }
        out.field = step.field
        out.myTailwind = step.myTailwind
        out.theirTailwind = step.theirTailwind
        out.trickRoom = step.trickRoom
        return out
    }
    /// The weather and the speed control, over the top of the field. Weather
    /// carries its clock: it runs out, and knowing when is a turn's plan.
    @ViewBuilder
    private func fieldState(_ board: Board) -> some View {
        // Only what covers the whole field. Tailwind and screens belong to a
        // side and sit over that side.
        let control = [board.trickRoom > 0 ? "Trick Room · \(board.trickRoom) left" : nil]
            .compactMap { $0 }
        if board.field.weather == .none && control.isEmpty {
            Text("clear skies")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 8) {
                if board.field.weather != .none {
                    fieldClock(symbol: weatherSymbol(board.field), title: board.field.weather.rawValue,
                               turns: board.weatherTurns)
                }
                ForEach(control, id: \.self) { line in
                    Text(line).font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                }
            }
        }
    }
    /// What one side has going for it, over that side: Tailwind, screens,
    /// Wide Guard, each with what is left of it.
    @ViewBuilder
    private func sideState(_ board: Board, mine: Bool) -> some View {
        let tailwind = mine ? board.myTailwind : board.theirTailwind
        let screens = mine ? board.myScreens : board.theirScreens
        let bits: [(String, String)] = [
            tailwind > 0 ? ("wind", "Tailwind · \(tailwind) left") : nil,
            screens.reflect > 0 ? ("shield.lefthalf.filled", "Reflect · \(screens.reflect)") : nil,
            screens.lightScreen > 0 ? ("shield.righthalf.filled", "Light Screen · \(screens.lightScreen)") : nil,
            screens.auroraVeil > 0 ? ("sparkles", "Aurora Veil · \(screens.auroraVeil)") : nil,
            screens.wideGuard ? ("shield.fill", "Wide Guard") : nil,
        ].compactMap { $0 }
        if !bits.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(bits.enumerated()), id: \.offset) { _, bit in
                    HStack(spacing: 4) {
                        Image(systemName: bit.0).font(.system(size: 9))
                        Text(bit.1).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder((mine ? Palette.accent : Palette.bad).opacity(0.6), lineWidth: 1))
                }
            }
        }
    }
    /// Terrain, along the bottom of the field, with its clock.
    @ViewBuilder
    private func terrainState(_ board: Board) -> some View {
        if board.field.terrain != .none {
            fieldClock(symbol: "square.grid.3x3.bottomleft.filled",
                       title: "\(board.field.terrain.rawValue) Terrain", turns: board.terrainTurns)
        }
    }
    private func fieldClock(symbol: String, title: String, turns: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 12))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 11, weight: .bold))
                Text(turns > 0 ? "\(turns) turn\(turns == 1 ? "" : "s") remaining" : "until something changes it")
                    .font(.system(size: 9, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Palette.hairline, lineWidth: 1))
    }
    private func weatherSymbol(_ field: Field) -> String {
        switch field.weather {
        case .sun:  return "sun.max.fill"
        case .rain: return "cloud.rain.fill"
        case .sand: return "aqi.medium"
        case .snow: return "snowflake"
        case .none: return field.terrain == .none ? "circle.grid.cross" : "square.stack.3d.down.forward.fill"
        }
    }
    private func fighterCard(_ fighter: Fighter, mine: Bool, slot: Int,
                             field: Field, tailwind: Bool = false, trickRoom: Bool = false) -> some View {
        let hit = mine ? struck.contains(slot) : struckTheirs.contains(slot)
        let health = fighter.share
        let bar: Color = health > 0.5 ? Palette.good
            : (health > 0.2 ? Palette.warn : Palette.bad)
        return VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                // Behind the sprite: a dome while it is protecting, and a
                // substitute's shell if it has one up. Both are things you have
                // to know before choosing a move, and both were only visible by
                // reading the log for them.
                if guarding(fighter) {
                    Circle()
                        .fill(
                            RadialGradient(colors: [Palette.accent.opacity(0.05),
                                                    Palette.accent.opacity(0.30)],
                                           center: .center, startRadius: 16, endRadius: 46)
                        )
                        .overlay(Circle().strokeBorder(Palette.accent.opacity(0.75), lineWidth: 1.5))
                        .frame(width: 88, height: 88)
                        .transition(.scale.combined(with: .opacity))
                } else if fighter.substitute > 0 && !fighter.fainted {
                    Circle()
                        .strokeBorder(Palette.dim.opacity(0.55),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .frame(width: 88, height: 88)
                }
                // The ground it is standing on. A Pokémon floating on a flat
                // panel reads as a list entry; one with a platform and a
                // shadow under it reads as being somewhere. The cheapest
                // single thing that makes this a field rather than a table.
                if !fighter.fainted {
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [Palette.canvas.opacity(0.55), Palette.canvas.opacity(0)],
                                center: .center, startRadius: 2, endRadius: 30)
                        )
                        .frame(width: 66, height: 17)
                        .offset(y: 32)
                        .allowsHitTesting(false)
                }
                SpriteImage(form: fighter.build.form, side: 78)
                    .offset(y: fighter.fainted ? 0 : bob)
                    .opacity(fighter.fainted ? 0.22 : 1)
                    .saturation(fighter.fainted ? 0 : 1)
                    .scaleEffect(fighter.fainted ? 0.86 : (hit ? 1.1 : 1))
                    .rotationEffect(.degrees(fighter.fainted ? -12 : 0))
                    .shadow(color: hit ? Palette.bad.opacity(0.55) : .clear, radius: 9)
                    .animation(.spring(response: 0.32, dampingFraction: 0.5), value: hit)
                    .animation(.easeOut(duration: 0.35), value: fighter.fainted)
                if guarding(fighter) {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.accent)
                        .padding(3)
                        .background(Palette.surface, in: Circle())
                        .offset(x: 2, y: 54)
                        .help("Protecting this turn. Most attacks will not reach it.")
                } else if fighter.substitute > 0 && !fighter.fainted {
                    Image(systemName: "person.fill.viewfinder")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.dim)
                        .padding(3)
                        .background(Palette.surface, in: Circle())
                        .offset(x: 2, y: 54)
                        .help("A substitute is taking the hits, worth \(fighter.substitute).")
                }
            }
            // The condition rides on the name rather than taking a badge of
            // its own: it is a fact about the Pokémon, and a line that reads
            // "Kingambit · burned" needs no decoding.
            HStack(spacing: 3) {
                Text(fighter.build.form.formLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.65)
                if fighter.status != .none {
                    Text("· \(fighter.status.rawValue)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(statusTint(fighter.status))
                        .lineLimit(1).fixedSize()
                }
            }
            // What it is, which the card never said. Two small bars of the
            // type colours read faster than any word, and typing is the thing
            // a player checks first.
            HStack(spacing: 3) {
                ForEach(fighter.types, id: \.rawValue) { type in
                    Text(type.rawValue.uppercased())
                        .font(.system(size: 7, weight: .heavy)).kerning(0.3)
                        .foregroundStyle(type.onColor)
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(type.color, in: Capsule())
                }
            }
            .opacity(fighter.fainted ? 0.4 : 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline).frame(height: 7)
                GeometryReader { geo in
                    Capsule()
                        .fill(LinearGradient(colors: [bar.opacity(0.75), bar],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * health)
                        // Nearly empty still reads as a sliver rather than
                        // vanishing: one point of health is the whole
                        // difference between standing and not.
                        .frame(minWidth: fighter.fainted ? 0 : 3, alignment: .leading)
                }
                .frame(height: 7)
            }
            .frame(height: 7)
            .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
            .animation(.easeOut(duration: 0.55), value: fighter.hp)
            HStack(spacing: 4) {
                Text("\(fighter.hp)/\(fighter.maxHP)")
                    .font(.system(size: 9, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.secondary)
                // Yours is what it is. Theirs is what you could work out from
                // the stat, because showing the real number would quietly tell
                // you about the Choice Scarf the card above says you cannot see.
                // The Speed it actually moves at, and why: Tailwind, a weather
                // ability, a Scarf, a paralysis. A bare number that has been
                // doubled twice is not something anyone can check.
                let reading = speedReading(fighter, mine: mine, field: field,
                                           tailwind: tailwind, trickRoom: trickRoom)
                Text("· \(reading.value)\(mine ? "" : "?")")
                    .font(.system(size: 9, weight: reading.causes.isEmpty ? .regular : .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(reading.causes.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Palette.accent))
                    .help((mine
                          ? "Speed on the field, everything included."
                          : "What its Speed would be with no item. You cannot see what it is holding, so you cannot see a Choice Scarf either.")
                          + (reading.causes.isEmpty ? "" : " " + reading.causes.joined(separator: ", ") + "."))
            }
            if !speedReading(fighter, mine: mine, field: field, tailwind: tailwind, trickRoom: trickRoom).causes.isEmpty {
                Text(speedReading(fighter, mine: mine, field: field, tailwind: tailwind, trickRoom: trickRoom).causes.joined(separator: " · "))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.accent.opacity(0.85))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Text(fighter.build.itemSpent && !fighter.build.item.isEmpty
                 ? "\(fighter.build.item) · used"
                 : mine ? (fighter.build.item.isEmpty ? "no item" : fighter.build.item)
                        : likelyItem(fighter.build.form))
                .font(.system(size: 9))
                .foregroundStyle(mine ? AnyShapeStyle(.tertiary)
                                      : AnyShapeStyle(Palette.warn.opacity(0.85)))
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(fighter.build.ability)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Palette.accent.opacity(0.85))
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(width: 118)
        .padding(.vertical, 8).padding(.horizontal, 4)
        // Opaque and *lighter* than the field. Two goes at this were wrong in
        // opposite directions: at 55% of a dark grey the card borrowed whatever
        // was behind it and went muddy once there was weather; at 94% of the
        // same dark grey it was darker than the ground and read as a hole. A
        // card on a battlefield is a panel lying on top of it, so it is lighter
        // than the field and carries a light edge and a shadow to say so.
        .background(fighter.fainted ? Color.clear : Palette.cardOnField)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if !fighter.fainted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(fighter.fainted ? 0 : 0.35), radius: 8, y: 3)
        .overlay {
            // The one being asked about, so the question and the Pokémon are
            // visibly the same thing.
            if mine, let board, session.awaitingOrders(board) == slot, !fighter.fainted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Palette.accent, lineWidth: 2)
                    .shadow(color: Palette.accent.opacity(0.7), radius: 7)
            }
        }
        .overlay(alignment: .top) {
            if let lost = damage[Seat(mine: mine, slot: slot)], lost > 0 {
                Text("-\(lost)")
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: Palette.bad, radius: 6)
                    .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                    .offset(y: -18)
                    .transition(.asymmetric(
                        insertion: .offset(y: 14).combined(with: .opacity),
                        removal: .offset(y: -12).combined(with: .opacity)))
                    .allowsHitTesting(false)
            }
        }
        // In the tile's own corner rather than the sprite's, and on a backdrop:
        // a sprite is not a reliable background — Charizard's wing reaches into
        // exactly this space — and a stat change is something you check at a
        // glance rather than squint at.
        .overlay(alignment: .topTrailing) {
            // Only when there is something to draw. This used to hand the
            // backdrop an `AnyView(EmptyView())` when nothing had changed —
            // and an AnyView is not an EmptyView: the erasure hides the
            // emptiness, so the view had no size of its own, stretched to fill
            // the overlay, and painted its near-black backdrop over the whole
            // card. Every Pokémon with no stat change wore a dark sheet, which
            // lifted the moment an Intimidate gave it one.
            let changed = changedStats(fighter)
            if !changed.isEmpty || fighter.isConfused {
                stages(fighter, changed: changed)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Palette.surface.opacity(0.88))
                    )
                    .padding(2)
                    .opacity(fighter.fainted ? 0 : 1)
            }
        }
        // The stone marker takes the other corner. It used to share the right
        // one with the stat column, which is fine at one stat changed and
        // overlapping at four.
        .overlay(alignment: .topLeading) {
            if fighter.pendingMega != nil {
                Text("M").font(.system(size: 9, weight: .heavy))
                    .frame(width: 17, height: 17)
                    .background(Palette.warn).foregroundStyle(.white)
                    .clipShape(Circle())
                    .padding(2)
                    .help("Holding its stone. It Mega Evolves only if you toggle it on "
                          + "with a move, before anything else happens, in Speed order.")
            } else if fighter.build.form.isMega {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.warn)
                    .padding(4)
                    .help("Mega Evolved")
            }
        }
    }
    /// The Speed a Pokémon moves at this turn, and every reason it is not the
    /// number on its stat card: a Chlorophyll in the sun, a Tailwind, a Scarf
    /// you can see because it is yours, a paralysis. Trick Room is named
    /// without changing the number, since it changes the order, not the stat.
    private func speedReading(_ fighter: Fighter, mine: Bool, field: Field,
                              tailwind: Bool, trickRoom: Bool) -> (value: Int, causes: [String]) {
        var causes: [String] = []
        var build = fighter.build
        if !mine { build.item = "" }
        let plain = build.stagedStat(.speed)
        var value = build.speed(in: field)
        if value != plain {
            switch build.ability {
            case "Swift Swim" where field.weather == .rain: causes.append("Swift Swim ×2 in rain")
            case "Chlorophyll" where field.weather == .sun: causes.append("Chlorophyll ×2 in sun")
            case "Sand Rush" where field.weather == .sand: causes.append("Sand Rush ×2 in sand")
            case "Slush Rush" where field.weather == .snow: causes.append("Slush Rush ×2 in snow")
            case "Surge Surfer" where field.terrain == .electric: causes.append("Surge Surfer ×2")
            case "Unburden" where build.itemSpent: causes.append("Unburden ×2")
            default: break
            }
            if mine, build.item == "Choice Scarf" { causes.append("Scarf ×1.5") }
            if mine, build.item == "Iron Ball" || build.item == "Macho Brace" { causes.append("\(build.item) ×½") }
        }
        // The stage itself is not named here any more — the arrow column in the
        // card's corner already says "Spe ▲". What stays are the things no
        // arrow shows: the doublings, the halvings, the item.
        if tailwind { value *= 2; causes.append("Tailwind ×2") }
        if fighter.status.halvesSpeed { value /= 2; causes.append("paralysed ×½") }
        if trickRoom { causes.append("Trick Room: slower first") }
        return (value, causes)
    }
    /// What the measured ladder says they are probably holding.
    private func likelyItem(_ form: Form) -> String {
        let engine = BattleEngine(rules: store.rulebook)
        guard let best = engine.itemOdds(for: form).first else { return "item unknown" }
        if best.chance >= 0.99 { return best.item }
        return String(format: "likely %@ (%.0f%%)", best.item, best.chance * 100)
    }
}
