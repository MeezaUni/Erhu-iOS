import Foundation

/// CC0 structured genres, used only through a verified MusicBrainz recording/album link.
/// No account, key, audio upload, artist-wide inference or page scraping is involved.
actor WikidataGenres {
    private let client: HTTPClient
    private var entities: [String: Entity] = [:]
    private var genreLabels: [String: String] = [:]

    init(client: HTTPClient) { self.client = client }

    static func isEntityID(_ id: String) -> Bool {
        id.first == "Q" && !id.dropFirst().isEmpty && id.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    private struct Value: Decodable {
        var text: String?
        var entityID: String?
        enum CodingKeys: String, CodingKey { case value }
        init(from decoder: Decoder) throws {
            let value = try decoder.container(keyedBy: CodingKeys.self)
            if let text = try? value.decode(String.self, forKey: .value) { self.text = text }
            else {
                struct EntityValue: Decodable { var id: String? }
                entityID = (try? value.decode(EntityValue.self, forKey: .value))?.id
            }
        }
    }
    private struct Statement: Decodable {
        struct Snak: Decodable { var datavalue: Value? }
        var rank: String?
        var mainsnak: Snak
    }
    private struct Entity: Decodable {
        struct Label: Decodable { var value: String }
        var id: String?
        var claims: [String: [Statement]]?
        var labels: [String: Label]?
    }
    private struct Response: Decodable { var entities: [String: Entity] }

    func genres(entityID: String, musicBrainzID: String, property: String) async throws -> [String] {
        guard Self.isEntityID(entityID), ["P436", "P4404"].contains(property) else { return [] }
        let entity: Entity
        if let cached = entities[entityID] { entity = cached }
        else {
            let response = try await fetchJSON(Response.self,
                URL(string: "https://www.wikidata.org/wiki/Special:EntityData/\(entityID).json")!, client: client)
            guard let item = response.entities[entityID], item.id == entityID else { return [] }
            entity = item
            if entities.count >= 500 { entities.removeAll() }
            entities[entityID] = entity
        }
        // A curated link is sufficient when the item has no inverse identifier; an explicit
        // conflicting identifier must never be ignored.
        let identifiers = (entity.claims?[property] ?? []).filter { $0.rank != "deprecated" }
            .compactMap { $0.mainsnak.datavalue?.text?.lowercased() }
        guard identifiers.isEmpty || identifiers.contains(musicBrainzID.lowercased()) else { return [] }
        let claims = (entity.claims?["P136"] ?? []).filter { $0.rank != "deprecated" }
        let preferred = claims.filter { $0.rank == "preferred" }
        let ids = Array(Set((preferred.isEmpty ? claims : preferred).compactMap { $0.mainsnak.datavalue?.entityID }
            .filter(Self.isEntityID))).sorted().prefix(12)
        let uncached = ids.filter { genreLabels[$0] == nil }
        if !uncached.isEmpty {
            let response = try await fetchJSON(Response.self, requestURL("https://www.wikidata.org/w/api.php", [
                ("action", "wbgetentities"), ("ids", uncached.joined(separator: "|")),
                ("props", "labels"), ("languages", "en"), ("format", "json")
            ]), client: client)
            if genreLabels.count >= 5_000 { genreLabels.removeAll() }
            for id in uncached { genreLabels[id] = response.entities[id]?.labels?["en"]?.value ?? "" }
        }
        return Genres.normalize(ids.compactMap { genreLabels[$0] })
    }
}
