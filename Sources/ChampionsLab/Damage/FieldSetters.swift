//  FieldSetters.swift
//  Who puts the weather and the terrain up.
//
//  Eleven files each carried their own copy of this table, and they had begun
//  to disagree: the meta model knew Sand Spit brings sand and the builder did
//  not, and Orichalcum Pulse was being counted for a Pokemon that is not in
//  the game. The sim setting a field on a switch-in, the builder scoring a
//  matchup on it, the game plan and the analysis screen showing what a team
//  puts up, the advisor naming what a team lacks, the refiner sparing a move
//  that only works under it, and the meta model counting who brings it all
//  read this one table now, and FieldOwnershipTests fails the build if a
//  setter's name is written by string anywhere else.
//
//  Arrival and later are kept apart on purpose. Drought puts the sun up the
//  moment its holder walks in, so the switch-in reads it; Sand Spit brings a
//  sandstorm only once its holder has been hit, so a forecast of what a team
//  will have up counts it and the switch-in does not.

import Foundation

enum FieldSetters {
    // MARK: - The table

    /// Abilities that set a weather the moment their holder arrives.
    static let weatherOnArrival: [String: Weather] = [
        "Drought": .sun, "Drizzle": .rain, "Sand Stream": .sand, "Snow Warning": .snow,
    ]
    /// Abilities that bring a weather later in the game -- Sand Spit, once its
    /// holder is hit. Counted where a team's weather is being forecast; not an
    /// arrival, so the switch-in does not read it. The turn model does not yet
    /// model it, and the parity audit says so.
    static let weatherLater: [String: Weather] = ["Sand Spit": .sand]
    /// Abilities that set a terrain the moment their holder arrives.
    static let terrainOnArrival: [String: Terrain] = [
        "Electric Surge": .electric, "Grassy Surge": .grassy,
        "Misty Surge": .misty, "Psychic Surge": .psychic,
    ]
    /// The moves that set each.
    static let weatherMoves: [String: Weather] = [
        "Sunny Day": .sun, "Rain Dance": .rain, "Sandstorm": .sand, "Snowscape": .snow,
    ]
    static let terrainMoves: [String: Terrain] = [
        "Grassy Terrain": .grassy, "Electric Terrain": .electric,
        "Misty Terrain": .misty, "Psychic Terrain": .psychic,
    ]

    // MARK: - Reading it

    /// What arriving with this ability puts up, if anything.
    static func weather(onArrivalWith ability: String) -> Weather? { weatherOnArrival[ability] }
    static func terrain(onArrivalWith ability: String) -> Terrain? { terrainOnArrival[ability] }
    /// What using this move puts up, if anything.
    static func weather(setBy move: String) -> Weather? { weatherMoves[move] }
    static func terrain(setBy move: String) -> Terrain? { terrainMoves[move] }

    /// What Showdown's protocol calls what is on the field.
    ///
    /// Mostly the move's own name, which is why this lives here rather than
    /// with the reader that needs it: one place knows what a weather is
    /// called, and a second copy of these words is exactly the drift this
    /// file exists to stop. Where the client differs it is only in being
    /// shorter about it -- "Sun" for the sun, "Rain" for the rain.
    static func weather(named protocolName: String) -> Weather? {
        if let direct = weatherMoves[protocolName] { return direct }
        switch protocolName {
        case "SunnyDay", "Sun", "DesolateLand", "desolateland": return .sun
        case "RainDance", "Rain", "PrimordialSea", "primordialsea": return .rain
        case "Sand": return .sand
        case "Snow", "Hail": return .snow
        case "none", "": return Weather.none
        default: return nil
        }
    }

    static func terrain(named protocolName: String) -> Terrain? {
        if let direct = terrainMoves[protocolName] { return direct }
        // The client writes a field condition with the move's name, and the
        // ability-set ones with the ability's.
        switch protocolName {
        case "move: Grassy Terrain": return .grassy
        case "move: Electric Terrain": return .electric
        case "move: Misty Terrain": return .misty
        case "move: Psychic Terrain": return .psychic
        default: return nil
        }
    }

    /// Every ability that sets a field on arrival: what "a field setter" means.
    static let weatherArrivalAbilities: Set<String> = Set(weatherOnArrival.keys)
    static let terrainArrivalAbilities: Set<String> = Set(terrainOnArrival.keys)
    static let arrivalAbilities: Set<String> = weatherArrivalAbilities.union(terrainArrivalAbilities)

    /// The ability a team carries to set this, where one exists. Each field
    /// has exactly one, which is what lets this be a single answer.
    static func ability(setting weather: Weather) -> String? {
        weatherOnArrival.first { $0.value == weather }?.key
    }
    static func ability(setting terrain: Terrain) -> String? {
        terrainOnArrival.first { $0.value == terrain }?.key
    }
    /// The move that sets this, where one exists.
    static func move(setting weather: Weather) -> String? {
        weatherMoves.first { $0.value == weather }?.key
    }
    static func move(setting terrain: Terrain) -> String? {
        terrainMoves.first { $0.value == terrain }?.key
    }

    /// Every ability that brings this weather, on arrival or later, for a
    /// forecast of what a team will have up.
    static func abilities(bringing weather: Weather) -> [String] {
        (Array(weatherOnArrival.filter { $0.value == weather }.keys)
            + Array(weatherLater.filter { $0.value == weather }.keys)).sorted()
    }

    /// The arrival abilities that set any of these.
    static func arrivalAbilities(setting weathers: [Weather], or terrains: [Terrain]) -> Set<String> {
        Set(weatherOnArrival.filter { weathers.contains($0.value) }.keys)
            .union(terrainOnArrival.filter { terrains.contains($0.value) }.keys)
    }

    /// The weather and terrain these abilities put up between them. The last
    /// setter wins, as it does when two of a team's own arrive in turn.
    static func set(by abilities: some Sequence<String>) -> (weather: Weather, terrain: Terrain) {
        var weather = Weather.none, terrain = Terrain.none
        for ability in abilities {
            if let put = weatherOnArrival[ability] { weather = put }
            if let put = terrainOnArrival[ability] { terrain = put }
        }
        return (weather, terrain)
    }

    /// The field a team puts up for itself.
    static func field(from abilities: some Sequence<String>, isDoubles: Bool) -> Field {
        let (weather, terrain) = set(by: abilities)
        return Field(weather: weather, terrain: terrain, isDoubles: isDoubles)
    }

    // MARK: - In the game's order, for lists

    /// Each terrain with the ability and the move that set it.
    static let terrains: [(terrain: Terrain, ability: String, move: String)] =
        [Terrain.grassy, .psychic, .electric, .misty].compactMap {
            (terrain: Terrain) -> (terrain: Terrain, ability: String, move: String)? in
            guard let ability = ability(setting: terrain), let move = move(setting: terrain) else { return nil }
            return (terrain, ability, move)
        }
    /// Each weather with its arrival ability and its move.
    static let weatherArrivals: [(weather: Weather, ability: String, move: String)] =
        [Weather.sun, .rain, .sand, .snow].compactMap {
            (weather: Weather) -> (weather: Weather, ability: String, move: String)? in
            guard let ability = ability(setting: weather), let move = move(setting: weather) else { return nil }
            return (weather, ability, move)
        }
    /// Each weather with every ability that brings it, sooner or later, and
    /// its move.
    static let weathers: [(weather: Weather, abilities: [String], move: String)] =
        [Weather.sun, .rain, .sand, .snow].compactMap {
            (weather: Weather) -> (weather: Weather, abilities: [String], move: String)? in
            guard let move = move(setting: weather) else { return nil }
            return (weather, abilities(bringing: weather), move)
        }
    /// The setting moves by name.
    static let terrainMoveNames: [String] = terrains.map(\.move)
    static let weatherMoveNames: [String] = weatherArrivals.map(\.move)
}
