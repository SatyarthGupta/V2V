import OSLog

/// Unified logging (visible in the Xcode console and Console.app). Never log tokens or audio.
nonisolated enum Log {
    static let audio = Logger(subsystem: "com.satyarth.V2V", category: "audio")
    static let session = Logger(subsystem: "com.satyarth.V2V", category: "session")
}
