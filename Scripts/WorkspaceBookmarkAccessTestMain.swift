import Foundation

private enum Failure: Error { case unavailable }

private final class FakeBookmarks {
  let url = URL(fileURLWithPath: "/isolated-test/workspace")
  var activeScopes = 0
  var events: [String] = []
  var unavailable = Set<Data>()
  var stale = Set<Data>()
  var failCreate = false
  var onCreate: (() -> Void)?
  let owned = Data("receiver-owned".utf8)
  let transfer = Data("live-transfer".utf8)

  var operations: WorkspaceBookmarkOperations {
    WorkspaceBookmarkOperations(
      resolve: { [self] data, scope in
        events.append("resolve:\(scope)")
        if unavailable.contains(data) { throw Failure.unavailable }
        return (url, stale.contains(data))
      },
      create: { [self] _, scope in
        events.append("create:\(scope)")
        onCreate?()
        if failCreate { throw Failure.unavailable }
        return scope == .persistent ? owned : transfer
      },
      start: { [self] _ in activeScopes += 1; return true },
      stop: { [self] _ in activeScopes -= 1 }
    )
  }
}

@main
private struct WorkspaceBookmarkAccessTestMain {
  static func main() throws {
    let names = (0 ..< 3).map { "kmd-workspace-grant-tests-\(UUID().uuidString)-\($0)" }
    let stores = names.map { UserDefaults(suiteName: $0)! }
    defer { for (store, name) in zip(stores, names) { store.removePersistentDomain(forName: name) } }
    let shared = stores[0]
    let publisherLocal = stores[1]
    let receiverLocal = stores[2]
    let issuer = FakeBookmarks()
    let consumer = FakeBookmarks()
    var publisher: WorkspaceBookmarkPublisher? = WorkspaceBookmarkPublisher(
      shared: shared, local: publisherLocal, operations: issuer.operations
    )
    var receiver = WorkspaceBookmarkReceiver(shared: shared, local: receiverLocal, operations: consumer.operations)
    let source = Data("main-private-bookmark".utf8)
    publisher!.publish(source)
    let initial = shared.dictionary(forKey: WorkspaceBookmarkPublisher.sharedKey)!
    let generation = initial["generation"] as! String
    precondition(initial["transfer"] as? Data == issuer.transfer)
    precondition(initial["transfer"] as? Data != source)
    precondition(issuer.activeScopes == 1)
    publisher!.publish(source)
    precondition(shared.dictionary(forKey: WorkspaceBookmarkPublisher.sharedKey)!["generation"] as? String == generation)
    precondition(issuer.activeScopes == 1, "republish balances the previous sender scope")

    let received = receiver.acquire()!
    precondition(consumer.events == ["resolve:transfer", "create:persistent", "resolve:persistent"])
    precondition(consumer.activeScopes == 1, "temporary transfer scope is released")
    consumer.operations.stop(received)
    let durable = receiverLocal.dictionary(forKey: "ownedWorkspaceGrant.v1")!
    precondition(durable["bookmark"] as? Data == consumer.owned)

    // Reconstruct both processes with persisted preferences and no live transfer.
    publisher = nil
    precondition(issuer.activeScopes == 0)
    issuer.unavailable.insert(source)
    publisher = WorkspaceBookmarkPublisher(shared: shared, local: publisherLocal, operations: issuer.operations)
    publisher!.publish(source)
    let offline = shared.dictionary(forKey: WorkspaceBookmarkPublisher.sharedKey)!
    precondition(offline["generation"] as? String == generation && offline["transfer"] == nil)
    receiver = WorkspaceBookmarkReceiver(shared: shared, local: receiverLocal, operations: consumer.operations)
    consumer.events = []
    consumer.operations.stop(receiver.acquire()!)
    precondition(consumer.events == ["resolve:persistent"], "restart uses receiver-owned authority")
    consumer.unavailable.insert(consumer.owned)
    precondition(receiver.acquire() == nil)
    precondition(receiverLocal.dictionary(forKey: "ownedWorkspaceGrant.v1")?["bookmark"] as? Data == consumer.owned,
                 "offline receiver bookmarks are retained")
    consumer.unavailable.removeAll()
    consumer.stale.insert(consumer.owned)
    consumer.failCreate = true
    consumer.operations.stop(receiver.acquire()!)
    precondition(receiverLocal.dictionary(forKey: "ownedWorkspaceGrant.v1")?["bookmark"] as? Data == consumer.owned)
    consumer.failCreate = false
    consumer.operations.stop(receiver.acquire()!)
    consumer.stale.removeAll()

    shared.removeObject(forKey: WorkspaceBookmarkPublisher.sharedKey)
    precondition(receiver.acquire() == nil)
    precondition(receiverLocal.dictionary(forKey: "ownedWorkspaceGrant.v1") != nil, "missing IPC state is not revocation")
    publisher!.publish(Data("different-unavailable-workspace".utf8))
    let next = shared.dictionary(forKey: WorkspaceBookmarkPublisher.sharedKey)!
    shared.set(["generation": next["generation"]!, "revoked": false], forKey: WorkspaceBookmarkPublisher.sharedKey)
    precondition(receiver.acquire() == nil, "old scope cannot authorize a different generation")
    publisher!.publish(nil)
    precondition(receiver.acquire() == nil)
    precondition(receiverLocal.dictionary(forKey: "ownedWorkspaceGrant.v1") == nil, "explicit revocation clears receiver grant")

    issuer.unavailable.removeAll()
    issuer.stale.insert(source)
    let refreshed = publisher!.publish(source)
    let refreshedGeneration = shared.dictionary(forKey: WorkspaceBookmarkPublisher.sharedKey)!["generation"] as! String
    precondition(refreshed == issuer.owned)
    publisher!.publish(refreshed)
    precondition(shared.dictionary(forKey: WorkspaceBookmarkPublisher.sharedKey)!["generation"] as? String == refreshedGeneration,
                 "refreshing the main app bookmark preserves the generation")

    let externalRefresh = Data("refreshed-by-workspace-session".utf8)
    publisher!.preserveGeneration(from: refreshed!, to: externalRefresh)
    publisher!.publish(externalRefresh)
    precondition(shared.dictionary(forKey: WorkspaceBookmarkPublisher.sharedKey)!["generation"] as? String == refreshedGeneration,
                 "a caller's stale-bookmark refresh preserves receiver-owned grants")
    let unrelated = Data("unrelated-workspace".utf8)
    publisher!.preserveGeneration(from: source, to: unrelated)
    publisher!.publish(unrelated)
    precondition(shared.dictionary(forKey: WorkspaceBookmarkPublisher.sharedKey)!["generation"] as? String != refreshedGeneration,
                 "a mismatched refresh cannot preserve authority for a workspace change")

    consumer.onCreate = {
      shared.set(["generation": UUID().uuidString, "revoked": true], forKey: WorkspaceBookmarkPublisher.sharedKey)
    }
    precondition(receiver.acquire() == nil, "revocation during handoff aborts persistence")
    precondition(consumer.activeScopes == 0, "all failure paths balance acquired scopes")
    precondition(receiverLocal.dictionary(forKey: "ownedWorkspaceGrant.v1") == nil)
    var retainedScopes = [URL]()
    let firstOpen = try consumer.operations.acquire(source, scope: .transfer).url
    let repeatedOpen = try consumer.operations.acquire(source, scope: .transfer).url
    consumer.operations.retainForSession([firstOpen, repeatedOpen], in: &retainedScopes)
    precondition(retainedScopes == [consumer.url] && consumer.activeScopes == 1,
                 "long-lived resources keep one scope after the handoff completes")
    for url in retainedScopes { consumer.operations.stop(url) }
    precondition(consumer.activeScopes == 0, "session shutdown releases retained resource access")
    publisher = nil
    precondition(issuer.activeScopes == 0)
    print("Workspace bookmark transfer, restart, offline, refresh, generation and revocation tests passed.")
  }
}
