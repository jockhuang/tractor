import AVFoundation

/// 全局音效管理器，支持开关控制，兼带语音播报
class SoundManager: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SoundManager()

    private enum SoundEffect {
        case cardDraw
        case cardSlap
        case victory
        case gameOver
    }

    /// 音效开关（持久化到 UserDefaults）
    var soundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundEnabled") }
    }

    private var cardDrawPlayer:  AVAudioPlayer?
    private var cardSlapPlayer:  AVAudioPlayer?
    private var victoryPlayer:   AVAudioPlayer?
    private var gameOverPlayer:  AVAudioPlayer?

    /// AVAudioSession 激活和 AVAudioPlayer 预热都可能阻塞，统一放到串行后台队列。
    private let audioQueue = DispatchQueue(label: "com.jock.game.tractor.audio", qos: .userInitiated)
    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self

        audioQueue.async { [weak self] in
            self?.prepareAudio()
        }
    }

    private func prepareAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, mode: .default)
            // iOS 17–26 only expose the blocking API. Running it on audioQueue keeps the UI responsive.
            try session.setActive(true)
        } catch {
            print("SoundManager ⚠️ Audio session setup failed: \(error.localizedDescription)")
        }

        cardDrawPlayer = makePlayer(named: "poker_card_draw_sound")
        cardSlapPlayer = makePlayer(named: "card_slap_on_table")
        victoryPlayer = makePlayer(named: "game_victory_sound")
        gameOverPlayer = makePlayer(named: "game_over_sound")
    }

    private func makePlayer(named name: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            print("SoundManager ⚠️ 找不到: \(name).wav")
            return nil
        }
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        return player
    }

    // MARK: - 音效播放接口

    func playCardDraw() {
        play(.cardDraw)
    }

    func playCardSlap() {
        play(.cardSlap)
    }

    func playVictory() {
        play(.victory)
    }

    func playGameOver() {
        play(.gameOver)
    }

    private func play(_ effect: SoundEffect) {
        guard soundEnabled else { return }
        audioQueue.async { [weak self] in
            guard let self, self.soundEnabled else { return }
            let player: AVAudioPlayer?
            switch effect {
            case .cardDraw: player = self.cardDrawPlayer
            case .cardSlap: player = self.cardSlapPlayer
            case .victory: player = self.victoryPlayer
            case .gameOver: player = self.gameOverPlayer
            }
            player?.stop()
            player?.currentTime = 0
            player?.play()
        }
    }

    func stopAll() {
        audioQueue.async { [weak self] in
            self?.cardDrawPlayer?.stop()
            self?.cardSlapPlayer?.stop()
            self?.victoryPlayer?.stop()
            self?.gameOverPlayer?.stop()
        }
        DispatchQueue.main.async { [weak self] in
            self?.synthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - 语音播报（领出时喊牌）

    /// 播报领出牌的文字，如"吊主"、"对A"、"拖拉机"、"黑桃A"
    func speakLead(_ text: String) {
        guard soundEnabled, !text.isEmpty else { return }
        // 排在 prepareAudio 后执行，确保语音首次播放也不会在主线程触发会话激活。
        audioQueue.async { [weak self] in
            guard let self, self.soundEnabled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.soundEnabled else { return }
                self.synthesizer.stopSpeaking(at: .immediate)
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = AVSpeechSynthesisVoice(language: L10n.speechLanguageCode)
                utterance.rate = 0.52
                utterance.pitchMultiplier = 1.1
                self.synthesizer.speak(utterance)
            }
        }
    }
}
