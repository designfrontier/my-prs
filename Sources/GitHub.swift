import Foundation

struct Review: Hashable, Sendable {
  let login: String
  let state: String
  var isBot: Bool { GitHub.bots.contains(login) }
}

struct PR: Identifiable, Hashable, Sendable {
  let number: Int
  let title: String
  let url: String
  let isDraft: Bool
  let updatedAt: Date
  let additions: Int
  let deletions: Int
  let nameWithOwner: String
  let comments: Int
  let requested: [String]
  let reviews: [Review]
  let bucket: String
  let conflicting: Bool
  let failing: Bool
  let ageDays: Int
  let idleDays: Int

  var id: String { url }
  var repo: String { String(nameWithOwner.split(separator: "/").last ?? "") }

  /// Nobody is on the hook: no request outstanding and no human has looked.
  var unassigned: Bool { requested.isEmpty && reviews.allSatisfy(\.isBot) }

  var who: String {
    if !requested.isEmpty { return "\(requested.joined(separator: ", ")) pending" }
    let humans = reviews.filter { !$0.isBot }
    if !humans.isEmpty {
      return humans
        .map { "\($0.login) \($0.state.lowercased().replacingOccurrences(of: "_", with: " "))" }
        .joined(separator: ", ")
    }
    return reviews.isEmpty ? "nobody" : "\(reviews.map(\.login).joined(separator: ", ")) only"
  }
}

extension PR {
  static func bucket(approved: Bool, changesRequested: Bool, conflicting: Bool, failing: Bool, pending: Bool) -> String {
    approved && !failing && !conflicting ? "ready"
      : changesRequested ? "changes"
      : conflicting ? "conflicting"
      : failing ? "failing"
      : pending ? "running"
      : "review"
  }

  static func days(since date: Date) -> Int { Int(Date().timeIntervalSince(date) / 86400) }
}

struct GitHubError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

enum GitHub {
  static let bots: Set<String> = [
    "claude", "cursor", "github-actions", "dependabot", "renovate", "copilot-pull-request-reviewer",
  ]

  static func fetch(org: String, author: String, drafts: Bool, archived: Bool) async throws -> [PR] {
    let q = (["is:pr", "is:open", "org:\(org)", "author:\(author)", "sort:updated-desc"]
      + (drafts ? [] : ["draft:false"]) + (archived ? [] : ["archived:false"])).joined(separator: " ")
    let token = try await Token.shared.get()

    var nodes: [RawPR] = []
    var cursor: String?
    repeat {
      let page = try await search(q: q, cursor: cursor, token: token)
      nodes += page.nodes.compactMap(\.pr)
      cursor = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : nil
    } while cursor != nil

    return nodes.map(enrich)
  }

  private static func search(q: String, cursor: String?, token: String) async throws -> SearchPage {
    var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
    request.httpMethod = "POST"
    request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "query": query,
      "variables": ["q": q, "cursor": cursor as Any],
    ])

    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 401 {
      await Token.shared.reset()
      throw GitHubError(message: "GitHub rejected the token. Try: gh auth login")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let body = try decoder.decode(SearchResponse.self, from: data)
    if let message = body.errors?.first?.message { throw GitHubError(message: message) }
    guard let page = body.data?.search else { throw GitHubError(message: "GitHub returned HTTP \(status)") }
    return page
  }

  private static func enrich(_ pr: RawPR) -> PR {
    let ci = pr.commits.nodes.first?.commit.statusCheckRollup?.state
    let conflicting = pr.mergeable == "CONFLICTING"
    let failing = ci == "FAILURE" || ci == "ERROR"

    return PR(
      number: pr.number,
      title: pr.title,
      url: pr.url,
      isDraft: pr.isDraft,
      updatedAt: pr.updatedAt,
      additions: pr.additions,
      deletions: pr.deletions,
      nameWithOwner: pr.repository.nameWithOwner,
      comments: pr.comments.totalCount,
      requested: pr.reviewRequests.nodes.compactMap { $0.requestedReviewer?.login ?? $0.requestedReviewer?.name },
      reviews: pr.latestReviews.nodes.compactMap { r in r.author.map { Review(login: $0.login, state: r.state) } },
      bucket: PR.bucket(
        approved: pr.reviewDecision == "APPROVED",
        changesRequested: pr.reviewDecision == "CHANGES_REQUESTED",
        conflicting: conflicting,
        failing: failing,
        pending: ci == "PENDING"
      ),
      conflicting: conflicting,
      failing: failing,
      ageDays: PR.days(since: pr.createdAt),
      idleDays: PR.days(since: pr.updatedAt)
    )
  }

  private static let query = """
    query($q: String!, $cursor: String) {
      search(query: $q, type: ISSUE, first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          ... on PullRequest {
            number title url isDraft createdAt updatedAt additions deletions reviewDecision mergeable
            repository { nameWithOwner }
            comments { totalCount }
            commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
            reviewRequests(first: 20) {
              nodes { requestedReviewer { ... on User { login } ... on Team { name } } }
            }
            latestReviews(first: 20) { nodes { author { login } state } }
          }
        }
      }
    }
    """
}

/// Borrows the gh CLI's token so there is no separate login to manage.
actor Token {
  static let shared = Token()
  private var cached: String?

  func reset() { cached = nil }

  func get() async throws -> String {
    if let cached { return cached }
    let token = try await Task.detached { try Self.fromGh() }.value
    cached = token
    return token
  }

  // GUI apps get a bare PATH, so check the usual install locations directly.
  private static let ghPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

  private static func fromGh() throws -> String {
    guard let gh = ghPaths.first(where: FileManager.default.isExecutableFile) else {
      throw GitHubError(message: "gh not found. Install it (brew install gh) and run: gh auth login")
    }
    let process = Process()
    let out = Pipe()
    process.executableURL = URL(fileURLWithPath: gh)
    process.arguments = ["auth", "token"]
    process.standardOutput = out
    process.standardError = Pipe()
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0, !token.isEmpty else {
      throw GitHubError(message: "gh is not logged in. Run: gh auth login")
    }
    return token
  }
}

private struct SearchResponse: Decodable {
  struct Payload: Decodable { let search: SearchPage }
  struct Message: Decodable { let message: String }
  let data: Payload?
  let errors: [Message]?
}

private struct SearchPage: Decodable {
  struct PageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
  }
  // Search can return non-PR nodes as empty objects; skip them instead of failing the page.
  struct Node: Decodable {
    let pr: RawPR?
    init(from decoder: Decoder) throws { pr = try? RawPR(from: decoder) }
  }
  let pageInfo: PageInfo
  let nodes: [Node]
}

private struct Nodes<T: Decodable>: Decodable { let nodes: [T] }

private struct RawPR: Decodable {
  struct Repo: Decodable { let nameWithOwner: String }
  struct Count: Decodable { let totalCount: Int }
  struct Commit: Decodable {
    struct Inner: Decodable {
      struct Rollup: Decodable { let state: String }
      let statusCheckRollup: Rollup?
    }
    let commit: Inner
  }
  struct Request: Decodable {
    struct Reviewer: Decodable {
      let login: String?
      let name: String?
    }
    let requestedReviewer: Reviewer?
  }
  struct RawReview: Decodable {
    struct Author: Decodable { let login: String }
    let author: Author?
    let state: String
  }

  let number: Int
  let title: String
  let url: String
  let isDraft: Bool
  let createdAt: Date
  let updatedAt: Date
  let additions: Int
  let deletions: Int
  let reviewDecision: String?
  let mergeable: String?
  let repository: Repo
  let comments: Count
  let commits: Nodes<Commit>
  let reviewRequests: Nodes<Request>
  let latestReviews: Nodes<RawReview>
}
