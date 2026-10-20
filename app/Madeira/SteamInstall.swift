// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

// Where Madeira's own Steam downloads live, and how one is read and removed
// (docs/STEAM_LIBRARY.md), and the language its record asks Valve's client
// for. Foundation only, so tests/host/check-steam-library.py
// compiles this file as it is.
//
// A download goes into Madeira Dock's own Steam library folder,
// C:\Program Files (x86)\Steam\steamapps, as `common/<installdir>` plus Steam's
// `appmanifest_<appid>.acf` install record. That is exactly the layout
// Madeira Dock's discovery (MadeiraDock.games) reads and Valve's client, which
// Dock starts the game through, understands: a game is "installed" for Dock
// once its record says so, and the record is written last.

enum SteamInstallPaths {
    /// The library folder, relative to drive_c (the value `DockGame.library` has).
    static let libraryRelative = "Program Files (x86)/Steam/steamapps"

    static func steamApps(drive: URL) -> URL { drive.appendingPathComponent(libraryRelative, isDirectory: true) }
    static func common(drive: URL) -> URL { steamApps(drive: drive).appendingPathComponent("common", isDirectory: true) }

    /// Whether an install (its drive-relative library folder) is in the library
    /// Madeira downloads into, and so can be updated or removed here.
    static func isManaged(library: String) -> Bool {
        library.caseInsensitiveCompare(libraryRelative) == .orderedSame
    }
}

/// Steam's languages by their API names: an install record's and a depot's
/// `language`, and what a game's GetCurrentGameLanguage returns. Names as Steam
/// shows them.
enum SteamLanguage {
    struct Choice: Equatable {
        let code: String
        let name: String
        init(_ code: String, _ name: String) { self.code = code; self.name = name }
    }

    static let all: [Choice] = [
        Choice("english", "English"), Choice("arabic", "Arabic"), Choice("bulgarian", "Bulgarian"),
        Choice("schinese", "Chinese (Simplified)"), Choice("tchinese", "Chinese (Traditional)"), Choice("czech", "Czech"),
        Choice("danish", "Danish"), Choice("dutch", "Dutch"), Choice("finnish", "Finnish"), Choice("french", "French"),
        Choice("german", "German"), Choice("greek", "Greek"), Choice("hungarian", "Hungarian"), Choice("indonesian", "Indonesian"),
        Choice("italian", "Italian"), Choice("japanese", "Japanese"), Choice("koreana", "Korean"), Choice("norwegian", "Norwegian"),
        Choice("polish", "Polish"), Choice("portuguese", "Portuguese (Portugal)"), Choice("brazilian", "Portuguese (Brazil)"),
        Choice("romanian", "Romanian"), Choice("russian", "Russian"), Choice("spanish", "Spanish (Spain)"),
        Choice("latam", "Spanish (Latin America)"), Choice("swedish", "Swedish"), Choice("thai", "Thai"), Choice("turkish", "Turkish"),
        Choice("ukrainian", "Ukrainian"), Choice("vietnamese", "Vietnamese"),
    ]

    static func valid(_ code: String) -> Bool { all.contains { $0.code == code } }
    static func name(_ code: String) -> String { all.first { $0.code == code }?.name ?? code }

    /// The picker's rows: the languages the app lists as supported (its product
    /// info, when cached), else all of them; `current` is always among them.
    static func choices(supported: [String]?, current: String) -> [Choice] {
        let listed = Set((supported ?? []).map { $0.lowercased() })
        let rows = listed.isEmpty ? all : all.filter { listed.contains($0.code) || $0.code == current }
        return rows.contains { $0.code == current } ? rows : rows + [Choice(current, name(current))]
    }
}

enum SteamInstallFiles {
    /// The `buildid` the install record of an app states, or nil when there is
    /// no readable record.
    static func buildID(appID: Int, steamApps: URL) -> Int? {
        guard let state = record(appID: appID, steamApps: steamApps) else { return nil }
        return state["buildid"]?.string.flatMap { Int($0) }
    }

    /// The install size the record states (`SizeOnDisk`, bytes), or nil.
    static func sizeOnDisk(appID: Int, steamApps: URL) -> Int64? {
        guard let state = record(appID: appID, steamApps: steamApps),
              let size = state["SizeOnDisk"]?.string.flatMap({ Int64($0) }), size > 0 else { return nil }
        return size
    }

    /// The language the record asks Valve's client for (`UserConfig.language`),
    /// or nil without a readable record or a known language.
    static func language(appID: Int, steamApps: URL) -> String? {
        guard let code = record(appID: appID, steamApps: steamApps)?["UserConfig"]?["language"]?.string?.lowercased(),
              SteamLanguage.valid(code) else { return nil }
        return code
    }

    /// Sets the record's `UserConfig.language`; false when it already says so.
    /// Only that value changes (an edit of the text, every other byte kept), and
    /// the file is replaced atomically. MountedConfig is left alone: it is what
    /// is installed, and Valve's client compares the two to fetch the language's
    /// depots before it starts the game.
    static func setLanguage(_ language: String, appID: Int, steamApps: URL) throws -> Bool {
        let url = steamApps.appendingPathComponent("appmanifest_\(appID).acf")
        guard record(appID: appID, steamApps: steamApps) != nil, let data = try? Data(contentsOf: url) else {
            throw SteamFileError.invalid("This game's Steam install record cannot be read.")
        }
        if Self.language(appID: appID, steamApps: steamApps) == language { return false }
        guard let edited = settingLanguage(language, in: data) else {
            throw SteamFileError.invalid("This game's Steam install record cannot be changed.")
        }
        try edited.write(to: url, options: .atomic)
        return true
    }

    /// `data` (an install record) with `AppState.UserConfig.language` set, added
    /// where missing; nil when it is not read the way SteamKeyValues reads it or
    /// the result would not say `language`.
    static func settingLanguage(_ language: String, in data: Data) -> Data? {
        guard SteamLanguage.valid(language), data.count <= 1 << 20 else { return nil }
        // Tokens as SteamKeyValues reads them, with their byte ranges (a quoted
        // word's is inside its quotes).
        enum Kind: Equatable { case word(String), open, close }
        let bytes = Array(data)
        var tokens: [(kind: Kind, range: Range<Int>)] = []
        var position = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? 3 : 0
        while true {
            while position < bytes.count {
                if bytes[position] <= 32 { position += 1; continue }
                if bytes[position] == 47, position + 1 < bytes.count, bytes[position + 1] == 47 {
                    while position < bytes.count && bytes[position] != 10 { position += 1 }
                    continue
                }
                break
            }
            guard position < bytes.count else { break }
            guard tokens.count < 100_000 else { return nil }
            let start = position, first = bytes[position]
            position += 1
            if first == 123 { tokens.append((.open, start..<position)); continue }
            if first == 125 { tokens.append((.close, start..<position)); continue }
            if first == 34 {
                var value: [UInt8] = [], closed = false
                while position < bytes.count {
                    let byte = bytes[position]; position += 1
                    if byte == 34 { closed = true; break }
                    if byte == 92, position < bytes.count, bytes[position] == 34 || bytes[position] == 92 {
                        value.append(bytes[position]); position += 1
                    } else { value.append(byte) }
                }
                guard closed else { return nil }
                tokens.append((.word(String(decoding: value, as: UTF8.self)), start + 1..<position - 1))
            } else {
                while position < bytes.count, bytes[position] > 32, bytes[position] != 123, bytes[position] != 125 { position += 1 }
                tokens.append((.word(String(decoding: bytes[start..<position], as: UTF8.self)), start..<position))
            }
        }
        func word(_ i: Int) -> String? {
            guard i < tokens.count, case .word(let text) = tokens[i].kind else { return nil }
            return text.lowercased()
        }
        // The pairs of the object opened at `open` (key -> index of its value) and its
        // closing brace; nested no deeper than SteamKeyValues reads.
        func object(_ open: Int, depth: Int = 1) -> (pairs: [(key: String, value: Int)], close: Int)? {
            guard depth < 32 else { return nil }
            var pairs: [(key: String, value: Int)] = []
            var i = open + 1
            while i < tokens.count {
                if tokens[i].kind == .close { return (pairs, i) }
                guard let key = word(i), i + 1 < tokens.count else { return nil }
                switch tokens[i + 1].kind {
                case .word: pairs.append((key, i + 1)); i += 2
                case .open:
                    pairs.append((key, i + 1))
                    guard let inner = object(i + 1, depth: depth + 1) else { return nil }
                    i = inner.close + 1
                case .close: return nil
                }
            }
            return nil
        }
        guard word(0) == "appstate", tokens.count > 1, tokens[1].kind == .open, let state = object(1) else { return nil }
        let line = "\"language\"\t\t\"\(language)\""
        var edited = bytes
        // The last of a repeated key is the one read, as in SteamKeyValues.
        if let user = state.pairs.last(where: { $0.key == "userconfig" && tokens[$0.value].kind == .open }) {
            guard let config = object(user.value, depth: 2) else { return nil }
            if let current = config.pairs.last(where: { $0.key == "language" && word($0.value) != nil }) {
                edited.replaceSubrange(tokens[current.value].range, with: Array(language.utf8))
            } else {
                edited.insert(contentsOf: Array(("\n\t\t" + line).utf8), at: tokens[user.value].range.upperBound)
            }
        } else {
            edited.insert(contentsOf: Array(("\t\"UserConfig\"\n\t{\n\t\t" + line + "\n\t}\n").utf8),
                          at: tokens[state.close].range.lowerBound)
        }
        guard var parser = try? SteamKeyValues(Data(edited)), let root = try? parser.read(),
              root["AppState"]?["UserConfig"]?["language"]?.string == language else { return nil }
        return Data(edited)
    }

    /// Removes an app's install: its folder under `common`, its record, its
    /// resume journal and the records of the apps that own its shared depots
    /// (those describe the same folder). Only paths strictly inside
    /// `steamApps/common` are removed.
    nonisolated static func delete(appID: Int, folderName: String, steamApps: URL) {
        let fm = FileManager.default
        let common = steamApps.appendingPathComponent("common", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let folder = common.appendingPathComponent(safeFolderName(folderName)).resolvingSymlinksInPath().standardizedFileURL
        if folder.path.hasPrefix(common.path + "/"), folder.deletingLastPathComponent().path == common.path {
            try? fm.removeItem(at: folder)
        }
        let recordURL = steamApps.appendingPathComponent("appmanifest_\(appID).acf")
        if let state = record(appID: appID, steamApps: steamApps) {
            let shared = (state["SharedDepots"]?.fields ?? [:]).sorted(by: { $0.key < $1.key }).prefix(64)
            for (_, owner) in shared {
                guard let ownerID = owner.string.flatMap({ Int($0) }), ownerID > 0, ownerID != appID,
                      let ownerState = record(appID: ownerID, steamApps: steamApps),
                      let dir = ownerState["installdir"]?.string
                else { continue }
                // An owner in another folder (its own installdir) goes too when
                // it holds nothing but depots shared into this app.
                let mine = Set(shared.filter { $0.value.string == owner.string }.map { $0.key })
                let held = Set((ownerState["InstalledDepots"]?.fields ?? [:]).keys)
                guard safeFolderName(dir).caseInsensitiveCompare(safeFolderName(folderName)) == .orderedSame ||
                      held.isSubset(of: mine) else { continue }
                try? fm.removeItem(at: steamApps.appendingPathComponent("appmanifest_\(ownerID).acf"))
            }
        }
        try? fm.removeItem(at: recordURL)
        try? fm.removeItem(at: steamApps.appendingPathComponent("downloading/\(appID)", isDirectory: true))
    }

    /// Validates a manifest path and folds directory spelling to the first
    /// one seen (case-insensitively). Returns nil for anything that could
    /// escape the install folder.
    nonisolated static func safeRelativePath(_ name: String, folded: inout [String: String]) -> String? {
        let parts = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.count <= 64, name.utf8.count < 1024,
              !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains(":") ||
                  $0.unicodeScalars.contains(where: { $0.value < 0x20 }) }) else { return nil }
        var built: [String] = []
        for (index, part) in parts.enumerated() {
            if index == parts.count - 1 { built.append(part); break }
            let key = (built + [part]).joined(separator: "/").lowercased()
            if let existing = folded[key] {
                built = existing.split(separator: "/").map(String.init)
            } else {
                built.append(part)
                folded[key] = built.joined(separator: "/")
            }
        }
        return built.joined(separator: "/")
    }

    /// Install folders come from app metadata; keep them to one safe component.
    nonisolated static func safeFolderName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        guard !cleaned.isEmpty, cleaned != ".", cleaned != "..", !cleaned.contains(":"),
              !cleaned.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return "app" }
        return cleaned
    }

    /// The `AppState` block of `appmanifest_<appid>.acf` when the file is
    /// readable, bounded, and names this app.
    private static func record(appID: Int, steamApps: URL) -> SteamValue? {
        let url = steamApps.appendingPathComponent("appmanifest_\(appID).acf")
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20,
              var parser = try? SteamKeyValues(data), let root = try? parser.read(),
              let state = root["AppState"], state["appid"]?.string == String(appID) else { return nil }
        return state
    }
}
