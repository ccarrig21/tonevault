import Foundation

enum Config {
    /// Must match the app group in project.yml (setup.sh keeps them in sync).
    static let appGroup = "group.com.example.tonevault"
    static let apiBase = "https://www.tone3000.com/api/v1"
    static let redirectScheme = "tonevault"
    static var redirectURI: String { "\(redirectScheme)://callback" }
}
