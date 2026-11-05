import AVFoundation

/// 全局音效管理器，支持开关控制，兼带语音播报
final class SoundManager: NSObject {
    static let shared = SoundManager()

    private enum SoundEffect: CaseIterable {
        case cardDraw
        case cardSlap
        case victory
        case gameOver

        var fileName: String {
            switch self {
            case .cardDraw: return "poker_card_draw_sound"
            case .cardSlap: return "card_slap_on_table"
            case .victory: return "game_victory_sound"
            case .gameOver: return "game_over_sound"
            }
        }

        /// 连续发牌和出牌允许同类音效重叠，结算音效各用一个节点。
        var voiceCount: Int {
            switch self {
            case .cardDraw: return 6
            case .cardSlap: return 4
            case .victory, .gameOver: return 1
            }
        }
    }

    /// 音效开关（持久化到 UserDefaults）
    var soundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundEnabled") }
    }

    /// 引擎、Buffer 和节点只在此队列上访问，避免路由变化与播放互相竞争。
    private let audioQueue = DispatchQueue(label: "com.jock.game.tractor.audio", qos: .userInitiated)
    private let synthesizer = AVSpeechSynthesizer()
    private var engine: AVAudioEngine?
    private var buffers: [SoundEffect: AVAudioPCMBuffer] = [:]
    private var players: [SoundEffect: [AVAudioPlayerNode]] = [:]
    private var nextVoice: [SoundEffect: Int] = [:]
    private var sessionObservers: [NSObjectProtocol] = []
    private var engineObserver: NSObjectProtocol?

    private override init() {
        super.init()

        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: nil
        ) { [weak self] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            self?.audioQueue.async { [weak self] in
                if type == .began {
                    self?.stopPlayers()
                    self?.engine?.stop()
                } else {
                    self?.activateSessionAndStartEngine()
                }
            }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: nil
        ) { [weak self] _ in
            self?.audioQueue.async { [weak self] in self?.startEngineIfNeeded() }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(), queue: nil
        ) { [weak self] _ in
            self?.audioQueue.async { [weak self] in
                self?.buildEngine()
                self?.activateSessionAndStartEngine()
            }
        })

        audioQueue.async { [weak self] in self?.prepareAudio() }
    }

    deinit {
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
    }

    private func prepareAudio() {
        for effect in SoundEffect.allCases {
            guard let url = Bundle.main.url(forResource: effect.fileName, withExtension: "wav") else {
                print("SoundManager ⚠️ 找不到: \(effect.fileName).wav")
                continue
            }
            do {
                let file = try AVAudioFile(forReading: url)
                guard file.length > 0, file.length <= AVAudioFramePosition(UInt32.max),
                      let buffer = AVAudioPCMBuffer(
                        pcmFormat: file.processingFormat,
                        frameCapacity: AVAudioFrameCount(file.length)
                      ) else { continue }
                try file.read(into: buffer)
                buffers[effect] = buffer
            } catch {
                print("SoundManager ⚠️ 无法加载 \(effect.fileName): \(error.localizedDescription)")
            }
        }
        buildEngine()
        activateSessionAndStartEngine()
    }

    private func buildEngine() {
        engine?.stop()
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        let newEngine = AVAudioEngine()
        var newPlayers: [SoundEffect: [AVAudioPlayerNode]] = [:]
        for effect in SoundEffect.allCases {
            guard let buffer = buffers[effect] else { continue }
            let voices = (0..<effect.voiceCount).map { _ in AVAudioPlayerNode() }
            for voice in voices {
                newEngine.attach(voice)
                newEngine.connect(voice, to: newEngine.mainMixerNode, format: buffer.format)
            }
            newPlayers[effect] = voices
        }
        newEngine.prepare()
        players = newPlayers
        nextVoice.removeAll()
        engine = newEngine

        // 蓝牙连接或输出格式改变后，引擎可能暂停；保留已解码的 Buffer 并重启。
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: nil
        ) { [weak self] _ in
            self?.audioQueue.async { [weak self] in self?.startEngineIfNeeded() }
        }
    }

    private func activateSessionAndStartEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default)
            try session.setActive(true)
            startEngineIfNeeded()
        } catch {
            print("SoundManager ⚠️ Audio session setup failed: \(error.localizedDescription)")
        }
    }

    private func startEngineIfNeeded() {
        guard let engine, !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            print("SoundManager ⚠️ Audio engine start failed: \(error.localizedDescription)")
        }
    }

    private func stopPlayers() {
        for voices in players.values {
            for voice in voices { voice.stop() }
        }
    }

    // MARK: - 音效播放接口

    func playCardDraw() { play(.cardDraw) }
    func playCardSlap() { play(.cardSlap) }
    func playVictory() { play(.victory) }
    func playGameOver() { play(.gameOver) }

    private func play(_ effect: SoundEffect) {
        guard soundEnabled else { return }
        audioQueue.async { [weak self] in
            guard let self, self.soundEnabled, let buffer = self.buffers[effect],
                  let voices = self.players[effect], !voices.isEmpty else { return }
            self.startEngineIfNeeded()
            guard self.engine?.isRunning == true else { return }

            let index = self.nextVoice[effect, default: 0] % voices.count
            self.nextVoice[effect] = (index + 1) % voices.count
            let voice = voices[index]
            // 仅在整个池耗尽并轮回到该节点时截断旧音，不让密集事件排队造成延迟。
            voice.stop()
            voice.scheduleBuffer(buffer, at: nil, options: [])
            voice.play()
        }
    }

    func stopAll() {
        audioQueue.async { [weak self] in self?.stopPlayers() }
        DispatchQueue.main.async { [weak self] in
            self?.synthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - 语音播报（领出时喊牌）

    /// 播报领出牌的文字，如“吊主”、“对A”、“拖拉机”、“黑桃A”
    func speakLead(_ text: String) {
        guard soundEnabled, !text.isEmpty else { return }
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
