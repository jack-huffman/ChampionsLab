//  ChampionsRules.swift
//  The numbers Pokemon Champions changed from the main series.
//
//  Showdown plays Champions as a mod over its main-series tables, and that
//  mod -- data/mods/champions/ in the pokemon-showdown checkout -- is the
//  closest thing to a published rulebook. Where it changes a number the turn
//  model used to carry from the main series, the number lives here with the
//  mod's own line beside it, and ChampionsRulesTests reads the mod when the
//  checkout is present and fails if the two ever part.
//
//  A leaf: it depends on nothing, and Ailments, Strikes and Residuals read it.

import Foundation

enum ChampionsRules {
    /// A paralysed Pokemon loses one turn in eight. The main series says one
    /// in four; Champions halved it.
    ///
    ///     conditions.ts  par: this.randomChance(1, 8)
    static let fullParalysis = 1.0 / 8

    /// Sleep lasts two turns a third of the time and three the rest, drawn
    /// when it is inflicted. The search takes two, so it never counts on the
    /// long one.
    ///
    ///     conditions.ts  slp: this.sample([2, 3, 3])
    static let sleepTurns = [2, 3, 3]
    static let sleepSearch = 2

    /// Frozen solid thaws one turn in four, and on the third turn regardless
    /// -- the main series has no clock on it at all.
    ///
    ///     conditions.ts  frz: startTime = 3; this.randomChance(1, 4)
    static let thaw = 1.0 / 4
    static let frozenFor = 3

    /// Healer clears a partner's condition one turn in two; the main series
    /// says three in ten.
    ///
    ///     abilities.ts  healer: this.randomChance(1, 2)
    static let healer = 1.0 / 2
}
