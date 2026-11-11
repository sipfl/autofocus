import Foundation
import os

let log = Logger(subsystem: "local.autofocus", category: "main")

let workModeID = "com.apple.focus.work"

enum FocusState: Equatable {
    case noAccess
    case off
    case active(id: String, name: String, symbol: String)

    var modeID: String? { if case let .active(id, _, _) = self { return id } else { return nil } }
    var isWork: Bool { modeID == workModeID }

    var label: String {
        switch self {
        case .noAccess: return "Unbekannt (kein Zugriff)"
        case .off: return "Kein Focus"
        case let .active(_, name, _): return name
        }
    }
}

enum FocusReader {
    private static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB")
    static let assertionsURL = dir.appendingPathComponent("Assertions.json")
    private static let modesURL = dir.appendingPathComponent("ModeConfigurations.json")

    static func mtime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: assertionsURL.path))?[.modificationDate] as? Date
    }

    static func read() -> FocusState {
        guard let data = try? Data(contentsOf: assertionsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let store = (root["data"] as? [[String: Any]])?.first
        else { return .noAccess }

        let records = (store["storeAssertionRecords"] as? [[String: Any]]) ?? []
        let latest = records.max {
            ($0["assertionStartDateTimestamp"] as? Double ?? 0) < ($1["assertionStartDateTimestamp"] as? Double ?? 0)
        }
        guard let id = (latest?["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String
        else { return .off }

        let (name, symbol) = modeInfo(id)
        return .active(id: id, name: name, symbol: symbol)
    }

    private static func modeInfo(_ id: String) -> (String, String) {
        guard let data = try? Data(contentsOf: modesURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let configs = ((root["data"] as? [[String: Any]])?.first?["modeConfigurations"]) as? [String: Any],
              let mode = (configs[id] as? [String: Any])?["mode"] as? [String: Any]
        else { return (id.components(separatedBy: ".").last ?? id, "moon.fill") }
        return (mode["name"] as? String ?? id, mode["symbolImageName"] as? String ?? "moon.fill")
    }
}

enum Shortcuts {
    @discardableResult
    static func run(_ name: String, timeout: TimeInterval = 20) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["run", name]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            log.error("shortcut \(name, privacy: .public) failed to start: \(error.localizedDescription, privacy: .public)")
            return false
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            log.error("shortcut \(name, privacy: .public) timed out")
            return false
        }
        let ok = p.terminationStatus == 0
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        log.info("shortcut \(name, privacy: .public) exit=\(p.terminationStatus) \(msg, privacy: .public)")
        return ok
    }
}
