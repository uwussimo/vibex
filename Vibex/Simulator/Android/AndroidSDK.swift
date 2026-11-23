import Foundation

/// Where the Android SDK is, and what's in it: the emulator, adb and the virtual devices (AVDs) made
/// in Android Studio. Found on its own in the usual places; Settings › Devices can point elsewhere.
nonisolated enum AndroidSDK {
    private static let customKey = "android.sdkPath"

    static var customLocation: URL? {
        get { UserDefaults.standard.string(forKey: customKey).map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: customKey) }
    }

    static var location: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            customLocation,
            environment["ANDROID_HOME"].map { URL(fileURLWithPath: $0) },
            environment["ANDROID_SDK_ROOT"].map { URL(fileURLWithPath: $0) },
            home.appendingPathComponent("Library/Android/sdk"),
            URL(fileURLWithPath: "/opt/homebrew/share/android-commandlinetools"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("platform-tools/adb").path) }
    }

    static var adb: String? { location.map { $0.appendingPathComponent("platform-tools/adb").path } }

    static var emulator: String? {
        guard let path = location?.appendingPathComponent("emulator/emulator").path,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    static var isInstalled: Bool { adb != nil && emulator != nil }

    /// The virtual devices' names, from ~/.android/avd (where Android Studio keeps them).
    static func avds() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = ProcessInfo.processInfo.environment["ANDROID_AVD_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".android/avd")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.filter { $0.hasSuffix(".ini") }.map { String($0.dropLast(4)) }.sorted()
    }

    /// "foyda_pixel8" → "Foyda Pixel 8": AVD names are identifiers; this is what people read.
    static func displayName(_ avd: String) -> String {
        var words: [String] = []
        for part in avd.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " }) {
            var word = String(part)
            // Split "pixel8" into "Pixel 8".
            if let digit = word.firstIndex(where: \.isNumber), digit != word.startIndex, word[word.startIndex..<digit].allSatisfy(\.isLetter) {
                words.append(String(word[word.startIndex..<digit]).capitalized)
                word = String(word[digit...])
                words.append(word)
                continue
            }
            words.append(word.first?.isLetter == true ? word.prefix(1).uppercased() + word.dropFirst() : word)
        }
        return words.joined(separator: " ")
    }
}
