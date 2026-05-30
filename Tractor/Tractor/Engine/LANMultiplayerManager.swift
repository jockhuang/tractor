import Foundation
import MultipeerConnectivity
import UIKit

enum LANMode: Equatable {
    case none
    case host
    case client
}

struct LANLobbyEntry: Codable, Identifiable {
    let id: String
    let name: String
    var position: PlayerPosition?
    let isHost: Bool
}

struct LANLobbyState: Codable {
    var players: [LANLobbyEntry]
}

struct NetworkPlayerSnapshot: Codable {
    let position: PlayerPosition
    let hand: [Card]
    let handCount: Int
    let isDealer: Bool
}

struct NetworkPlaySnapshot: Codable {
    let position: PlayerPosition
    let cards: [Card]
}

struct NetworkTrickSnapshot: Codable {
    let leadPosition: PlayerPosition
    let plays: [NetworkPlaySnapshot]
}

struct GameSnapshot: Codable {
    let localPosition: PlayerPosition
    let playerNames: [PlayerPosition: String]
    let phase: GamePhase
    let trumpSuit: Suit?
    let trumpRank: Rank
    let trumpDeclaration: TrumpDeclaration?
    let dealtCount: Int
    let isDealingFast: Bool
    let isResolvingTrick: Bool
    let dealerPosition: PlayerPosition
    let currentTrick: NetworkTrickSnapshot
    let currentLeader: PlayerPosition
    let currentTurn: PlayerPosition
    let attackScore: Int
    let teamLevels: [Int: Rank]
    let dealerTeamIdx: Int
    let message: String
    let lastRoundResult: RoundResult?
    let players: [NetworkPlayerSnapshot]
}

enum MultiplayerActionKind: Codable {
    case declareTrump(selectedCardIDs: [UUID])
    case confirmKitty(selectedCardIDs: [UUID])
    case play(selectedCardIDs: [UUID])
}

struct MultiplayerAction: Codable {
    let position: PlayerPosition
    let kind: MultiplayerActionKind
}

enum LANMessage: Codable {
    case lobby(LANLobbyState)
    case snapshot(GameSnapshot)
    case action(MultiplayerAction)
    case roomClosed
}

final class LANMultiplayerManager: NSObject, ObservableObject {
    private let serviceType = "tractor-game"
    private let playerNameKey = "tractor.multiplayer.playerName"

    @Published var localPlayerName: String
    @Published var mode: LANMode = .none
    @Published var discoveredHosts: [MCPeerID] = []
    @Published var lobby = LANLobbyState(players: [])
    @Published var statusText = ""

    private var peerID: MCPeerID
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private weak var engine: GameEngine?
    private var positionByPeerID: [ObjectIdentifier: PlayerPosition] = [:]
    private var connectedPeers: [MCPeerID] = []

    var isHost: Bool { mode == .host }
    var isClient: Bool { mode == .client }
    var hasRemotePlayers: Bool {
        isClient || !connectedRoomPeers().isEmpty || lobby.players.contains { !$0.isHost }
    }

    override init() {
        let savedName = UserDefaults.standard.string(forKey: playerNameKey)
        let initialName = Self.normalizedPlayerName(savedName ?? UIDevice.current.name)
        self.localPlayerName = initialName
        self.peerID = MCPeerID(displayName: initialName)
        super.init()
    }

    func attach(engine: GameEngine) {
        self.engine = engine
    }

    func commitLocalPlayerName() {
        applyLocalPlayerName()
    }

    func hostGame() {
        applyLocalPlayerName()
        resetConnections()
        mode = .host
        statusText = "正在等待其他玩家加入"
        startSession()

        advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: ["name": peerID.displayName],
            serviceType: serviceType
        )
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
        refreshHostLobby()
    }

    func browseGames() {
        applyLocalPlayerName()
        resetConnections()
        mode = .client
        statusText = "正在搜索局域网房间"
        startSession()

        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
    }

    func join(_ host: MCPeerID) {
        guard let session else { return }
        statusText = "正在加入 \(host.displayName)"
        browser?.invitePeer(host, to: session, withContext: nil, timeout: 12)
    }

    func leave() {
        if mode == .host {
            send(.roomClosed, to: connectedRoomPeers())
        }
        resetConnections()
        mode = .none
        lobby = LANLobbyState(players: [])
        discoveredHosts = []
        positionByPeerID = [:]
        connectedPeers = []
        statusText = ""
    }

    @MainActor
    func startHostedGame() {
        guard mode == .host, let engine else { return }

        let remotePeers = lobbyPeers()
        let humanPeers = [peerID] + remotePeers
        let positions: [PlayerPosition]
        if humanPeers.count == 1 {
            positions = [.south]
        } else {
            positions = Array(PlayerPosition.allCases.shuffled().prefix(humanPeers.count))
        }
        positionByPeerID = [:]
        for (peer, position) in zip(humanPeers, positions) {
            positionByPeerID[peerObjectID(peer)] = position
        }

        refreshHostLobby()
        broadcastLobby()

        let humanPositions = Set(humanPeers.compactMap { position(for: $0) })
        let hostPosition = position(for: peerID) ?? .south
        var playerNames: [PlayerPosition: String] = [:]
        for peer in humanPeers {
            guard let position = position(for: peer) else { continue }
            playerNames[position] = peer.displayName
        }
        engine.startMultiplayerGame(
            localPosition: hostPosition,
            humanPositions: humanPositions,
            playerNames: playerNames
        )
        broadcastSnapshots()
    }

    func sendAction(_ action: MultiplayerAction) {
        send(.action(action), to: connectedRoomPeers())
    }

    @MainActor
    func broadcastSnapshots() {
        guard mode == .host, let engine else { return }

        for peer in connectedRoomPeers() {
            guard let position = position(for: peer) else { continue }
            send(.snapshot(engine.snapshot(for: position)), to: [peer])
        }
    }

    private func startSession() {
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session?.delegate = self
    }

    private func applyLocalPlayerName() {
        let normalized = Self.normalizedPlayerName(localPlayerName)
        localPlayerName = normalized
        UserDefaults.standard.set(normalized, forKey: playerNameKey)
        guard mode == .none else { return }
        peerID = MCPeerID(displayName: normalized)
    }

    private static func normalizedPlayerName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? (fallback.isEmpty ? "玩家" : fallback) : trimmed
        var result = ""
        for character in value {
            let candidate = result + String(character)
            guard candidate.utf8.count <= 48 else { break }
            result = candidate
        }
        return result.isEmpty ? "玩家" : result
    }

    private func resetConnections() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        connectedPeers = []
    }

    private func refreshHostLobby() {
        let remotePeers = lobbyPeers()
        var entries = [LANLobbyEntry(
            id: lobbyEntryID(for: peerID),
            name: peerID.displayName,
            position: position(for: peerID),
            isHost: true
        )]
        entries += remotePeers.map {
            LANLobbyEntry(
                id: lobbyEntryID(for: $0),
                name: $0.displayName,
                position: position(for: $0),
                isHost: false
            )
        }
        lobby = LANLobbyState(players: entries)
    }

    private func broadcastLobby() {
        send(.lobby(lobby), to: lobbyPeers())
    }

    private func lobbyPeers() -> [MCPeerID] {
        Array(connectedRoomPeers().prefix(3))
    }

    private func connectedRoomPeers() -> [MCPeerID] {
        var peers = connectedPeers
        for peer in session?.connectedPeers ?? [] where !containsPeer(peer, in: peers) {
            peers.append(peer)
        }
        return peers
    }

    private func updateConnectedPeer(_ peer: MCPeerID, state: MCSessionState) {
        switch state {
        case .connected:
            if !containsPeer(peer, in: connectedPeers) {
                connectedPeers.append(peer)
            }
        case .notConnected:
            connectedPeers.removeAll { $0 === peer }
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    private func position(for peer: MCPeerID) -> PlayerPosition? {
        positionByPeerID[peerObjectID(peer)]
    }

    private func peerObjectID(_ peer: MCPeerID) -> ObjectIdentifier {
        ObjectIdentifier(peer)
    }

    private func lobbyEntryID(for peer: MCPeerID) -> String {
        "\(peer.displayName)-\(peerObjectID(peer))"
    }

    private func containsPeer(_ peer: MCPeerID, in peers: [MCPeerID]) -> Bool {
        peers.contains { $0 === peer }
    }

    private func send(_ message: LANMessage, to peers: [MCPeerID]) {
        guard !peers.isEmpty, let session else { return }
        do {
            let data = try JSONEncoder().encode(message)
            try session.send(data, toPeers: peers, with: .reliable)
        } catch {
            statusText = "发送失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func handle(_ message: LANMessage, from peer: MCPeerID) {
        switch message {
        case .lobby(let lobby):
            self.lobby = lobby
            statusText = "已连接到房主 \(peer.displayName)"
        case .snapshot(let snapshot):
            engine?.apply(snapshot: snapshot)
        case .action(let action):
            guard mode == .host else { return }
            engine?.handleRemoteAction(action)
        case .roomClosed:
            returnToMenuAfterRoomClosed()
        }
    }

    @MainActor
    private func returnToMenuAfterRoomClosed() {
        resetConnections()
        mode = .none
        lobby = LANLobbyState(players: [])
        discoveredHosts = []
        positionByPeerID = [:]
        connectedPeers = []
        statusText = "房主已退出"
        engine?.returnToMenuFromMultiplayer()
    }
}

extension LANMultiplayerManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            self.updateConnectedPeer(peerID, state: state)

            if self.mode == .host {
                self.refreshHostLobby()
                switch state {
                case .connected:
                    self.statusText = "\(peerID.displayName) 已加入（\(self.lobby.players.count)/4）"
                case .connecting:
                    self.statusText = "连接中：\(peerID.displayName)"
                case .notConnected:
                    self.statusText = "\(peerID.displayName) 已离开（\(self.lobby.players.count)/4）"
                @unknown default:
                    self.statusText = "连接状态变化"
                }
                self.broadcastLobby()
            } else {
                switch state {
                case .connected:
                    self.statusText = "已连接：\(peerID.displayName)"
                case .connecting:
                    self.statusText = "连接中：\(peerID.displayName)"
                case .notConnected:
                    self.statusText = "已断开：\(peerID.displayName)"
                @unknown default:
                    self.statusText = "连接状态变化"
                }

                if self.mode == .client && state == .notConnected {
                    self.returnToMenuAfterRoomClosed()
                }
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            do {
                let message = try JSONDecoder().decode(LANMessage.self, from: data)
                self.handle(message, from: peerID)
            } catch {
                self.statusText = "接收失败：\(error.localizedDescription)"
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension LANMultiplayerManager: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            let canJoin = self.mode == .host && self.lobbyPeers().count < 3
            invitationHandler(canJoin, self.session)
        }
    }
}

extension LANMultiplayerManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        Task { @MainActor in
            guard !self.containsPeer(peerID, in: self.discoveredHosts) else { return }
            self.discoveredHosts.append(peerID)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.discoveredHosts.removeAll { $0 === peerID }
        }
    }
}
