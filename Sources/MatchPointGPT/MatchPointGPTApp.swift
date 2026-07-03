import AppKit
import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import SwiftUI

@main
struct MatchPointGPTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RadarView()
                .preferredColorScheme(.dark)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1320, height: 840)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Models

struct DatabaseSettings: Equatable {
    var host: String
    var port: Int
    var database: String
    var user: String
    var password: String
}

enum SettingsStore {
    static func loadDatabaseSettings() -> DatabaseSettings {
        let env = loadEnvironment()
        return DatabaseSettings(
            host: UserDefaults.standard.string(forKey: "database.host") ?? env["MYSQL_HOST"] ?? "pi-sql",
            port: int("database.port") ?? Int(env["MYSQL_PORT"] ?? "") ?? 3306,
            database: UserDefaults.standard.string(forKey: "database.name") ?? env["MYSQL_DATABASE"] ?? "atp",
            user: UserDefaults.standard.string(forKey: "database.user") ?? env["MYSQL_USER"] ?? "root",
            password: nonEmpty(UserDefaults.standard.string(forKey: "database.password")) ?? env["MYSQL_PASSWORD"] ?? ""
        )
    }

    private static func loadEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.merging(loadAppSupportEnv()) { _, fileValue in fileValue }
    }

    private static func loadAppSupportEnv() -> [String: String] {
        guard
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            return [:]
        }

        let envURL = appSupport
            .appendingPathComponent("Match Point GPT", isDirectory: true)
            .appendingPathComponent(".env")
        guard let contents = try? String(contentsOf: envURL, encoding: .utf8) else {
            return [:]
        }

        return parseEnv(contents)
    }

    private static func parseEnv(_ contents: String) -> [String: String] {
        contents
            .split(whereSeparator: \.isNewline)
            .reduce(into: [String: String]()) { result, line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else {
                    return
                }

                let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rawValue = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                result[key] = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
    }

    private static func int(_ key: String) -> Int? {
        UserDefaults.standard.integer(forKey: key).nonZero
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

enum MatchState: String, Equatable {
    case live
    case upcoming

    var title: String {
        switch self {
        case .live:
            return "Live"
        case .upcoming:
            return "Kommande"
        }
    }
}

struct MatchPlayer: Equatable {
    let id: String?
    let name: String
    let country: String?
    let rank: Int?
    let odds: Double?

    var lastName: String {
        name.split(separator: " ").last.map(String.init) ?? name
    }
}

struct RadarMatch: Identifiable, Equatable {
    let id: String
    let start: Date?
    let tournament: String?
    let state: MatchState
    let score: String?
    let serve: String?
    let playerA: MatchPlayer
    let playerB: MatchPlayer
    let source: String

    var matchupTitle: String {
        "\(playerA.name) vs \(playerB.name)"
    }

    var surfaceGuess: String {
        let text = (tournament ?? "").lowercased()
        if text.contains("wimbledon") || text.contains("halle") || text.contains("grass") {
            return "Grass"
        }
        if text.contains("roland") || text.contains("clay") || text.contains("båstad") {
            return "Clay"
        }
        return "Hard"
    }

    var startTitle: String {
        guard let start else { return "Tid saknas" }
        let calendar = Calendar.current
        let prefix: String
        if calendar.isDateInToday(start) {
            prefix = "Idag"
        } else if calendar.isDateInTomorrow(start) {
            prefix = "I morgon"
        } else if calendar.isDateInYesterday(start) {
            prefix = "I går"
        } else {
            let day = DateFormatter()
            day.locale = Locale(identifier: "sv_SE")
            day.setLocalizedDateFormatFromTemplate("d MMM")
            prefix = day.string(from: start)
        }

        let time = DateFormatter()
        time.locale = Locale(identifier: "sv_SE")
        time.dateFormat = "HH:mm"
        return "\(prefix) \(time.string(from: start))"
    }
}

struct PlayerStats: Equatable {
    let id: String
    let name: String
    let country: String?
    let rank: Int?
    let points: Int?
    let elo: Int?
    let surfaceElo: Int?
    let recentMatches: [HistoricalMatch]

    var imageURL: URL? {
        URL(string: "https://www.atptour.com/-/media/alias/player-headshot/\(id.lowercased())")
    }
}

struct HistoricalMatch: Identifiable, Equatable {
    let id: String
    let date: String
    let tournament: String
    let surface: String?
    let winner: String
    let loser: String
    let winnerRank: Int?
    let loserRank: Int?
    let score: String?

    func didWin(_ player: String) -> Bool { winner == player }

    func opponent(for player: String) -> String {
        didWin(player) ? loser : winner
    }

    func opponentRank(for player: String) -> Int? {
        didWin(player) ? loserRank : winnerRank
    }

    func playerRank(for player: String) -> Int? {
        didWin(player) ? winnerRank : loserRank
    }
}

struct PlayerPulse: Equatable {
    let health: Int
    let formRecord: String
    let title: String
    let note: String
    let standoutWins: [HistoricalMatch]
    let warningLosses: [HistoricalMatch]

    init(player: PlayerStats?) {
        guard let player else {
            health = 2
            formRecord = "-"
            title = "Väntar på ATP"
            note = "Marknaden finns. Databassignalen fylls på när spelaren matchas."
            standoutWins = []
            warningLosses = []
            return
        }

        let recent = Array(player.recentMatches.prefix(12))
        let wins = recent.filter { $0.didWin(player.name) }.count
        let losses = max(0, recent.count - wins)
        let standout = player.recentMatches.filter { match in
            guard match.didWin(player.name), let own = match.playerRank(for: player.name), let opponent = match.opponentRank(for: player.name) else { return false }
            return opponent < own && own - opponent >= 15
        }
        let warnings = player.recentMatches.filter { match in
            guard !match.didWin(player.name), let own = match.playerRank(for: player.name), let opponent = match.opponentRank(for: player.name) else { return false }
            return opponent > own && opponent - own >= 20
        }

        let base = recent.isEmpty ? 2.5 : Double(wins) / Double(max(1, recent.count)) * 5
        let standoutBonus = Double(standout.prefix(3).count) * 0.35
        let warningPenalty = Double(warnings.prefix(3).count) * 0.45
        let rawHealth = base + standoutBonus - warningPenalty
        let computed = Int(rawHealth.rounded())
        health = min(5, max(1, computed))
        formRecord = "\(wins)-\(losses)"
        standoutWins = Array(standout.prefix(3))
        warningLosses = Array(warnings.prefix(3))

        switch health {
        case 5:
            title = "Boss-läge"
        case 4:
            title = "Het"
        case 3:
            title = "Stabil"
        case 2:
            title = "Skör"
        default:
            title = "Röd zon"
        }

        if standoutWins.isEmpty == false {
            note = "Har färska vinster mot bättre rankade spelare."
        } else if warningLosses.isEmpty == false {
            note = "Har släppt matcher mot lägre rankat motstånd."
        } else if wins > losses {
            note = "Formkurvan pekar uppåt utan tydliga extrema signaler."
        } else {
            note = "Ingen fri lunch här. Formen behöver granskas."
        }
    }
}

struct MatchRadar: Equatable {
    let match: RadarMatch
    let playerA: PlayerStats?
    let playerB: PlayerStats?
    let modelA: Double?

    var pulseA: PlayerPulse { PlayerPulse(player: playerA) }
    var pulseB: PlayerPulse { PlayerPulse(player: playerB) }

    var modelB: Double? {
        modelA.map { 1 - $0 }
    }

    var favoriteName: String {
        let marketFavorite = [match.playerA, match.playerB].compactMap { player -> (String, Double)? in
            guard let odds = player.odds else { return nil }
            return (player.name, odds)
        }.min { $0.1 < $1.1 }?.0

        return marketFavorite ?? "Okänd"
    }

    var marketSpread: Double? {
        guard let a = match.playerA.odds, let b = match.playerB.odds else { return nil }
        return abs(a - b)
    }

    var marketPulse: Int {
        guard let spread = marketSpread else { return 2 }
        switch spread {
        case 0..<0.35:
            return 2
        case 0.35..<0.85:
            return 3
        case 0.85..<1.70:
            return 4
        default:
            return 5
        }
    }

    var atpCoverage: Int {
        [playerA, playerB].compactMap { $0 }.count
    }

    var modelFavorite: String {
        guard let modelA else { return "Väntar" }
        if modelA >= 0.53 {
            return match.playerA.lastName
        }
        if modelA <= 0.47 {
            return match.playerB.lastName
        }
        return "Jämnt"
    }

    var marketFavoriteSide: Int? {
        guard let a = match.playerA.odds, let b = match.playerB.odds else { return nil }
        if abs(a - b) < 0.03 { return nil }
        return a < b ? 0 : 1
    }

    var modelFavoriteSide: Int? {
        guard let modelA else { return nil }
        if modelA >= 0.53 { return 0 }
        if modelA <= 0.47 { return 1 }
        return nil
    }

    var surfaceEdgeSide: Int? {
        guard let a = playerA?.surfaceElo, let b = playerB?.surfaceElo else { return nil }
        if abs(a - b) < 35 { return nil }
        return a > b ? 0 : 1
    }

    var surfaceEdgeValue: Int? {
        guard let a = playerA?.surfaceElo, let b = playerB?.surfaceElo else { return nil }
        return abs(a - b)
    }

    var healthEdgeSide: Int? {
        if pulseA.health == pulseB.health { return nil }
        return pulseA.health > pulseB.health ? 0 : 1
    }

    func playerLastName(side: Int) -> String {
        side == 0 ? match.playerA.lastName : match.playerB.lastName
    }

    var tension: Int {
        let healthGap = abs(pulseA.health - pulseB.health)
        let oddsGap = abs((match.playerA.odds ?? 2.0) - (match.playerB.odds ?? 2.0))
        let scoreBoost = match.state == .live ? 1 : 0
        return min(5, max(1, 5 - healthGap - Int(oddsGap.rounded()) + scoreBoost))
    }
}

// MARK: - Store

@MainActor
final class RadarStore: ObservableObject {
    @Published var matches: [RadarMatch] = []
    @Published var selectedID: String?
    @Published var radar: MatchRadar?
    @Published var isLoading = false
    @Published var status = "Redo."

    private let oddset = OddsetClient()
    private let database = ATPDatabase(settings: SettingsStore.loadDatabaseSettings())
    private var radarCache: [String: MatchRadar] = [:]

    var selectedMatch: RadarMatch? {
        matches.first { $0.id == selectedID } ?? matches.first
    }

    func refresh() {
        Task {
            await load()
        }
    }

    func select(_ match: RadarMatch) {
        guard selectedID != match.id else { return }
        selectedID = match.id
        Task {
            await loadRadar(for: match)
        }
    }

    private func load() async {
        isLoading = true
        status = "Läser tennisradar..."

        do {
            let loadedMatches = try await oddset.loadMatches()
            if loadedMatches != matches {
                matches = loadedMatches
            }
            if selectedID == nil || !matches.contains(where: { $0.id == selectedID }) {
                selectedID = matches.first?.id
            }
            status = "Laddade \(matches.filter { $0.state == .live }.count) live och \(matches.filter { $0.state == .upcoming }.count) kommande."
            if let selectedMatch {
                await loadRadar(for: selectedMatch)
            }
        } catch {
            status = error.localizedDescription
        }

        isLoading = false
    }

    private func loadRadar(for match: RadarMatch) async {
        if let current = radar, current.match.id == match.id {
            let refreshedShell = MatchRadar(match: match, playerA: current.playerA, playerB: current.playerB, modelA: current.modelA)
            if refreshedShell != current {
                radar = refreshedShell
                radarCache[match.id] = refreshedShell
            }
        } else if let cached = radarCache[match.id] {
            let refreshedShell = MatchRadar(match: match, playerA: cached.playerA, playerB: cached.playerB, modelA: cached.modelA)
            radar = refreshedShell
            radarCache[match.id] = refreshedShell
        } else {
            radar = MatchRadar(match: match, playerA: nil, playerB: nil, modelA: nil)
        }

        do {
            let loaded = try await database.loadRadar(match: match)
            guard selectedID == match.id else { return }
            radarCache[match.id] = loaded
            if radar != loaded {
                radar = loaded
            }
            if loaded.playerA == nil || loaded.playerB == nil {
                let missing = [
                    loaded.playerA == nil ? match.playerA.name : nil,
                    loaded.playerB == nil ? match.playerB.name : nil
                ]
                .compactMap { $0 }
                .joined(separator: ", ")
                status = "Oddset OK. ATP-träff saknas för \(missing)."
            } else {
                status = "Oddset och ATP-signaler laddade."
            }
        } catch {
            status = "ATP-signaler saknas: \(error.localizedDescription)"
        }
    }
}

// MARK: - App UI

struct RadarView: View {
    @StateObject private var store = RadarStore()
    @State private var filter: MatchState?
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Match Point GPT")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("Tennis Radar")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .textCase(.uppercase)
                    .tracking(1.4)
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 22)
            .frame(height: 66)
            .background(Theme.chrome)

            HStack(spacing: 14) {
                MatchFeed(matches: filteredMatches, selectedID: store.selectedID, filter: $filter, onSelect: store.select)
                    .frame(width: 390)

                if let radar = store.radar {
                    SituationRoom(radar: radar)
                } else if let match = store.selectedMatch {
                    SituationRoom(radar: MatchRadar(match: match, playerA: nil, playerB: nil, modelA: nil))
                } else {
                    EmptyRadar()
                }
            }
            .padding(14)

            HStack {
                Image(systemName: store.isLoading ? "dot.radiowaves.left.and.right" : "checkmark.circle")
                Text(store.status)
                Spacer()
                Text("\(store.matches.count) matcher")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 22)
            .frame(height: 34)
            .background(Theme.status)
        }
        .background(Theme.background)
        .onAppear { store.refresh() }
        .onReceive(timer) { _ in store.refresh() }
    }

    private var filteredMatches: [RadarMatch] {
        guard let filter else { return store.matches }
        return store.matches.filter { $0.state == filter }
    }
}

struct MatchFeed: View {
    let matches: [RadarMatch]
    let selectedID: String?
    @Binding var filter: MatchState?
    let onSelect: (RadarMatch) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Radarflöde", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
            }

            HStack(spacing: 8) {
                FilterChip(title: "Alla", isOn: filter == nil) { filter = nil }
                FilterChip(title: "Live", isOn: filter == .live) { filter = .live }
                FilterChip(title: "Kommande", isOn: filter == .upcoming) { filter = .upcoming }
            }

            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(matches) { match in
                        MatchCard(match: match, isSelected: selectedID == match.id) {
                            onSelect(match)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.border, lineWidth: 1)
        }
    }
}

struct FilterChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 13)
                .frame(height: 32)
                .background(isOn ? Theme.accentSoft : Color.clear)
                .foregroundStyle(isOn ? Theme.accent : Theme.muted)
                .clipShape(Capsule())
                .overlay {
                    Capsule().stroke(isOn ? Theme.accent : Theme.border, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

struct MatchCard: View {
    let match: RadarMatch
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(match.state.title)
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(match.state == .live ? Theme.liveSoft : Theme.accentSoft)
                        .foregroundStyle(match.state == .live ? Theme.live : Theme.accent)
                        .clipShape(Capsule())
                    Text(match.tournament ?? "Tennis")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                    Spacer()
                    Text(match.startTitle)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                }

                VStack(alignment: .leading, spacing: 5) {
                    playerLine(match.playerA, serving: match.serve == "playerA")
                    playerLine(match.playerB, serving: match.serve == "playerB")
                }

                if let score = match.score {
                    Text(score)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.live)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.selection : Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Theme.accent : Theme.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func playerLine(_ player: MatchPlayer, serving: Bool) -> some View {
        HStack(spacing: 7) {
            Text(player.country ?? "--")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .frame(width: 30, height: 22)
                .background(Theme.badge)
                .clipShape(Capsule())
            Text(player.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if let rank = player.rank {
                Text("#\(rank)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.muted)
            }
            if let odds = player.odds {
                Text(odds.formatted(.number.precision(.fractionLength(2))))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.muted)
            }
            if serving {
                Text("🎾")
            }
        }
    }
}

struct SituationRoom: View {
    let radar: MatchRadar

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MatchHeader(radar: radar)
                RadarBriefing(radar: radar)
                WatchAngles(radar: radar)
                HStack(alignment: .top, spacing: 14) {
                    PlayerRadarCard(player: radar.playerA, fallback: radar.match.playerA, pulse: radar.pulseA, model: radar.modelA)
                    PlayerRadarCard(player: radar.playerB, fallback: radar.match.playerB, pulse: radar.pulseB, model: radar.modelB)
                }
                ScoutNotes(radar: radar)
                HStack(alignment: .top, spacing: 14) {
                    SignalColumn(title: "Skrällar", matches: radar.pulseA.standoutWins + radar.pulseB.standoutWins, positive: true)
                    SignalColumn(title: "Varningsflaggor", matches: radar.pulseA.warningLosses + radar.pulseB.warningLosses, positive: false)
                }
            }
            .padding(18)
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.border, lineWidth: 1)
        }
    }
}

struct RadarBriefing: View {
    let radar: MatchRadar

    var body: some View {
        HStack(spacing: 12) {
            BriefingTile(
                title: "Marknad",
                value: radar.favoriteName,
                detail: marketDetail,
                color: Theme.live,
                bars: radar.marketPulse
            )
            BriefingTile(
                title: "ATP-signal",
                value: "\(radar.atpCoverage)/2",
                detail: atpDetail,
                color: radar.atpCoverage == 2 ? Theme.accent : Theme.warning,
                bars: max(1, radar.atpCoverage * 2 + (radar.atpCoverage == 2 ? 1 : 0))
            )
            BriefingTile(
                title: "Modell",
                value: radar.modelFavorite,
                detail: modelDetail,
                color: Theme.warning,
                bars: modelBars
            )
        }
    }

    private var marketDetail: String {
        guard let spread = radar.marketSpread else { return "Oddsen saknas" }
        if spread < 0.35 { return "nära myntkast" }
        if spread < 0.85 { return "lätt lutning" }
        if spread < 1.70 { return "tydlig favorit" }
        return "hård marknadstro"
    }

    private var atpDetail: String {
        switch radar.atpCoverage {
        case 2:
            return "båda spelarna hittade"
        case 1:
            return "halv datatäckning"
        default:
            return "endast Oddset just nu"
        }
    }

    private var modelDetail: String {
        guard let model = radar.modelA else { return "väntar på databas" }
        return model.formatted(.percent.precision(.fractionLength(0))) + " / " + (1 - model).formatted(.percent.precision(.fractionLength(0)))
    }

    private var modelBars: Int {
        guard let model = radar.modelA else { return 1 }
        return min(5, max(1, Int((abs(model - 0.5) * 10).rounded()) + 1))
    }
}

struct BriefingTile: View {
    let title: String
    let value: String
    let detail: String
    let color: Color
    let bars: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .textCase(.uppercase)
                    .tracking(1.0)
                    .foregroundStyle(Theme.muted)
                Spacer()
                HealthBars(value: bars, color: color, compact: true)
            }

            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)

            Text(detail)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel2)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.border.opacity(0.75), lineWidth: 1)
        }
    }
}

struct WatchAngles: View {
    let radar: MatchRadar

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Att bevaka", systemImage: "scope")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(radar.match.state == .live ? "live radar" : "match preview")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .textCase(.uppercase)
                    .tracking(1.0)
                    .foregroundStyle(Theme.muted)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(angles) { angle in
                    WatchAngleCard(angle: angle)
                }
            }
        }
        .padding(16)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.border, lineWidth: 1)
        }
    }

    private var angles: [WatchAngle] {
        var result: [WatchAngle] = []

        if let market = radar.marketFavoriteSide, let model = radar.modelFavoriteSide {
            if market == model {
                result.append(.init(
                    id: "market-model-aligned",
                    icon: "checkmark.seal",
                    title: "Överens",
                    detail: "Marknad och modell pekar mot \(radar.playerLastName(side: market)). Ingen konflikt att jaga här.",
                    color: Theme.live
                ))
            } else {
                result.append(.init(
                    id: "market-model-split",
                    icon: "arrow.triangle.branch",
                    title: "Konflikt",
                    detail: "Marknaden gillar \(radar.playerLastName(side: market)), modellen lutar \(radar.playerLastName(side: model)). Undersök varför.",
                    color: Theme.warning
                ))
            }
        } else if let market = radar.marketFavoriteSide {
            result.append(.init(
                id: "market-only",
                icon: "chart.line.uptrend.xyaxis",
                title: "Prisbild",
                detail: "\(radar.playerLastName(side: market)) är marknadens ankare. Oddset är baseline tills mer data säger annat.",
                color: Theme.accent
            ))
        }

        if let side = radar.surfaceEdgeSide, let value = radar.surfaceEdgeValue {
            result.append(.init(
                id: "surface-edge",
                icon: "tennisball",
                title: "Underlagskant",
                detail: "\(radar.playerLastName(side: side)) har +\(value) i \(radar.match.surfaceGuess.lowercased())-ELO. Det är dagens taktiska signal.",
                color: Theme.warning
            ))
        }

        if let side = radar.healthEdgeSide {
            result.append(.init(
                id: "health-edge",
                icon: "bolt.heart",
                title: "Formpuls",
                detail: "\(radar.playerLastName(side: side)) ser friskare ut i senaste tolv. Motparten behöver bryta mönstret tidigt.",
                color: side == 0 ? Theme.accent : Theme.live
            ))
        } else if radar.atpCoverage == 2 {
            result.append(.init(
                id: "health-even",
                icon: "equal.square",
                title: "Jämn puls",
                detail: "Formen skiljer inte mycket. Då blir serve, första set och oddsreaktion viktigare.",
                color: Theme.muted
            ))
        }

        let warningCount = radar.pulseA.warningLosses.count + radar.pulseB.warningLosses.count
        if warningCount > 0 {
            result.append(.init(
                id: "warning-losses",
                icon: "exclamationmark.triangle",
                title: "Varningsflaggor",
                detail: "\(warningCount) färska tapp mot lägre rankat motstånd. Stabiliteten är inte gratis.",
                color: Theme.danger
            ))
        }

        let upsetCount = radar.pulseA.standoutWins.count + radar.pulseB.standoutWins.count
        if upsetCount > 0 {
            result.append(.init(
                id: "upset-wins",
                icon: "sparkles",
                title: "Skrällminne",
                detail: "\(upsetCount) färska vinster uppåt i ranking. Någon här vet hur man slår bättre papper.",
                color: Theme.live
            ))
        }

        if result.isEmpty {
            result.append(.init(
                id: "no-data",
                icon: "magnifyingglass",
                title: "Datatyst",
                detail: "Oddset finns, men ATP-signalen är tunn. Bevaka prisrörelse och starttempo först.",
                color: Theme.accent
            ))
        }

        return Array(result.prefix(4))
    }
}

struct WatchAngle: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let color: Color
}

struct WatchAngleCard: View {
    let angle: WatchAngle

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: angle.icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(angle.color)
                .frame(width: 24, height: 24)
                .background(angle.color.opacity(0.13))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(angle.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(angle.detail)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .background(Theme.panel2)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.border.opacity(0.65), lineWidth: 1)
        }
    }
}

struct MatchHeader: View {
    let radar: MatchRadar

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(radar.match.state.title)
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(radar.match.state == .live ? Theme.liveSoft : Theme.accentSoft)
                    .foregroundStyle(radar.match.state == .live ? Theme.live : Theme.accent)
                    .clipShape(Capsule())
                Text(radar.match.tournament ?? "Tennis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.muted)
                    .textCase(.uppercase)
                Spacer()
                Text(radar.match.startTitle)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.muted)
            }

            Text(radar.match.matchupTitle)
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)

            HStack(spacing: 12) {
                Meter(title: "Spänning", value: radar.tension, color: Theme.accent)
                Meter(title: "Favorit", text: radar.favoriteName, color: Theme.live)
                Meter(title: "Underlag", text: radar.match.surfaceGuess, color: Theme.warning)
            }
        }
        .padding(16)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.border, lineWidth: 1)
        }
    }
}

struct PlayerRadarCard: View {
    let player: PlayerStats?
    let fallback: MatchPlayer
    let pulse: PlayerPulse
    let model: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Headshot(url: player?.imageURL, name: player?.name ?? fallback.name)
                    .frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 5) {
                    Text(player?.name ?? fallback.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text([player?.country ?? fallback.country, (player?.rank ?? fallback.rank).map { "#\($0)" }, player?.elo.map { "ELO \($0)" }]
                        .compactMap { $0 }
                        .joined(separator: "  "))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(pulse.title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text("\(pulse.formRecord) senaste 12")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                HealthBars(value: pulse.health)
            }

            Text(pulse.note)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .lineLimit(2)

            HStack(spacing: 8) {
                MiniFact(title: "Oddset", value: fallback.odds.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "-")
                MiniFact(title: "Modell", value: model.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "-")
                MiniFact(title: "Yta", value: player?.surfaceElo.map(String.init) ?? "-")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.border, lineWidth: 1)
        }
    }
}

struct ScoutNotes: View {
    let radar: MatchRadar

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Scout-notes", systemImage: "sparkles")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.text)

            VStack(alignment: .leading, spacing: 9) {
                note(marketNote)
                note(formNote)
                if radar.match.state == .live, let score = radar.match.score {
                    note("Live nu: \(score). Följ serve och prisrörelse innan du litar på en enda datapunkt.")
                } else if radar.modelA == nil {
                    note("Modellen väntar på ATP-träff. Just nu är detta en marknadsradar, inte en full scout.")
                } else {
                    note("Modellen och marknaden kan jämföras här: när de inte håller med finns ofta det roliga.")
                }
            }
        }
        .padding(16)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.border, lineWidth: 1)
        }
    }

    private var strongerPulseName: String {
        radar.pulseA.health >= radar.pulseB.health ? radar.match.playerA.lastName : radar.match.playerB.lastName
    }

    private var marketNote: String {
        guard let spread = radar.marketSpread else {
            return "Marknaden har ännu ingen tydlig prissignal."
        }
        if spread < 0.35 {
            return "Marknaden ser detta som jämnt. Leta efter form eller underlag som bryter dödläget."
        }
        return "Marknaden lutar mot \(radar.favoriteName). Frågan är om ATP-signalen håller med."
    }

    private var formNote: String {
        let gap = abs(radar.pulseA.health - radar.pulseB.health)
        if radar.atpCoverage < 2 {
            return "Formmätaren är försiktig tills båda spelarna hittas i databasen."
        }
        if gap == 0 {
            return "Formbilden är symmetrisk. Då blir odds, underlag och matchup viktigare."
        }
        return "\(strongerPulseName) har bäst färsk puls med \(gap) steg i health-gap."
    }

    private func note(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 7, height: 7)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
        }
    }
}

struct SignalColumn: View {
    let title: String
    let matches: [HistoricalMatch]
    let positive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .textCase(.uppercase)
                .tracking(1.0)
                .foregroundStyle(Theme.muted)

            if matches.isEmpty {
                Text(positive ? "Inga tydliga skrällar." : "Inga tydliga tapp.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            } else {
                ForEach(Array(matches.prefix(4))) { match in
                    HStack(spacing: 10) {
                        Text(positive ? "▲" : "▼")
                            .foregroundStyle(positive ? Theme.live : Theme.danger)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(match.winner) - \(match.loser)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Text("\(match.date) · \(match.tournament)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(match.score ?? "-")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(10)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.panel2)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.border, lineWidth: 1)
        }
    }
}

struct EmptyRadar: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "scope")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text("Ingen match vald")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct Meter: View {
    let title: String
    var value: Int?
    var text: String?
    let color: Color

    init(title: String, value: Int, color: Color) {
        self.title = title
        self.value = value
        self.text = nil
        self.color = color
    }

    init(title: String, text: String, color: Color) {
        self.title = title
        self.value = nil
        self.text = text
        self.color = color
    }

    var body: some View {
        HStack(spacing: 9) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.9)
                .foregroundStyle(Theme.muted)
            if let value {
                HealthBars(value: value, color: color, compact: true)
            } else {
                Text(text ?? "-")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Theme.panel2)
        .clipShape(Capsule())
    }
}

struct HealthBars: View {
    let value: Int
    var color: Color = Theme.live
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 3 : 5) {
            ForEach(1...5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(index <= value ? colorForValue : Theme.border)
                    .frame(width: compact ? 14 : 26, height: compact ? 9 : 14)
            }
        }
    }

    private var colorForValue: Color {
        if color != Theme.live { return color }
        switch value {
        case 4...5:
            return Theme.live
        case 3:
            return Theme.warning
        default:
            return Theme.danger
        }
    }
}

struct MiniFact: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(Theme.panel2)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct Headshot: View {
    let url: URL?
    let name: String

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                Text(initials)
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(Theme.muted)
            }
        }
        .background(Theme.panel2)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(Theme.border, lineWidth: 1)
        }
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}

enum Theme {
    static let background = Color(red: 0.035, green: 0.052, blue: 0.075)
    static let chrome = Color(red: 0.052, green: 0.075, blue: 0.105)
    static let status = Color(red: 0.058, green: 0.089, blue: 0.110)
    static let panel = Color(red: 0.070, green: 0.105, blue: 0.145)
    static let panel2 = Color(red: 0.055, green: 0.085, blue: 0.120)
    static let card = Color(red: 0.080, green: 0.120, blue: 0.165)
    static let selection = Color(red: 0.050, green: 0.190, blue: 0.215)
    static let border = Color(red: 0.160, green: 0.330, blue: 0.430)
    static let text = Color(red: 0.930, green: 0.960, blue: 0.955)
    static let muted = Color(red: 0.640, green: 0.700, blue: 0.720)
    static let accent = Color(red: 0.340, green: 0.800, blue: 0.950)
    static let accentSoft = Color(red: 0.065, green: 0.210, blue: 0.270)
    static let live = Color(red: 0.390, green: 0.940, blue: 0.640)
    static let liveSoft = Color(red: 0.055, green: 0.230, blue: 0.160)
    static let warning = Color(red: 1.0, green: 0.760, blue: 0.250)
    static let danger = Color(red: 1.0, green: 0.360, blue: 0.320)
    static let badge = Color(red: 0.110, green: 0.160, blue: 0.200)
}

// MARK: - Oddset

struct OddsetClient {
    private let atpURL = URL(string: "https://eu1.offering-api.kambicdn.com/offering/v2018/svenskaspel/listView/tennis/atp/all/all/matches.json")!
    private let tennisURL = URL(string: "https://eu1.offering-api.kambicdn.com/offering/v2018/svenskaspel/listView/tennis/all/all/all/matches.json")!
    private let liveOpenURL = URL(string: "https://eu1.offering-api.kambicdn.com/offering/v2018/svenskaspel/event/live/open.json")!

    func loadMatches() async throws -> [RadarMatch] {
        async let atp = loadSource(label: "tennis-atp", url: atpURL)
        async let live = loadSource(label: "tennis-live-open", url: liveOpenURL)
        async let all = loadSource(label: "tennis-all", url: tennisURL)

        let sources = await [atp, live, all]
        let matches = sources.flatMap { source in
            source.events
                .filter(isRelevantTennisEvent)
                .compactMap { normalize($0, source: source.label) }
        }

        if matches.isEmpty, let error = sources.compactMap(\.error).first {
            throw error
        }

        return dedupe(matches)
    }

    private func loadSource(label: String, url: URL) async -> OddsetSourceResult {
        do {
            let (data, response) = try await URLSession.shared.data(from: buildKambiURL(url))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw OddsetClientError.http(label, http.statusCode)
            }

            let payload = try JSONDecoder().decode(KambiResponse.self, from: data)
            return OddsetSourceResult(label: label, events: payload.allEvents, error: nil)
        } catch {
            return OddsetSourceResult(label: label, events: [], error: error)
        }
    }

    private func buildKambiURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var queryItems = components.queryItems ?? []
        setQueryItem("channel_id", "1", in: &queryItems)
        setQueryItem("client_id", "200", in: &queryItems)
        setQueryItem("lang", "sv_SE", in: &queryItems)
        setQueryItem("market", "SE", in: &queryItems)

        if url.path.contains("/listView/") {
            setQueryItem("useCombined", "true", in: &queryItems)
            setQueryItem("useCombinedLive", "true", in: &queryItems)
        }

        components.queryItems = queryItems
        return components.url ?? url
    }

    private func setQueryItem(_ name: String, _ value: String, in queryItems: inout [URLQueryItem]) {
        queryItems.removeAll { $0.name == name }
        queryItems.append(URLQueryItem(name: name, value: value))
    }

    private func isRelevantTennisEvent(_ item: KambiEventItem) -> Bool {
        guard item.event.sport == "TENNIS", ["STARTED", "NOT_STARTED"].contains(item.event.state) else {
            return false
        }

        let path = item.event.path ?? []
        let terms = path.flatMap { [$0.termKey, $0.name, $0.englishName] }
            .map(normalizeToken)
            .filter { !$0.isEmpty }
        let searchText = ([item.event.name, item.event.group] + path.flatMap { [$0.name, $0.englishName, $0.termKey] })
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        let excludedTerms: Set<String> = ["wta", "challenger", "challenger_qual_", "utr_pro_tennis_series", "utr_pro_tennis_series_women"]

        if terms.contains(where: { excludedTerms.contains($0) || $0.contains("qual") || $0.contains("kval") }) {
            return false
        }

        if searchText.range(of: #"(^|[\s-])(damer|damsingel|damdubbel|women|womens|ladies|dubbel|doubles|kval|qual|qualification|qualifier)([\s-]|$)"#, options: .regularExpression) != nil {
            return false
        }

        return terms.contains("atp") || terms.contains("grand_slam")
    }

    private func normalize(_ item: KambiEventItem, source: String) -> RadarMatch? {
        guard let id = item.event.id, let homeName = item.event.homeName, let awayName = item.event.awayName else {
            return nil
        }

        let outcomes = primaryMarket(item)?.outcomes ?? []
        let playerAOutcome = findOutcome(outcomes, type: "OT_ONE", fallbackIndex: 0)
        let playerBOutcome = findOutcome(outcomes, type: "OT_TWO", fallbackIndex: 1)
        let state: MatchState = item.event.state == "STARTED" ? .live : .upcoming

        return RadarMatch(
            id: String(id),
            start: item.event.start.flatMap(Self.parseDate),
            tournament: item.event.group,
            state: state,
            score: state == .live ? buildScore(item) : nil,
            serve: item.liveData?.statistics?.sets?.homeServe == true ? "playerA" : (item.liveData == nil ? nil : "playerB"),
            playerA: MatchPlayer(id: item.event.home.map(String.init), name: homeName, country: nil, rank: nil, odds: decimalOdds(playerAOutcome)),
            playerB: MatchPlayer(id: item.event.away.map(String.init), name: awayName, country: nil, rank: nil, odds: decimalOdds(playerBOutcome)),
            source: source
        )
    }

    private func primaryMarket(_ item: KambiEventItem) -> KambiBetOffer? {
        item.betOffers?.first {
            $0.criterion?.label == "Matchodds" || $0.criterion?.englishLabel == "Match Odds"
        } ?? item.mainBetOffer
    }

    private func findOutcome(_ outcomes: [KambiOutcome], type: String, fallbackIndex: Int) -> KambiOutcome? {
        outcomes.first { $0.type == type } ?? (outcomes.indices.contains(fallbackIndex) ? outcomes[fallbackIndex] : nil)
    }

    private func decimalOdds(_ outcome: KambiOutcome?) -> Double? {
        guard let odds = outcome?.odds else { return nil }
        return Double(odds) / 1000
    }

    private func buildScore(_ item: KambiEventItem) -> String? {
        guard let liveData = item.liveData else { return nil }
        let homeSets = liveData.statistics?.sets?.home ?? []
        let awaySets = liveData.statistics?.sets?.away ?? []
        let setScores = zipLongest(homeSets, awaySets).compactMap { home, away -> String? in
            guard let home, let away, home >= 0, away >= 0, !(home == 0 && away == 0) else { return nil }
            return "\(home)-\(away)"
        }
        let gameScore = liveData.score.flatMap { score -> String? in
            guard let home = score.home, let away = score.away else { return nil }
            return "\(home)-\(away)"
        }
        let score = setScores.joined(separator: " ")
        if let gameScore {
            return score.isEmpty ? "[\(gameScore)]" : "\(score) [\(gameScore)]"
        }
        return score.isEmpty ? nil : score
    }

    private func zipLongest(_ lhs: [Int], _ rhs: [Int]) -> [(Int?, Int?)] {
        (0..<max(lhs.count, rhs.count)).map { index in
            (lhs.indices.contains(index) ? lhs[index] : nil, rhs.indices.contains(index) ? rhs[index] : nil)
        }
    }

    private func dedupe(_ matches: [RadarMatch]) -> [RadarMatch] {
        let byID = Dictionary(matches.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        return byID.values.sorted {
            ($0.state == .live ? 0 : 1, $0.start ?? .distantFuture, $0.matchupTitle) <
            ($1.state == .live ? 0 : 1, $1.start ?? .distantFuture, $1.matchupTitle)
        }
    }

    private func normalizeToken(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
    }

    private static func parseDate(_ value: String) -> Date? {
        isoDateFormatterWithFractions.date(from: value) ?? isoDateFormatter.date(from: value)
    }

    private static let isoDateFormatterWithFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoDateFormatter = ISO8601DateFormatter()
}

private struct OddsetSourceResult {
    let label: String
    let events: [KambiEventItem]
    let error: Error?
}

private enum OddsetClientError: LocalizedError {
    case http(String, Int)

    var errorDescription: String? {
        switch self {
        case .http(let label, let statusCode):
            return "Oddset \(label) svarade med HTTP \(statusCode)."
        }
    }
}

private struct KambiResponse: Decodable {
    let events: [KambiEventItem]?
    let liveEvents: [KambiEventItem]?
    var allEvents: [KambiEventItem] { (events ?? []) + (liveEvents ?? []) }
}

private struct KambiEventItem: Decodable {
    let event: KambiEvent
    let liveData: KambiLiveData?
    let betOffers: [KambiBetOffer]?
    let mainBetOffer: KambiBetOffer?
}

private struct KambiEvent: Decodable {
    let id: Int?
    let sport: String?
    let name: String?
    let home: Int?
    let homeName: String?
    let away: Int?
    let awayName: String?
    let start: String?
    let group: String?
    let state: String?
    let path: [KambiPathTerm]?
}

private struct KambiPathTerm: Decodable {
    let termKey: String?
    let name: String?
    let englishName: String?
}

private struct KambiLiveData: Decodable {
    let score: KambiScore?
    let statistics: KambiStatistics?
}

private struct KambiScore: Decodable {
    let home: String?
    let away: String?
}

private struct KambiStatistics: Decodable {
    let sets: KambiSets?
}

private struct KambiSets: Decodable {
    let home: [Int]?
    let away: [Int]?
    let homeServe: Bool?
}

private struct KambiBetOffer: Decodable {
    let criterion: KambiCriterion?
    let outcomes: [KambiOutcome]?
}

private struct KambiCriterion: Decodable {
    let label: String?
    let englishLabel: String?
}

private struct KambiOutcome: Decodable {
    let type: String?
    let odds: Int?
}

// MARK: - ATP database

enum ATPDatabaseError: LocalizedError {
    case invalidHost

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "Ogiltig databashost eller port."
        }
    }
}

struct ATPDatabase {
    let settings: DatabaseSettings

    func loadRadar(match: RadarMatch) async throws -> MatchRadar {
        try await withConnection { connection in
            let refA = try await resolvePlayer(match.playerA.name, on: connection)
            let refB = try await resolvePlayer(match.playerB.name, on: connection)
            let playerA: PlayerStats?
            if let refA {
                playerA = try await loadPlayer(ref: refA, surface: match.surfaceGuess, on: connection)
            } else {
                playerA = nil
            }
            let playerB: PlayerStats?
            if let refB {
                playerB = try await loadPlayer(ref: refB, surface: match.surfaceGuess, on: connection)
            } else {
                playerB = nil
            }
            let model = try? await loadModel(playerA: refA, playerB: refB, surface: match.surfaceGuess, on: connection)
            return MatchRadar(match: match, playerA: playerA, playerB: playerB, modelA: model)
        }
    }

    private func loadPlayer(ref: PlayerRef, surface: String, on connection: MySQLConnection) async throws -> PlayerStats? {
        let rows = try await connection.query(
            """
            SELECT
                id,
                name,
                country,
                rank,
                points,
                elo_rank,
                CASE
                    WHEN ? = 'Clay' THEN elo_rank_clay
                    WHEN ? = 'Grass' THEN elo_rank_grass
                    ELSE elo_rank_hard
                END AS surface_elo
            FROM players
            WHERE id = ?
            LIMIT 1
            """,
            [
                MySQLData(string: surface),
                MySQLData(string: surface),
                MySQLData(string: ref.id)
            ]
        ).get()

        guard let row = rows.first, let id = row.string("id"), let resolvedName = row.string("name") else {
            return nil
        }

        let recent = try await loadRecentMatches(playerID: id, playerName: resolvedName, on: connection)
        return PlayerStats(
            id: id,
            name: resolvedName,
            country: row.string("country"),
            rank: row.int("rank"),
            points: row.int("points"),
            elo: row.int("elo_rank"),
            surfaceElo: row.int("surface_elo"),
            recentMatches: recent
        )
    }

    private func resolvePlayer(_ name: String, on connection: MySQLConnection) async throws -> PlayerRef? {
        let parts = name.split(separator: " ").map(String.init)
        let first = parts.first ?? name
        let last = parts.last ?? name
        let firstLike = "%\(first)%"
        let lastLike = "%\(last)%"
        let lastOnlyLike = "%\(last)%"

        let rows = try await connection.query(
            """
            SELECT id, name
            FROM players
            WHERE id = PLAYER_LOOKUP(?)
               OR LOWER(name) = LOWER(?)
               OR (LOWER(name) LIKE LOWER(?) AND LOWER(name) LIKE LOWER(?))
               OR LOWER(name) LIKE LOWER(?)
            ORDER BY
                CASE
                    WHEN id = PLAYER_LOOKUP(?) THEN 0
                    WHEN LOWER(name) = LOWER(?) THEN 1
                    WHEN (LOWER(name) LIKE LOWER(?) AND LOWER(name) LIKE LOWER(?)) THEN 2
                    ELSE 3
                END,
                CASE WHEN rank IS NULL THEN 1 ELSE 0 END,
                rank ASC,
                name ASC
            LIMIT 1
            """,
            [
                MySQLData(string: name),
                MySQLData(string: name),
                MySQLData(string: firstLike),
                MySQLData(string: lastLike),
                MySQLData(string: lastOnlyLike),
                MySQLData(string: name),
                MySQLData(string: name),
                MySQLData(string: firstLike),
                MySQLData(string: lastLike)
            ]
        ).get()

        guard let row = rows.first, let id = row.string("id"), let resolvedName = row.string("name") else {
            return nil
        }

        return PlayerRef(id: id, name: resolvedName)
    }

    private func loadRecentMatches(playerID: String, playerName _: String, on connection: MySQLConnection) async throws -> [HistoricalMatch] {
        let rows = try await connection.query(
            """
            SELECT
                m.id,
                DATE_FORMAT(e.date, '%Y-%m-%d') AS event_date,
                e.name AS event_name,
                e.surface,
                winner.name AS winner_name,
                loser.name AS loser_name,
                m.winner_rank,
                m.loser_rank,
                m.score
            FROM matches m
            JOIN events e ON e.id = m.event
            JOIN players winner ON winner.id = m.winner
            JOIN players loser ON loser.id = m.loser
            WHERE e.date IS NOT NULL
              AND m.winner IS NOT NULL
              AND m.loser IS NOT NULL
              AND (m.winner = ? OR m.loser = ?)
              AND LOWER(e.name) NOT LIKE '%challenger%'
            ORDER BY e.date DESC, e.id DESC, m.id DESC
            LIMIT 80
            """,
            [
                MySQLData(string: playerID),
                MySQLData(string: playerID)
            ]
        ).get()

        return rows.compactMap { row in
            guard
                let id = row.string("id"),
                let date = row.string("event_date"),
                let event = row.string("event_name"),
                let winner = row.string("winner_name"),
                let loser = row.string("loser_name")
            else {
                return nil
            }

            return HistoricalMatch(
                id: id,
                date: date,
                tournament: event,
                surface: row.string("surface"),
                winner: winner,
                loser: loser,
                winnerRank: row.int("winner_rank"),
                loserRank: row.int("loser_rank"),
                score: row.string("score")
            )
        }
    }

    private func loadModel(playerA: PlayerRef?, playerB: PlayerRef?, surface: String, on connection: MySQLConnection) async throws -> Double? {
        guard let playerA, let playerB else { return nil }

        let rows = try await connection.query(
            """
            SELECT PLAYER_WIN_FACTOR(?, ?, ?) AS win_factor_a
            """,
            [
                MySQLData(string: playerA.id),
                MySQLData(string: playerB.id),
                MySQLData(string: surface)
            ]
        ).get()

        guard let value = rows.first?.double("win_factor_a"), value > 0, value < 1 else {
            return nil
        }
        return value
    }

    private func withConnection<T>(_ work: (MySQLConnection) async throws -> T) async throws -> T {
        guard let socketAddress = try? SocketAddress.makeAddressResolvingHost(settings.host, port: settings.port) else {
            throw ATPDatabaseError.invalidHost
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connection = try await MySQLConnection.connect(
            to: socketAddress,
            username: settings.user,
            database: settings.database,
            password: settings.password.isEmpty ? nil : settings.password,
            tlsConfiguration: nil,
            on: group.next()
        ).get()

        do {
            let result = try await work(connection)
            try await connection.close().get()
            try await group.shutdownGracefully()
            return result
        } catch {
            try? await connection.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }
}

private struct PlayerRef {
    let id: String
    let name: String
}

private extension MySQLRow {
    func string(_ column: String) -> String? {
        self.column(column)?.string
    }

    func int(_ column: String) -> Int? {
        self.column(column)?.int
    }

    func double(_ column: String) -> Double? {
        self.column(column)?.double
    }
}
