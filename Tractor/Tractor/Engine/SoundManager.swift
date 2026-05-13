import AVFoundation

/// 全局音效管理器，支持开关控制，兼带语音播报
class SoundManager: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SoundManager()

    /// 音效开关（持久化到 UserDefaults）
    var soundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundEnabled") }
    }

    private var cardDrawPlayer:  AVAudioPlayer?
    private var cardSlapPlayer:  AVAudioPlayer?
    private var victoryPlayer:   AVAudioPlayer?
    private var gameOverPlayer:  AVAudioPlayer?

    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        cardDrawPlayer  = makePlayer(named: "poker_card_draw_sound")
        cardSlapPlayer  = makePlayer(named: "card_slap_on_table")
        victoryPlayer   = makePlayer(named: "game_victory_sound")
        gameOverPlayer  = makePlayer(named: "game_over_sound")
        synthesizer.delegate = self
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
        guard soundEnabled else { return }
        cardDrawPlayer?.stop()
        cardDrawPlayer?.currentTime = 0
        cardDrawPlayer?.play()
    }

    func playCardSlap() {
        guard soundEnabled else { return }
        cardSlapPlayer?.stop()
        cardSlapPlayer?.currentTime = 0
        cardSlapPlayer?.play()
    }

    func playVictory() {
        guard soundEnabled else { return }
        victoryPlayer?.stop()
        victoryPlayer?.currentTime = 0
        victoryPlayer?.play()
    }

    func playGameOver() {
        guard soundEnabled else { return }
        gameOverPlayer?.stop()
        gameOverPlayer?.currentTime = 0
        gameOverPlayer?.play()
    }

    func stopAll() {
        cardDrawPlayer?.stop()
        cardSlapPlayer?.stop()
        victoryPlayer?.stop()
        gameOverPlayer?.stop()
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - 语音播报（领出时喊牌）

    /// 播报领出牌的文字，如"吊主"、"对A"、"拖拉机"、"黑桃A"
    func speakLead(_ text: String) {
        guard soundEnabled, !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate  = 0.52          // 语速（0.0-1.0，默认 0.5）
        utterance.pitchMultiplier = 1.1 // 略高音调，更有活力
        synthesizer.speak(utterance)
    }
}
