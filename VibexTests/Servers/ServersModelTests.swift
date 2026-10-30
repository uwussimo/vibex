import Foundation
import Testing
@testable import Vibex

@MainActor @Suite struct ServersModelTests {
    private func model() -> (ServersModel, URL, InMemoryKeychain) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-servers-\(UUID().uuidString)/servers.json")
        let keychain = InMemoryKeychain()
        let store = KeychainCredentialStore(service: "test.\(UUID().uuidString)", backend: keychain, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return (ServersModel(file: file, store: store, authenticator: FakeDeviceAuthenticator()), file, keychain)
    }

    private func draft(_ name: String = "Production", secret: String = "hunter2") -> ServerDraft {
        var draft = ServerDraft()
        draft.name = name
        draft.host = "203.0.113.10"
        draft.username = "deploy"
        draft.secret = secret
        return draft
    }

    @Test func `a saved password goes to the keychain and never to the file`() throws {
        let (model, file, _) = model()
        let server = model.save(draft(secret: "a-very-secret-password"), editing: nil)
        #expect(model.hasSecret(server))
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("203.0.113.10"))
        #expect(!text.contains("a-very-secret-password"))
    }

    @Test func `the servers file is readable only by its owner`() throws {
        let (model, file, _) = model()
        model.save(draft(), editing: nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func `servers come back after a restart`() {
        let (first, file, _) = model()
        first.save(draft("Zeta"), editing: nil)
        first.save(draft("Alpha"), editing: nil)
        let second = ServersModel(file: file, store: KeychainCredentialStore(service: "t", backend: InMemoryKeychain(), defaults: UserDefaults(suiteName: UUID().uuidString)!), authenticator: FakeDeviceAuthenticator())
        #expect(second.sorted.map(\.name) == ["Alpha", "Zeta"])
    }

    @Test func `editing keeps the server's identity and an empty field keeps its password`() {
        let (model, _, _) = model()
        let server = model.save(draft(), editing: nil)
        var edit = ServerDraft(profile: server)
        edit.name = "Renamed"
        let saved = model.save(edit, editing: server)
        #expect(saved.id == server.id)
        #expect(model.servers.map(\.name) == ["Renamed"])
        #expect(model.hasSecret(saved))
    }

    @Test func `switching to a private key forgets the password`() {
        let (model, _, _) = model()
        let server = model.save(draft(), editing: nil)
        var edit = ServerDraft(profile: server)
        edit.authentication = .privateKey
        edit.privateKeyPath = "~/.ssh/id_ed25519"
        let saved = model.save(edit, editing: server)
        #expect((try? model.credentials.hasCredential(for: server.id, kind: .password)) == false)
        #expect(saved.privateKeyPath?.hasPrefix("/") == true)
    }

    @Test func `deleting a server deletes its secret`() {
        let (model, _, _) = model()
        let server = model.save(draft(), editing: nil)
        model.delete(server)
        #expect(model.servers.isEmpty)
        #expect(!model.hasSecret(server))
    }

    @Test func `search looks through names, hosts and notes`() {
        let (model, _, _) = model()
        var first = draft("Production")
        first.notes = "billing database"
        model.save(first, editing: nil)
        var second = draft("Staging")
        second.host = "staging.example.com"
        model.save(second, editing: nil)
        #expect(model.matching("PROD").map(\.name) == ["Production"])
        #expect(model.matching("example").map(\.name) == ["Staging"])
        #expect(model.matching("billing").map(\.name) == ["Production"])
        #expect(model.matching("").count == 2)
    }

    @Test func `a cancelled Touch ID opens nothing and says nothing`() async {
        let authenticator = FakeDeviceAuthenticator()
        authenticator.scriptedFailures = [.cancelledByUser]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vibex-servers-\(UUID().uuidString)/s.json")
        let gated = ServersModel(file: file, store: KeychainCredentialStore(service: "g.\(UUID().uuidString)", backend: InMemoryKeychain(), defaults: UserDefaults(suiteName: UUID().uuidString)!), authenticator: authenticator)
        let server = gated.save(draft(), editing: nil)
        var opened = false
        await gated.connect(server) { _ in
            opened = true
            return nil
        }
        #expect(!opened)
        #expect(gated.problem == nil)
    }
}

@MainActor @Suite struct ServerClickTests {
    private let model = ServersModel(file: FileManager.default.temporaryDirectory.appendingPathComponent("clicks-\(UUID().uuidString).json"), store: KeychainCredentialStore(service: "clicks", backend: InMemoryKeychain()))
    private let server = UUID()

    @Test func `a click goes to the open tab, or connects when there is none`() {
        #expect(model.click(on: server, count: 1, hasOpenTab: true) == .focus)
        #expect(model.click(on: server, count: 1, hasOpenTab: false) == .connect)
    }

    @Test func `a double-click opens another tab`() {
        #expect(model.click(on: server, count: 1, hasOpenTab: true) == .focus)
        #expect(model.click(on: server, count: 2, hasOpenTab: true) == .connect)
    }

    @Test func `a double-click on a server with no tab opens just one`() {
        #expect(model.click(on: server, count: 1, hasOpenTab: false) == .connect)
        #expect(model.click(on: server, count: 2, hasOpenTab: true) == .nothing)
        #expect(model.click(on: server, count: 3, hasOpenTab: true) == .nothing)
        // The next double-click is a new request.
        #expect(model.click(on: server, count: 1, hasOpenTab: true) == .focus)
        #expect(model.click(on: server, count: 2, hasOpenTab: true) == .connect)
    }
}
