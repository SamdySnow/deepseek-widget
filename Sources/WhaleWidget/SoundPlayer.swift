import AVFoundation
import Foundation

/// 音效播放：内置「小黄鸭」与「音效1」两套预置，以及任务结束音
/// （Minecraft·经验球 / 预设 A）。
@MainActor
final class SoundPlayer: ObservableObject {

    enum Preset: String, CaseIterable {
        case duck
        case beep

        var title: String {
            switch self {
            case .duck: return "小黄鸭"
            case .beep: return "音效1"
            }
        }
    }

    enum TaskEnd: String, CaseIterable {
        case expOrb
        case presetA
        case off

        var title: String {
            switch self {
            case .expOrb: return "Minecraft·经验球"
            case .presetA: return "预设 A"
            case .off: return "关闭"
            }
        }
    }

    private var cache: [String: AVAudioPlayer] = [:]
    @Published var volume: Double = 0.9
    @Published var enabled: Bool = true

    /// 预置音效的文件名映射。
    private static func file(for preset: Preset, pressed: Bool) -> String? {
        switch preset {
        case .duck: return pressed ? "Ya1.mp3" : "Ya2.mp3"
        case .beep: return pressed ? "D1.mp3" : "D2.mp3"
        }
    }

    func playPress(preset: Preset) { play(file: Self.file(for: preset, pressed: true)) }
    func playRelease(preset: Preset) { play(file: Self.file(for: preset, pressed: false)) }

    func playTaskEnd(_ kind: TaskEnd) {
        switch kind {
        case .expOrb: play(file: "minecraft-exp-orb.wav")
        case .presetA: play(file: "task-end-a.wav")
        case .off: break
        }
    }

    private func play(file name: String?) {
        guard enabled, let name, volume > 0 else { return }
        guard let url = Assets.url(name) else { return }
        do {
            let player: AVAudioPlayer
            if let cached = cache[name] {
                player = cached
                player.currentTime = 0
            } else {
                player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                cache[name] = player
            }
            player.volume = Float(max(0, min(1, volume)))
            player.play()
        } catch {
            // 资源缺失时静默降级
        }
    }
}
