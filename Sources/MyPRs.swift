import AppKit
import SwiftUI

struct Section: Identifiable {
  let key: String
  let label: String
  let color: Color
  var id: String { key }
}

let sections = [
  Section(key: "ready", label: "Ready to merge", color: .green),
  Section(key: "changes", label: "Changes requested", color: .orange),
  Section(key: "conflicting", label: "Conflicting — needs rebase", color: .orange),
  Section(key: "failing", label: "CI failing", color: .red),
  Section(key: "running", label: "CI running", color: .yellow),
  Section(key: "review", label: "Green, waiting on review", color: .blue),
]

enum Server: String, CaseIterable, Identifiable, Sendable {
  case github, gitea, forgejo
  var id: String { rawValue }
  var name: String {
    switch self {
    case .github: "GitHub"
    case .gitea: "Gitea"
    case .forgejo: "Forgejo"
    }
  }
}

struct Settings: Equatable, Sendable {
  var server: Server
  var serverURL: String
  var orgs: [String]
  var author: String
  var drafts: Bool
  var archived: Bool
  var pollMinutes: Int

  static var defaults: [String: Any] { ["server": "github", "serverURL": "", "orgs": "voze-hq", "author": "@me", "drafts": false, "archived": false, "pollMinutes": 5] }

  static var current: Settings {
    let d = UserDefaults.standard
    return Settings(
      server: Server(rawValue: d.string(forKey: "server") ?? "") ?? .github,
      serverURL: d.string(forKey: "serverURL") ?? "",
      orgs: parseOrgs(d.string(forKey: "orgs") ?? ""),
      author: d.string(forKey: "author") ?? "@me",
      drafts: d.bool(forKey: "drafts"),
      archived: d.bool(forKey: "archived"),
      pollMinutes: max(1, d.integer(forKey: "pollMinutes"))
    )
  }
}

func parseOrgs(_ raw: String) -> [String] {
  raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
}

@MainActor
final class Store: ObservableObject {
  @Published var prs: [PR] = []
  @Published var errors: [String] = []
  @Published var lastRun: Date?
  @Published var loading = false
  @Published private(set) var settings = Settings.current

  private var loop: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []

  init() {
    observers = [
      NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
        [weak self] _ in Task { @MainActor in self?.settingsChanged() }
      },
      NotificationCenter.default.addObserver(forName: Keychain.didChange, object: nil, queue: .main) {
        [weak self] _ in Task { @MainActor in self?.reload() }
      },
    ]
    restart()
  }

  // PR url → bucket as of the last time the popover was opened.
  private var seen = UserDefaults.standard.dictionary(forKey: "seen") as? [String: String]
  @Published private(set) var changed: Set<String> = []
  @Published private(set) var removed = 0
  var hasChanges: Bool { !changed.isEmpty || removed > 0 }

  func markSeen() {
    seen = Dictionary(prs.map { ($0.url, $0.bucket) }, uniquingKeysWith: { a, _ in a })
    UserDefaults.standard.set(seen, forKey: "seen")
    changed = []
    removed = 0
  }

  private func detectChanges() {
    guard let seen else { return markSeen() }
    let current = Dictionary(prs.map { ($0.url, $0.bucket) }, uniquingKeysWith: { a, _ in a })
    changed = Set(current.filter { seen[$0.key] != $0.value }.keys)
    removed = seen.keys.filter { current[$0] == nil }.count
  }

  // UserDefaults also changes on window moves, so only restart when our settings differ.
  private func settingsChanged() {
    if Settings.current != settings { reload() }
  }

  private func reload() {
    seen = nil
    restart()
  }

  private func restart() {
    settings = Settings.current
    loop?.cancel()
    loop = Task { [weak self] in
      // Brief delay debounces settings edits so each keystroke doesn't trigger a fetch.
      try? await Task.sleep(for: .milliseconds(600))
      while !Task.isCancelled, let self {
        await self.refresh()
        try? await Task.sleep(for: .seconds(self.settings.pollMinutes * 60))
      }
    }
  }

  func refresh() async {
    let settings = self.settings
    loading = true
    defer { loading = false }

    let tasks = settings.orgs.map { org in
      (org, Task.detached { try await fetch(org: org, settings: settings) })
    }
    var results: [(String, Result<[PR], Error>)] = []
    for (org, task) in tasks { results.append((org, await task.result)) }
    if Task.isCancelled { return }

    prs = results.flatMap { (try? $0.1.get()) ?? [] }
    errors = results.compactMap { org, result in
      guard case .failure(let error) = result else { return nil }
      return "\(org): \(error.localizedDescription)"
    }
    lastRun = Date()
    // A failed org drops its PRs from the list, which would read as "all removed".
    if errors.isEmpty { detectChanges() }
  }
}

func fetch(org: String, settings: Settings) async throws -> [PR] {
  settings.server == .github
    ? try await GitHub.fetch(org: org, author: settings.author, drafts: settings.drafts, archived: settings.archived)
    : try await Gitea.fetch(
      server: settings.server, base: settings.serverURL, owner: org, author: settings.author,
      drafts: settings.drafts, archived: settings.archived)
}

struct PRRow: View {
  let pr: PR
  let showOrg: Bool
  let isChanged: Bool
  @Environment(\.openURL) private var openURL

  var body: some View {
    Button { URL(string: pr.url).map { openURL($0) } } label: {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          if isChanged { Circle().fill(.blue).frame(width: 7, height: 7).help("Changed since you last looked") }
          Text(verbatim: "\(showOrg ? pr.nameWithOwner : pr.repo) #\(pr.number)").bold()
          if pr.isDraft { Text("draft").font(.caption).foregroundStyle(.secondary) }
          Text(pr.title).lineLimit(1).truncationMode(.tail)
        }
        HStack(spacing: 0) {
          Text(meta).foregroundStyle(.secondary)
          if pr.unassigned { Text(" · no reviewer").foregroundStyle(.orange) }
          if pr.conflicting && pr.bucket != "conflicting" { Text(" · conflicting").foregroundStyle(.orange) }
          if pr.failing && pr.bucket != "failing" { Text(" · CI red").foregroundStyle(.red) }
        }
        .font(.caption)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(pr.url)
  }

  var meta: String {
    let n = pr.comments
    return ([
      "+\(pr.additions)/-\(pr.deletions)",
      "\(pr.idleDays)d idle",
      "\(pr.ageDays)d old",
      pr.who,
    ] + (n > 0 ? ["\(n) comment\(n == 1 ? "" : "s")"] : []))
      .joined(separator: " · ")
  }
}

struct ContentView: View {
  @ObservedObject var store: Store
  @Environment(\.openSettings) private var openSettings
  var settings: Settings { store.settings }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      list
      Divider()
      footer
    }
    .frame(width: 540, height: 620)
    .onDisappear { store.markSeen() }
  }

  var header: some View {
    let counts = sections.compactMap { s -> String? in
      let n = store.prs.filter { $0.bucket == s.key }.count
      return n > 0 ? "\(n) \(s.label.lowercased().components(separatedBy: " —")[0])" : nil
    }
    let unassigned = store.prs.filter(\.unassigned).count
    let removed = store.removed
    return VStack(alignment: .leading, spacing: 2) {
      Text((["\(store.prs.count) open"] + counts).joined(separator: "  ·  ")).bold()
      if unassigned > 0 {
        Text("\(unassigned) with no reviewer assigned").font(.caption).foregroundStyle(.secondary)
      }
      if removed > 0 {
        Text("\(removed) closed or merged since you last looked").font(.caption).foregroundStyle(.blue)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
  }

  @ViewBuilder
  var list: some View {
    if store.prs.isEmpty {
      Text(store.lastRun == nil ? "Loading…" : "No open pull requests. Enjoy it.")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      List {
        ForEach(sections) { section in
          let group = store.prs
            .filter { $0.bucket == section.key }
            .sorted { $0.updatedAt > $1.updatedAt }
          if !group.isEmpty {
            SwiftUI.Section {
              ForEach(group) { PRRow(pr: $0, showOrg: settings.orgs.count > 1, isChanged: store.changed.contains($0.url)) }
            } header: {
              Text("\(section.label) (\(group.count))").foregroundStyle(section.color).bold()
            }
          }
        }
      }
    }
  }

  var footer: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(store.errors, id: \.self) { error in
        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(3)
      }
      HStack {
        if store.loading { ProgressView().controlSize(.small) }
        Text(status).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Refresh") { Task { await store.refresh() } }
          .keyboardShortcut("r")
          .disabled(store.loading)
        Button {
          // Menu bar apps aren't frontmost, so the settings window would open behind everything.
          NSApp.activate()
          openSettings()
        } label: { Image(systemName: "gearshape") }
          .keyboardShortcut(",")
          .help("Settings")
        Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
          .keyboardShortcut("q")
          .help("Quit")
      }
    }
    .padding(8)
  }

  var status: String {
    let every = "every \(settings.pollMinutes)m · \(settings.server.name) · \(settings.orgs.joined(separator: ", "))"
    guard let last = store.lastRun else { return every }
    return "Updated \(last.formatted(date: .omitted, time: .shortened)) · \(every)"
  }
}

struct SettingsView: View {
  @AppStorage("server") private var server = Server.github
  @AppStorage("serverURL") private var serverURL = ""
  @AppStorage("orgs") private var orgsRaw = "voze-hq"
  @AppStorage("author") private var author = "@me"
  @AppStorage("drafts") private var drafts = false
  @AppStorage("archived") private var archived = false
  @AppStorage("pollMinutes") private var pollMinutes = 5

  var body: some View {
    Form {
      Picker("Server", selection: $server) {
        ForEach(Server.allCases) { Text($0.name).tag($0) }
      }
      if server != .github {
        TextField("URL", text: $serverURL, prompt: Text(server == .forgejo ? "codeberg.org" : "gitea.example.com"))
        TokenField(account: Gitea.normalize(serverURL))
      }
      TextField(server == .github ? "Orgs" : "Owners", text: $orgsRaw, prompt: Text("voze-hq, another-org"))
      Text("Comma or space separated.").font(.caption).foregroundStyle(.secondary)
      TextField("Author", text: $author, prompt: Text("@me"))
      if server != .github && author != "@me" {
        Text("Other authors are filtered locally from every open PR the token can see.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Toggle("Include drafts", isOn: $drafts)
      Toggle("Include archived repos", isOn: $archived)
      Stepper("Poll every \(pollMinutes) min", value: $pollMinutes, in: 1...60)
    }
    .padding(20)
    .frame(width: 400)
  }
}

/// Access tokens live in the Keychain, keyed by server URL, rather than in UserDefaults.
struct TokenField: View {
  let account: String?
  @State private var token = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      SecureField("Token", text: $token, prompt: Text("Settings → Applications → Generate token"))
        .disabled(account == nil)
        .onSubmit(save)
      Text("Needs read access to repositories and issues. Press Return to save.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .onAppear(perform: load)
    .onChange(of: account) { load() }
  }

  private func load() { token = account.flatMap(Keychain.token) ?? "" }
  private func save() { account.map { Keychain.setToken(token, for: $0) } }
}

@main
struct MyPRsApp: App {
  @StateObject private var store: Store

  init() {
    UserDefaults.standard.register(defaults: Settings.defaults)
    _store = StateObject(wrappedValue: Store())
  }

  var body: some Scene {
    MenuBarExtra {
      ContentView(store: store)
    } label: {
      Image(nsImage: menuBarIcon(dot: store.hasChanges))
    }
    .menuBarExtraStyle(.window)
    SwiftUI.Settings { SettingsView() }
  }
}

func menuBarIcon(dot: Bool) -> NSImage {
  let image = NSImage(size: NSSize(width: dot ? 21 : 18, height: 18), flipped: false) { _ in
    let ring = { (x: CGFloat, y: CGFloat) in NSBezierPath(ovalIn: NSRect(x: x - 2.2, y: y - 2.2, width: 4.4, height: 4.4)) }
    let glyph = NSBezierPath()
    [ring(5, 14.5), ring(5, 3.5), ring(13, 3.5)].forEach { glyph.append($0) }
    glyph.move(to: NSPoint(x: 5, y: 5.7))
    glyph.line(to: NSPoint(x: 5, y: 12.3))
    glyph.move(to: NSPoint(x: 13, y: 5.7))
    glyph.line(to: NSPoint(x: 13, y: 12))
    glyph.curve(to: NSPoint(x: 11, y: 14.5), controlPoint1: NSPoint(x: 13, y: 13.5), controlPoint2: NSPoint(x: 12.5, y: 14.5))
    glyph.line(to: NSPoint(x: 8.6, y: 14.5))
    glyph.move(to: NSPoint(x: 10.4, y: 16.3))
    glyph.line(to: NSPoint(x: 8.6, y: 14.5))
    glyph.line(to: NSPoint(x: 10.4, y: 12.7))
    glyph.lineWidth = 1.6
    glyph.lineCapStyle = .round
    glyph.lineJoinStyle = .round
    NSColor.black.set()
    glyph.stroke()
    guard dot else { return true }
    let rect = NSRect(x: 15, y: 12.2, width: 5.8, height: 5.8)
    NSGraphicsContext.current?.compositingOperation = .clear
    NSBezierPath(ovalIn: rect.insetBy(dx: -1.4, dy: -1.4)).fill()
    NSGraphicsContext.current?.compositingOperation = .sourceOver
    NSBezierPath(ovalIn: rect).fill()
    return true
  }
  image.isTemplate = true
  image.accessibilityDescription = "My PRs"
  return image
}
