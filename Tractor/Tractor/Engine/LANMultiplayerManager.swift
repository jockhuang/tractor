import Foundation
import MultipeerConnectivity
import UIKit

enum LANMode {
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
    let phase: GamePhase
    let trumpSuit: Suit?
    let trumpRank: Rank
    let trumpDeclaration: TrumpDeclaration?
    let dealtCount: Int
    let isDealingFast: Bool
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
}

final class LANMultiplayerManager: NSObject, ObservableObject {
    private let serviceType = "tractor-game"

    @Published var mode: LANMode = .none
    @Published var discoveredHosts: [MCPeerID] = []
    @Published var lobby = LANLobbyState(players: [])
    @Published var statusText = ""

    private let peerID = MCPeerID(displayName: UIDevice.current.name)
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private weak var engine: GameEngine?
    private var positionByPeerID: [String: PlayerPosition] = [:]

    var isHost: Bool { mode == .host }
    var isClient: Bool { mode == .client }

    func attach(engine: GameEngine) {
        self.engine = engine
    }

    func hostGame() {
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
        resetConnections()
        mode = .none
        lobby = LANLobbyState(players: [])
        discoveredHosts = []
        positionByPeerID = [:]
        statusText = ""
    }

    @MainActor
    func startHostedGame() {
        guard mode == .host, let engine else { return }

        let remotePeers = Array(session?.connectedPeers.prefix(3) ?? [])
        let humanIDs = [peerID.displayName] + remotePeers.map(\.displayName)
        let positions: [PlayerPosition]
        if humanIDs.count == 1 {
            positions = [.south]
        } else {
            positions = Array(PlayerPosition.allCases.shuffled().prefix(humanIDs.count))
        }
        positionByPeerID = Dictionary(uniqueKeysWithValues: zip(humanIDs, positions))

        refreshHostLobby()
        broadcastLobby()

        let humanPositions = Set(humanIDs.compactMap { positionByPeerID[$0] })
        let hostPosition = positionByPeerID[peerID.displayName] ?? .south
        engine.startMultiplayerGame(localPosition: hostPosition, humanPositions: humanPositions)
        broadcastSnapshots()
    }

    func sendAction(_ action: MultiplayerAction) {
        send(.action(action), to: session?.connectedPeers ?? [])
    }

    @MainActor
    func broadcastSnapshots() {
        guard mode == .host, let engine, let session else { return }

        for peer in session.connectedPeers {
            guard let position = positionByPeerID[peer.displayName] else { continue }
            send(.snapshot(engine.snapshot(for: position)), to: [peer])
        }
    }

    private func startSession() {
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session?.delegate = self
    }

    private func resetConnections() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
    }

    private func refreshHostLobby() {
        let remotePeers = Array(session?.connectedPeers.prefix(3) ?? [])
        var entries = [LANLobbyEntry(
            id: peerID.displayName,
            name: peerID.displayName,
            position: positionByPeerID[peerID.displayName],
            isHost: true
        )]
        entries += remotePeers.map {
            LANLobbyEntry(
                id: $0.displayName,
                name: $0.displayName,
                position: positionByPeerID[$0.displayName],
                isHost: false
            )
        }
        lobby = LANLobbyState(players: entries)
    }

    private func broadcastLobby() {
        send(.lobby(lobby), to: session?.connectedPeers ?? [])
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
        }
    }
}

extension LANMultiplayerManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
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

            if self.mode == .host {
                self.refreshHostLobby()
                self.broadcastLobby()
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
        let canJoin = mode == .host && (session?.connectedPeers.count ?? 0) < 3
        invitationHandler(canJoin, session)
    }
}

extension LANMultiplayerManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        Task { @MainActor in
            guard !self.discoveredHosts.contains(where: { $0.displayName == peerID.displayName }) else { return }
            self.discoveredHosts.append(peerID)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.discoveredHosts.removeAll { $0.displayName == peerID.displayName }
        }
    }
}
