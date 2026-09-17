//  BuilderFlesh.swift
//  Giving a chosen Pokemon the set it is actually used with.
//
//  The search picks forms; this gives each one its ability, item, moves and
//  Stat Point spread -- from measured usage where the format has an answer,
//  and from its role on this team where it does not. The spread is planned
//  against the format's speed benchmarks, under the team's own Tailwind where
//  it has one.

import Foundation

extension TeamBuilder {
    /// Give a form the build it is actually used with, falling back to its role.
    func flesh(_ form: Form, plan: Archetype, usedItems: inout Set<String>,
               allyGrounded: Int = 0) -> TeamSlot {
        var slot = TeamSlot(formID: form.id)
        let advisor = TeamAdvisor(team: Team(), store: store)
        let roles = advisor.potentialRoles(of: form)
        let usage = store.data.usage.first { $0.name == form.formLabel || $0.name == form.name }

        // The ladder's own answer beats anything derived, where there is one.
        let live = store.data.usage.first {
            ($0.name == form.formLabel || $0.name == form.name) && $0.hasLiveData
        }
        if let measured = live?.abilityUsage?.first,
           form.abilities.contains(where: { $0.name == measured.name }) {
            slot.ability = measured.name
        } else {
            slot.ability = preferredAbility(form, plan: plan)
        }

        // Item: what it is usually seen with, else something that suits the role.
        let physicalAttacker = form.attack >= form.spAttack
        // Measured item share first, then the role-appropriate fallbacks.
        var wanted: [String] = (live?.itemUsage?.map(\.name) ?? usage?.commonItems ?? [])
        if form.isMega { wanted = [form.megaTrigger] }
        // A Choice item has to match the attacking stat: Specs on an Adamant
        // physical attacker is a wasted slot, which an earlier version did.
        wanted += roles.contains(.redirection) || roles.contains(.tailwind)
            ? ["Focus Sash", "Sitrus Berry", "Covert Cloak", "Mental Herb"]
            : (physicalAttacker
               ? ["Life Orb", "Choice Band", "Assault Vest", "Sitrus Berry", "Leftovers"]
               : ["Life Orb", "Choice Specs", "Assault Vest", "Sitrus Berry", "Leftovers"])
        // Only things people have actually been seen holding in Champions. The
        // item list comes from the main-series itemdex, and half of it is not in
        // this game — Assault Vest, Choice Band, Choice Specs and Covert Cloak
        // are all on that list and all appear on none of the registered teams.
        // Building a six around an item that does not exist is worse than any
        // scoring error, because none of it can be played.
        slot.item = wanted.first {
            guard let item = store.item(named: $0) else { return false }
            return item.seenInGame && !usedItems.contains($0)
        } ?? "Leftovers"
        usedItems.insert(slot.item)

        // Spread and alignment, built to a benchmark rather than to a habit.
        let support = roles.contains(.redirection) || roles.contains(.tailwind)
            || roles.contains(.trickRoom) || roles.contains(.terrain)
        let physical = form.attack >= form.spAttack
        let built = spread(for: form, physical: physical, support: support, plan: plan,
                           tailwind: roles.contains(.tailwind) || plan == .tailwind)
        slot.sp = built.sp
        slot.alignmentName = built.alignment

        slot.moves = chooseMoves(form, roles: roles, plan: plan, usage: usage,
                                 ability: slot.ability, item: slot.item,
                                 allyGrounded: allyGrounded)
        return slot
    }

    /// Something whose whole case is hitting hard should be hitting hard.
    private func physicalAttackerIsTheWholePoint(_ form: Form) -> Bool {
        max(form.attack, form.spAttack) >= 130
    }

    /// Speed numbers worth investing to beat, from the tracked field.
    private var benchmarks: [Int] { store.speedBenchmarks(format: format) }

    /// The same numbers seen from under your own Tailwind.
    ///
    /// Coaching advice that keeps coming up is "invest enough to outspeed X
    /// under Tailwind", and that is a different number: doubling your own Speed
    /// halves what you need to reach. A team that carries Tailwind was still
    /// paying full price for Speed it did not need.
    private func benchmarks(underTailwind: Bool) -> [Int] {
        let marks = benchmarks
        // Opponents in this format nearly all carry Tailwind of their own, so
        // yours buys parity rather than a free halving. Half the gap, not all.
        return underTailwind ? marks.map { Int(Double($0) * 0.72) } : marks
    }

    /// A spread aimed at a Speed benchmark the Pokémon can actually reach.
    ///
    /// The previous version gave every attacker 32 Speed and every supporter 2,
    /// which produced teams sitting at 108-139 against a field whose benchmarks
    /// are 178 to 223 — investment that bought nothing. Here, Speed is only paid
    /// for when it clears something real, and the points go into bulk otherwise.
    func spread(for form: Form, physical: Bool, support: Bool,
                plan: Archetype, tailwind: Bool = false) -> (sp: [Int], alignment: String) {
        var sp = Array(repeating: 0, count: 6)
        let attacking: Stat = physical ? .attack : .spAttack

        // Trick Room wants to be slow, so none of this applies.
        if plan == .trickRoom {
            sp[attacking.rawValue] = 32
            sp[Stat.hp.rawValue] = 32
            sp[Stat.defense.rawValue] = 2
            return (sp, physical ? "Brave" : "Quiet")
        }

        let marks = benchmarks(underTailwind: tailwind)
        // Try the attack-boosting alignment first: Speed that clears a benchmark
        // is worth having, but not at the cost of the attacking stat if the
        // benchmark is reachable either way.
        for alignmentName in [physical ? "Adamant" : "Modest", physical ? "Jolly" : "Timid"] {
            let alignment = Alignment.named(alignmentName)
            let ceiling = ChampionsStats.value(base: form.speed, sp: 32,
                                               stat: .speed, alignment: alignment)
            // The highest mark this Pokémon can actually get above.
            guard let target = marks.first(where: { $0 < ceiling }) else { continue }
            // Cheapest investment that clears it.
            var needed = 32
            for candidate in 0...32 {
                let value = ChampionsStats.value(base: form.speed, sp: candidate,
                                                 stat: .speed, alignment: alignment)
                if value > target { needed = candidate; break }
            }
            sp[Stat.speed.rawValue] = needed
            sp[attacking.rawValue] = support ? 0 : 32
            let spent = sp.reduce(0, +)
            // Everything left goes into bulk rather than being wasted, and into
            // the side it is already good at: health multiplies whichever
            // defence it has, so points spent there are worth more.
            let spare = ChampionsStats.spTotal - spent
            sp[Stat.hp.rawValue] = min(32, spare)
            let after = ChampionsStats.spTotal - sp.reduce(0, +)
            if after > 0 {
                let role = store.statRole(of: form)
                let strong: Stat = role.defence == .specialWall ? .spDefense : .defense
                let other: Stat = strong == .defense ? .spDefense : .defense
                sp[strong.rawValue] = min(32, after)
                let last = ChampionsStats.spTotal - sp.reduce(0, +)
                if last > 0 { sp[other.rawValue] = min(32, last) }
            }
            return (sp, alignmentName)
        }

        // Nothing reachable: do not pay for Speed at all.
        sp[attacking.rawValue] = support ? 0 : 32
        sp[Stat.hp.rawValue] = 32
        let spare = ChampionsStats.spTotal - sp.reduce(0, +)
        let role = store.statRole(of: form)
        let strong: Stat = role.defence == .specialWall ? .spDefense : .defense
        let other: Stat = strong == .defense ? .spDefense : .defense
        sp[strong.rawValue] = min(32, spare)
        let last = ChampionsStats.spTotal - sp.reduce(0, +)
        if last > 0 { sp[other.rawValue] = min(32, last) }
        return (sp, support
                ? (physical ? "Careful" : "Calm")
                : (physical ? "Adamant" : "Modest"))
    }

    private func preferredAbility(_ form: Form, plan: Archetype) -> String {
        if let enabler = plan.enabler,
           form.abilities.contains(where: { $0.name == enabler }) { return enabler }
        // Prefer the ability the format actually uses it for.
        let priority = ["Intimidate", "Prankster", "Good as Gold", "Levitate",
                        "Adaptability", "Huge Power", "Unburden", "Armor Tail",
                        "Multiscale", "Thermal Exchange", "Tough Claws"]
        for name in priority where form.abilities.contains(where: { $0.name == name }) {
            return name
        }
        return form.abilities.first?.name ?? ""
    }

    /// Four moves, built to a doubles shape rather than to raw power.
    ///
    /// Reserving the last slot for Protect matters: the previous version added
    /// it after coverage, so it was crowded out of 58 of 78 slots. Two damaging
    /// moves of the same type are a wasted slot, and a team with no spread move
    /// at all has no way to win a doubles game, so both are handled explicitly.
    ///
    /// `allyGrounded` is the count of partners an Earthquake would also hit.
    private func chooseMoves(_ form: Form, roles: Set<TeamRole>, plan: Archetype,
                             usage: UsageEntry?, ability: String, item: String,
                             allyGrounded: Int) -> [String] {
        var chosen: [String] = []
        var usedTypes = Set<String>()
        let learnset = store.moves(for: form)

        // Assault Vest forbids status moves, and a Choice item locks you into
        // one — neither wants Protect.
        let wantsProtect = item != "Assault Vest"
            && !item.hasPrefix("Choice")
        let budget = wantsProtect ? 3 : 4

        @discardableResult
        func add(_ name: String) -> Bool {
            guard chosen.count < budget,
                  let move = learnset.first(where: { $0.name == name }),
                  !chosen.contains(move.id) else { return false }
            if move.isDamaging {
                guard usedTypes.insert(move.type).inserted else { return false }
            }
            chosen.append(move.id)
            return true
        }

        // Status before damage on something built to survive. Coaching material
        // is emphatic about this and the engine now agrees: a burn halves a
        // physical attacker for the whole game, which beats one more attack from
        // a Pokémon that was never going to out-damage it anyway.
        let bulky = form.hp + form.defense + form.spDefense >= 300
        if bulky && !physicalAttackerIsTheWholePoint(form) {
            for name in ["Will-O-Wisp", "Thunder Wave", "Hypnosis", "Spore"] {
                if add(name) { break }
            }
        }

        // The role move is the reason the slot exists.
        if plan == .trickRoom { add("Trick Room") }
        if roles.contains(.tailwind) { add("Tailwind") }
        if roles.contains(.redirection) { if !add("Follow Me") { add("Rage Powder") } }
        if roles.contains(.fakeOut) { add("Fake Out") }
        // Moves people actually run, in the order they run them.
        for name in usage?.keyMoves ?? [] where !name.hasPrefix("Protect") { add(name) }

        let physical = form.attack >= form.spAttack
        let usesNormal = form.types.contains("Normal")
            || form.abilities.contains { ["Aerilate", "Pixilate", "Refrigerate",
                                          "Galvanize", "Normalize"].contains($0.name) }
        // Worth, not base power. Steel Beam's 140 is not 140 when it costs half
        // your HP, and Focus Blast's 120 is not 120 at 70% accuracy.
        func ranked(_ pool: [Move]) -> [Move] {
            pool.sorted {
                store.moveValue($0, for: form, ability: ability, item: item)
                    > store.moveValue($1, for: form, ability: ability, item: item)
            }
        }
        let attacks = ranked(store.attackingMoves(for: form)
            .filter { physical ? $0.category == "Physical" : $0.category == "Special" }
            .filter { $0.type != "Normal" || usesNormal }
            // An Earthquake beside three grounded partners costs more than it wins.
            .filter { !($0.hitsAlly && allyGrounded >= 2) })

        // A spread move first — doubles games are decided by hitting both.
        if let spreadMove = attacks.first(where: { $0.isSpread }) { add(spreadMove.name) }
        // Then the strongest STAB, then coverage, one per type.
        for move in attacks where form.types.contains(move.type) { add(move.name) }
        for move in attacks { add(move.name) }

        if wantsProtect, chosen.count < 4 {
            if learnset.contains(where: { $0.name == "Protect" }) {
                chosen.append(learnset.first { $0.name == "Protect" }!.id)
            } else if let detect = learnset.first(where: { $0.name == "Detect" }) {
                chosen.append(detect.id)
            }
        }
        // If anything is still short, top up with the best remaining attack.
        for move in attacks where chosen.count < 4 {
            if !chosen.contains(move.id) { chosen.append(move.id) }
        }
        return chosen
    }
}
