import Foundation

/// What this Mac's darkmux can do, as `GET /client/whoami` lists it
/// (`capabilities`): a feature is gated on its capability, never on a
/// version or on how a route happens to answer.
extension RunCoordinator {
    /// darkmux's capabilities, read once per pairing (empty when they
    /// can't be read now, and read again next time).
    @discardableResult
    func capabilities() async -> Set<String> {
        if let darkmuxCapabilities { return darkmuxCapabilities }
        let read: Set<String>?
        if let capabilitiesSource {
            read = try? await capabilitiesSource()
        } else if let connection, let token = connection.token {
            read = (try? await connection.client.whoami(token: token)).map { Set($0.capabilities ?? []) }
        } else {
            read = nil
        }
        if let read { darkmuxCapabilities = read }
        return read ?? []
    }

    /// darkmux said it can do `capability` (as last read).
    func darkmuxCan(_ capability: String) -> Bool {
        darkmuxCapabilities?.contains(capability) ?? false
    }

    /// The darkmux role a crew's work goes to here: Researcher goes to
    /// darkmux's read-only `researcher` where darkmux has it (darkmux
    /// #3682), else to `analyst`.
    func role(for crew: CrewRole) -> String? {
        if crew == .researcher, darkmuxCan("read_only_runs") { return "researcher" }
        return crew.darkmuxRole
    }
}
