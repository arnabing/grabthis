import AppKit
import Foundation

enum FeedbackSoundService {
    static func playStart() {
        playSystemSoundFallback(fileNames: ["Pop.aiff", "Ping.aiff", "Glass.aiff"])
    }

    static func playStop() {
        playSystemSoundFallback(fileNames: ["Tink.aiff", "Blow.aiff", "Submarine.aiff"])
    }
}

private extension FeedbackSoundService {
    static func playSystemSoundFallback(fileNames: [String]) {
        for name in fileNames {
            let path = "/System/Library/Sounds/\(name)"
            if FileManager.default.fileExists(atPath: path),
               let sound = NSSound(contentsOfFile: path, byReference: true) {
                sound.play()
                return
            }
        }
        NSSound.beep()
    }
}


