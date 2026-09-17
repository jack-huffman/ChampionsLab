//  SmogonFeedTests.swift
//  Smogon's gzipped table opens, reads into the app's usage entries by name,
//  and its spreads read into Stat Points.

import XCTest
@testable import ChampionsLab

final class SmogonFeedTests: HarnessCase {
    /// A one-Pokemon chaos table, gzipped: Garchomp on 40% of teams, on
    /// seven sets, running Earthquake and Scale Shot, a Focus Sash, Rough
    /// Skin, two spreads, with Kingambit and Whimsicott beside it.
    static let fixture = "H4sIAAAAAAAC/0WPQU/EIBCF/wrhbGyluzHpbU9mNV7UxPOUQiFbmBUGjWn87w5tjXCZx/fmzbBIHy3KXixSF0Jrubw7tu2NkLGEwSSBVgxANJvM6P6HwQgEa8cDJO0wXFdRMkyGq/b2wJ4X+BIaS6TaxPoZP9eARRpI5D4KXKr5yChr4HCH1drV/DOZsHkt6pIzZMfqUNFp8LMnv0clLJPLFx//Nnu9JgPjBh9xnr971XSqadfbqX3gaYQAkfr61Kh/pmrEm4EQgPYJTz5OEAZfd6vfenc+ZK+RtmX5/ALppZ18QQEAAA=="

    @MainActor func testAChaosTableBecomesUsageEntries() throws {
        let gz = Data(base64Encoded: Self.fixture)!
        let json = try Gzip.decompress(gz)
        let table = try SmogonFeed.parse(json)
        check("one species", table.count == 1 && table.first?.name == "Garchomp", "\(table.map(\.name))")
        check("seven sets", table.first?.appearances == 7, "\(table.first?.appearances ?? -1)")
        let (entries, dropped) = SmogonFeed.convert(table, index: store.usageIndex())
        guard let garchomp = entries.first else { return check("Garchomp survived the dex", false, "\(dropped)") }
        check("usage as a percentage", garchomp.usage == 40, "\(garchomp.usage)")
        check("moves by name, Earthquake first",
              garchomp.moveUsage?.first?.name == "Earthquake", "\(garchomp.moveUsage ?? [])")
        check("a share is of sets: five of seven",
              abs((garchomp.moveUsage?.first?.percent ?? 0) - 71.43) < 0.01, "\(garchomp.moveUsage?.first?.percent ?? 0)")
        check("the item by name", garchomp.itemUsage?.first?.name == "Focus Sash", "\(garchomp.itemUsage ?? [])")
        check("the ability by name", garchomp.abilityUsage?.first?.name == "Rough Skin", "\(garchomp.abilityUsage ?? [])")
        check("the spread in Stat Points, most run first",
              garchomp.spreadUsage?.first?.name == "Jolly 2/32/0/0/0/32", "\(garchomp.spreadUsage ?? [])")
        check("teammates by label", garchomp.teammates == ["Kingambit", "Whimsicott"], "\(garchomp.teammates ?? [])")
        check("nothing fell out of the dex", !dropped.contains { $0.contains("not in the Champions dex") }, "\(dropped)")
    }

    func testAPublishedSpreadReadsIntoStatPoints() {
        let read = MetaModel.spread("Jolly 2/32/0/0/0/32")
        check("the alignment", read?.alignment == "Jolly")
        check("the points where they go",
              read?.sp[Stat.hp.rawValue] == 2 && read?.sp[Stat.attack.rawValue] == 32
                && read?.sp[Stat.speed.rawValue] == 32 && read?.sp[Stat.defense.rawValue] == 0,
              "\(read?.sp ?? [])")
        check("over the cap is refused", MetaModel.spread("Bold 40/0/40/0/0/0") == nil)
        check("too few stats is refused", MetaModel.spread("Jolly 2/32") == nil)
        check("over the total is refused", MetaModel.spread("Jolly 32/32/32/0/0/0") == nil)
    }

    @MainActor func testAHyphenatedMoveIsFoundByItsSmogonID() {
        // Charizard learns both in Champions; the dex writes them "will-o-wisp"
        // and "double-edge", Smogon "willowisp" and "doubleedge".
        let species = SmogonFeed.Species(name: "Charizard", usage: 0.3, appearances: 10,
                                         moves: [("willowisp", 8), ("doubleedge", 6), ("heatwave", 9)],
                                         items: [("charizarditey", 6)], abilities: [("blaze", 10)],
                                         spreads: [], teammates: [])
        let (entries, dropped) = SmogonFeed.convert([species], index: store.usageIndex())
        let names = entries.first?.moveUsage?.map(\.name) ?? []
        check("Will-O-Wisp survived its hyphens", names.contains("Will-O-Wisp"), "\(names) dropped \(dropped)")
        check("Double-Edge too", names.contains("Double-Edge"), "\(names)")
    }

    func testAnIDIsAName() {
        check("focussash", SmogonFeed.toID("Focus Sash") == "focussash")
        check("kingsrock", SmogonFeed.toID("King's Rock") == "kingsrock")
        check("pokemon", SmogonFeed.toID("Pok\u{00E9}mon") == "pokmon")
    }
}
