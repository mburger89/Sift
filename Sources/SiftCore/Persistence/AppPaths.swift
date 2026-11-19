/// Where Sift keeps its files (decision D13). Pure: the caller passes the environment and the
/// home directory, so every platform's answer is testable on any host.
public enum AppPaths {
    public enum Platform: Sendable, Equatable { case macOS, linux, windows }

    /// The platform this build runs on.
    public static var currentPlatform: Platform {
        #if os(macOS)
        .macOS
        #elseif os(Windows)
        .windows
        #else
        .linux
        #endif
    }

    /// `~/Library/Application Support/Sift` on macOS; `${XDG_DATA_HOME:-~/.local/share}/sift` on
    /// Linux; `%APPDATA%\Sift` on Windows.
    public static func supportDirectory(platform: Platform, env: [String: String], home: String) -> String {
        switch platform {
        case .macOS:
            return "\(home)/Library/Application Support/Sift"
        case .linux:
            if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty { return "\(xdg)/sift" }
            return "\(home)/.local/share/sift"
        case .windows:
            if let appData = env["APPDATA"], !appData.isEmpty { return "\(appData)\\Sift" }
            return "\(home)\\AppData\\Roaming\\Sift"
        }
    }
}
