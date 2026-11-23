import AppKit
import SwiftUI

struct Release: Decodable, Sendable {
  struct Asset: Decodable, Sendable {
    let name: String
    let browserDownloadUrl: URL
  }
  let tagName: String
  let assets: [Asset]
  var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
}

@MainActor
final class Updater: ObservableObject {
  enum Phase {
    case idle, checking, upToDate, installing
    case available(Release)
    case failed(String)
  }

  static let latestURL = URL(string: "https://api.github.com/repos/designfrontier/my-prs/releases/latest")!
  static let assetName = "MyPRs.zip"
  static var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }

  @Published private(set) var phase = Phase.idle

  func check() async {
    phase = .checking
    do {
      var request = URLRequest(url: Self.latestURL)
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      let (data, _) = try await URLSession.shared.data(for: request)
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      let release = try decoder.decode(Release.self, from: data)
      phase = Self.isNewer(release.version, than: Self.currentVersion) ? .available(release) : .upToDate
    } catch {
      phase = .failed("Couldn't check for updates: \(error.localizedDescription)")
    }
  }

  func install(_ release: Release) async {
    phase = .installing
    do {
      guard let asset = release.assets.first(where: { $0.name == Self.assetName }) else {
        throw GitHubError(message: "Release \(release.tagName) has no \(Self.assetName).")
      }
      let app = try await Self.download(asset.browserDownloadUrl)
      _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: app)
      relaunch()
    } catch {
      phase = .failed("Update failed: \(error.localizedDescription)")
    }
  }

  static func isNewer(_ candidate: String, than current: String) -> Bool {
    let parse = { (v: String) in v.split(separator: ".").map { Int($0) ?? 0 } }
    let (a, b) = (parse(candidate), parse(current))
    let pad = { (v: [Int]) in v + Array(repeating: 0, count: max(a.count, b.count) - v.count) }
    return pad(b).lexicographicallyPrecedes(pad(a))
  }

  private static func download(_ url: URL) async throws -> URL {
    let (zip, _) = try await URLSession.shared.download(from: url)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try await run("/usr/bin/ditto", "-x", "-k", zip.path, dir.path)
    let app = dir.appendingPathComponent("MyPRs.app")
    guard FileManager.default.fileExists(atPath: app.path) else {
      throw GitHubError(message: "Downloaded archive has no MyPRs.app.")
    }
    return app
  }

  private static func run(_ tool: String, _ args: String...) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
      process.terminationHandler = {
        $0.terminationStatus == 0
          ? done.resume() : done.resume(throwing: GitHubError(message: "\(tool) exited \($0.terminationStatus)"))
      }
      do { try process.run() } catch { done.resume(throwing: error) }
    }
  }

  // The new copy can only launch once this process has exited, so a shell waits on our PID.
  private func relaunch() {
    let pid = ProcessInfo.processInfo.processIdentifier
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"$0\"", Bundle.main.bundlePath]
    try? process.run()
    NSApp.terminate(nil)
  }
}

struct UpdateSection: View {
  @StateObject private var updater = Updater()

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Version \(Updater.currentVersion)")
        Spacer()
        action
      }
      status.font(.caption).foregroundStyle(.secondary)
    }
    .task { await updater.check() }
  }

  @ViewBuilder private var action: some View {
    switch updater.phase {
    case .checking, .installing: ProgressView().controlSize(.small)
    case .available(let release): Button("Install \(release.tagName)") { Task { await updater.install(release) } }
    default: Button("Check for Updates") { Task { await updater.check() } }
    }
  }

  @ViewBuilder private var status: some View {
    switch updater.phase {
    case .upToDate: Text("You're up to date.")
    case .available: Text("A new version is available. My PRs will restart to install it.")
    case .installing: Text("Installing…")
    case .failed(let message): Text(message).foregroundStyle(.red)
    default: EmptyView()
    }
  }
}
