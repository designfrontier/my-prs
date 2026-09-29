import Foundation
import Security

/// Gitea and Forgejo share the `/api/v1` REST API, so one client serves both.
enum Gitea {
  private static let pageSize = 50

  static func fetch(server: Server, base: String, owner: String, author: String, drafts: Bool) async throws -> [PR] {
    guard let account = normalize(base), let url = URL(string: account) else {
      throw GitHubError(message: "Set your \(server.name) URL in Settings.")
    }
    guard let token = Keychain.token(for: account) else {
      throw GitHubError(message: "Add a \(server.name) access token in Settings.")
    }
    let api = Client(server: server, base: url, token: token)
    let me = author == "@me"
    let issues = try await search(api, owner: owner, mine: me)
      .filter { me || $0.user.login.caseInsensitiveCompare(author) == .orderedSame }

    let tasks = issues.map { issue in (issue, Task.detached { try await details(issue, api) }) }
    var prs: [PR] = []
    // Some servers 404 on PR details (e.g. archived repos); show what search returned instead.
    for (issue, task) in tasks { prs.append((try? await task.value) ?? build(issue)) }
    return prs.filter { drafts || !$0.isDraft }
  }

  static func normalize(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if trimmed.isEmpty { return nil }
    return trimmed.contains("://") ? trimmed : "https://\(trimmed)"
  }

  private static func search(_ api: Client, owner: String, mine: Bool, page: Int = 1) async throws -> [Issue] {
    let batch: [Issue] = try await api.get(
      "repos/issues/search",
      ["type": "pulls", "state": "open", "owner": owner, "page": "\(page)", "limit": "\(pageSize)"]
        .merging(mine ? ["created": "true"] : [:]) { a, _ in a }
    )
    return batch.count < pageSize ? batch : try await batch + search(api, owner: owner, mine: mine, page: page + 1)
  }

  private static func details(_ issue: Issue, _ api: Client) async throws -> PR {
    let path = "repos/\(issue.repository.fullName)/pulls/\(issue.number)"
    let pull: Pull = try await api.get(path)
    let reviews: [RawReview] = try await api.get("\(path)/reviews", ["limit": "\(pageSize)"])
    let status: Status = try await api.get("repos/\(issue.repository.fullName)/commits/\(pull.head.sha)/status")
    return build(issue, pull: pull, reviews: reviews, ci: status.state)
  }

  private static func build(_ issue: Issue, pull: Pull? = nil, reviews: [RawReview] = [], ci: String? = nil) -> PR {
    // Later comments don't undo an approval or change request, matching GitHub's review decision.
    let latest = reviews.reduce(into: [String: String]()) { acc, review in
      guard let login = review.user?.login, login != issue.user.login, review.dismissed != true,
        let state = reviewStates[review.state]
      else { return }
      if state != "COMMENTED" || acc[login] == nil { acc[login] = state }
    }
    let states = Set(latest.values)
    let conflicting = pull?.mergeable == false
    let failing = ci == "failure" || ci == "error"

    return PR(
      number: issue.number,
      title: issue.title,
      url: issue.htmlUrl,
      isDraft: pull?.draft ?? isWip(issue.title),
      updatedAt: issue.updatedAt,
      additions: pull?.additions ?? 0,
      deletions: pull?.deletions ?? 0,
      nameWithOwner: issue.repository.fullName,
      comments: issue.comments,
      requested: (pull?.requestedReviewers ?? []).map(\.login) + (pull?.requestedReviewersTeams ?? []).map(\.name),
      reviews: latest.sorted { $0.key < $1.key }.map { Review(login: $0.key, state: $0.value) },
      bucket: PR.bucket(
        approved: states.contains("APPROVED"),
        changesRequested: states.contains("CHANGES_REQUESTED"),
        conflicting: conflicting,
        failing: failing,
        pending: ci == "pending"
      ),
      conflicting: conflicting,
      failing: failing,
      ageDays: PR.days(since: issue.createdAt),
      idleDays: PR.days(since: issue.updatedAt)
    )
  }

  private static let reviewStates = ["APPROVED": "APPROVED", "REQUEST_CHANGES": "CHANGES_REQUESTED", "COMMENT": "COMMENTED"]

  // Servers too old to report `draft` use Gitea's title-prefix convention.
  private static func isWip(_ title: String) -> Bool {
    ["WIP:", "[WIP]"].contains { title.uppercased().hasPrefix($0) }
  }
}

private struct Client: Sendable {
  let server: Server
  let base: URL
  let token: String

  func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
    var components = URLComponents(url: base.appending(path: "api/v1/\(path)"), resolvingAgainstBaseURL: false)!
    components.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.key, value: $0.value) }
    var request = URLRequest(url: components.url!)
    request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 401 { throw GitHubError(message: "\(server.name) rejected the token. Check it in Settings.") }
    guard (200..<300).contains(status) else {
      let message = (try? JSONDecoder().decode(APIMessage.self, from: data))?.message
      throw GitHubError(message: message ?? "\(server.name) returned HTTP \(status)")
    }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: data)
  }
}

private struct APIMessage: Decodable { let message: String }
private struct User: Decodable { let login: String }

private struct Issue: Decodable {
  struct Repo: Decodable { let fullName: String }
  let number: Int
  let title: String
  let htmlUrl: String
  let comments: Int
  let createdAt: Date
  let updatedAt: Date
  let user: User
  let repository: Repo
}

private struct Pull: Decodable {
  struct Head: Decodable { let sha: String }
  struct Team: Decodable { let name: String }
  let draft: Bool?
  let mergeable: Bool?
  let additions: Int?
  let deletions: Int?
  let head: Head
  let requestedReviewers: [User]?
  let requestedReviewersTeams: [Team]?
}

private struct RawReview: Decodable {
  let user: User?
  let state: String
  let dismissed: Bool?
}

private struct Status: Decodable { let state: String }

enum Keychain {
  static let didChange = Notification.Name("KeychainTokenDidChange")
  private static let service = "com.danielsellers.myprs"

  private static func query(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
  }

  static func token(for account: String) -> String? {
    var result: AnyObject?
    let status = SecItemCopyMatching(
      query(account).merging([kSecReturnData as String: true]) { a, _ in a } as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  static func setToken(_ token: String, for account: String) {
    SecItemDelete(query(account) as CFDictionary)
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      SecItemAdd(query(account).merging([kSecValueData as String: Data(trimmed.utf8)]) { a, _ in a } as CFDictionary, nil)
    }
    NotificationCenter.default.post(name: didChange, object: nil)
  }
}
