import SwiftUI
import AuthenticationServices
import CryptoKit

struct Tone: Identifiable, Hashable { let id: String; let title: String; let subtitle: String }
struct RemoteModel: Identifiable, Hashable { let id: String; let name: String; let size: String; let url: String }
enum ApiError: LocalizedError {
    case auth, http(Int)
    var errorDescription: String? {
        switch self { case .auth: return "Sign-in failed. Check your key and redirect URI."
        case .http(let c): return "TONE3000 returned HTTP \(c)." }
    }
}

@MainActor
final class TONE3000: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    private let ud = UserDefaults.standard
    @Published var clientID: String { didSet { ud.set(clientID, forKey: "t3k_cid") } }
    @Published var access: String { didSet { ud.set(access, forKey: "t3k_access") } }
    private var refresh: String { get { ud.string(forKey: "t3k_refresh") ?? "" } set { ud.set(newValue, forKey: "t3k_refresh") } }
    private var session: ASWebAuthenticationSession?
    var signedIn: Bool { !access.isEmpty }

    override init() {
        clientID = UserDefaults.standard.string(forKey: "t3k_cid") ?? ""
        access = UserDefaults.standard.string(forKey: "t3k_access") ?? ""
        super.init()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }

    func signOut() { access = ""; refresh = "" }

    // MARK: OAuth 2.0 + PKCE
    func login() async throws {
        guard !clientID.isEmpty else { throw ApiError.auth }
        let verifier = Self.random(48)
        let challenge = Self.b64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.random(16)
        var c = URLComponents(string: Config.apiBase + "/oauth/authorize")!
        c.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: Config.redirectURI), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state),
        ]
        let cb: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: Config.redirectScheme) { url, err in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: err ?? URLError(.cancelled)) }
            }
            s.presentationContextProvider = self
            self.session = s
            s.start()
        }
        let items = URLComponents(url: cb, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else { throw ApiError.auth }
        try await token(["grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                         "redirect_uri": Config.redirectURI, "client_id": clientID])
    }

    private func token(_ form: [String: String]) async throws {
        var r = URLRequest(url: URL(string: Config.apiBase + "/oauth/token")!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let a = j["access_token"] as? String else { throw ApiError.auth }
        access = a
        if let rt = j["refresh_token"] as? String { refresh = rt } // refresh tokens rotate: always store the new one
    }

    private static func random(_ n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n); _ = SecRandomCopyBytes(kSecRandomDefault, n, &b); return b64url(Data(b))
    }
    private static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: Requests
    private func authed(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url); r.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization"); return r
    }

    private func get(_ path: String, _ q: [URLQueryItem]) async throws -> [String: Any] {
        func go() async throws -> (Data, Int) {
            var c = URLComponents(string: Config.apiBase + path)!
            c.queryItems = q
            let (d, resp) = try await URLSession.shared.data(for: authed(c.url!))
            return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var (d, s) = try await go()
        if s == 401, !refresh.isEmpty, !clientID.isEmpty {
            try await token(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
            (d, s) = try await go()
        }
        guard s == 200 else { throw ApiError.http(s) }
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    private func str(_ d: [String: Any], _ keys: [String]) -> String {
        for k in keys { if let s = d[k] as? String, !s.isEmpty { return s }; if let n = d[k] as? Int { return String(n) } }
        return ""
    }

    func search(_ query: String, page: Int = 1) async throws -> [Tone] {
        var q: [URLQueryItem] = [.init(name: "page", value: "\(page)"), .init(name: "page_size", value: "24"), .init(name: "format", value: "nam")]
        if !query.isEmpty { q.append(.init(name: "query", value: query)) }
        let j = try await get("/tones/search", q)
        return (j["data"] as? [[String: Any]] ?? []).map { d in
            let user = (d["user"] as? [String: Any]).map { str($0, ["username", "name"]) } ?? ""
            let parts = [str(d, ["gear"]), user.isEmpty ? "" : "by \(user)", str(d, ["models_count"]).isEmpty ? "" : "\(str(d, ["models_count"])) models"]
            return Tone(id: str(d, ["id"]), title: str(d, ["title", "name"]), subtitle: parts.filter { !$0.isEmpty }.joined(separator: " · "))
        }
    }

    func models(for tone: Tone) async throws -> [RemoteModel] {
        let j = try await get("/models", [.init(name: "tone_id", value: tone.id), .init(name: "page_size", value: "100")])
        return (j["data"] as? [[String: Any]] ?? []).compactMap { d in
            let u = str(d, ["model_url"]); if u.isEmpty { return nil }
            return RemoteModel(id: str(d, ["id"]), name: str(d, ["name", "title"]), size: str(d, ["size"]), url: u)
        }
    }

    func download(_ m: RemoteModel, tone: Tone) async throws {
        guard let u = URL(string: m.url) else { throw ApiError.http(0) }
        let (tmp, resp) = try await URLSession.shared.download(for: authed(u))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ApiError.http(code) }
        let dest = ModelStore.writeDir.appendingPathComponent(ModelStore.sanitize("\(tone.title) - \(m.name)") + ".nam")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}
