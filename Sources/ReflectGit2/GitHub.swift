import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security

/// The GitHub App the apps sign in through, as the app's Info.plist gives
/// it — from `iOS/GitHub.xcconfig` on the phone, the build script on the Mac.
public enum GitHubApp {
    public static let clientID = info("GitHubClientID")
    public static let clientSecret = info("GitHubClientSecret")
    public static let slug = info("GitHubAppSlug")
    public static var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty && !slug.isEmpty }

    /// Where GitHub sends the browser back to; the app's callback URL.
    public static let callbackScheme = "com.mariusae.reflect"
    public static let redirectURI = "\(callbackScheme)://oauth/callback"

    public static var installURL: URL { URL(string: "https://github.com/apps/\(slug)/installations/new")! }

    private static func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

/// A repository the app was given, to keep a graph in.
public struct GitHubRepository: Decodable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var fullName: String
    public var cloneURL: String
    public var isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case id, fullName = "full_name", cloneURL = "clone_url", isPrivate = "private"
    }
}

/// Shows GitHub's page for a URL, in the system's browser sheet, and gives
/// back the URL GitHub sends the browser back to, at a scheme.
public typealias GitHubAuthenticator = @MainActor (_ url: URL, _ callbackScheme: String) async throws -> URL

/// The GitHub account the app is signed in to: its tokens, kept in the
/// Keychain and refreshed before they run out, and who it is.
@MainActor
@Observable
public final class GitHubAccount {
    struct Tokens: Codable {
        var access: String
        var accessExpires: Date?
        var refresh: String?
        var refreshExpires: Date?
    }

    public struct User: Codable, Sendable {
        public var login: String
        public var id: Int
        public var name: String?

        /// Who commits are by: the name GitHub has, and the address GitHub
        /// keeps private for them.
        public var identity: (name: String, email: String) {
            (name?.isEmpty == false ? name! : login, "\(id)+\(login)@users.noreply.github.com")
        }
    }

    private(set) var tokens: Tokens?
    public private(set) var user: User?
    public var isSignedIn: Bool { tokens != nil }

    /// The token the sync hands to git, readable off the main thread.
    public nonisolated let currentToken = TokenBox()

    private static let tokensKey = "github.tokens"
    private static let userKey = "github.user"

    public init() {
        tokens = Keychain.read(Self.tokensKey).flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) }
        user = UserDefaults.standard.data(forKey: Self.userKey).flatMap { try? JSONDecoder().decode(User.self, from: $0) }
        currentToken.value = tokens?.access
    }

    // MARK: Signing in

    /// Signs in through GitHub's page in the system's browser sheet, where
    /// the person is likely signed in already.
    public func signIn(_ authenticate: GitHubAuthenticator) async throws {
        let verifier = Self.randomString()
        let state = Self.randomString()
        var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: GitHubApp.clientID),
            URLQueryItem(name: "redirect_uri", value: GitHubApp.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: Self.challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        let callback = try await authenticate(components.url!, GitHubApp.callbackScheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else { throw GitHubError("GitHub sent back an unexpected answer.") }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw GitHubError(items.first(where: { $0.name == "error_description" })?.value ?? "GitHub did not sign in.")
        }
        try await exchange(["code": code, "redirect_uri": GitHubApp.redirectURI, "code_verifier": verifier])
    }

    /// Lets the person choose, on GitHub, the repositories the app may use.
    /// Installing it signs in too; changing an installation may not come
    /// back here, and closing the sheet is how the person says they are done.
    public func chooseRepositories(_ authenticate: GitHubAuthenticator) async throws {
        let callback: URL
        do {
            callback = try await authenticate(GitHubApp.installURL, GitHubApp.callbackScheme)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let code = items.first(where: { $0.name == "code" })?.value {
            try await exchange(["code": code])
        }
    }

    public func signOut() {
        tokens = nil
        user = nil
        currentToken.value = nil
        Keychain.delete(Self.tokensKey)
        UserDefaults.standard.removeObject(forKey: Self.userKey)
    }

    // MARK: Tokens

    /// A refresh under way: every caller waits on the one. A refresh token
    /// is good once — two at a time, and the second was turned away as if
    /// the sign-in were gone, signing the app out.
    private var refreshing: Task<Void, Error>?

    /// A token good for a while yet: refreshed first when it is running out.
    public func validAccessToken() async throws -> String {
        guard let tokens else { throw GitHubError("Not signed in to GitHub.") }
        if let expires = tokens.accessExpires, expires < Date().addingTimeInterval(5 * 60) {
            if let refreshing {
                try await refreshing.value
            } else {
                guard let refresh = tokens.refresh, tokens.refreshExpires.map({ $0 > Date() }) ?? true else {
                    signOut()
                    throw GitHubError("Signed out of GitHub: sign in again.")
                }
                let task = Task { try await exchange(["grant_type": "refresh_token", "refresh_token": refresh]) }
                refreshing = task
                defer { refreshing = nil }
                try await task.value
            }
        }
        guard let tokens = self.tokens else { throw GitHubError("Not signed in to GitHub.") }
        return tokens.access
    }

    private func exchange(_ fields: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let form = fields.merging(["client_id": GitHubApp.clientID, "client_secret": GitHubApp.clientSecret]) { a, _ in a }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
        request.httpBody = Data(form.utf8)
        let (data, _) = try await URLSession.shared.data(for: request)

        struct Answer: Decodable {
            var access_token: String?
            var expires_in: Double?
            var refresh_token: String?
            var refresh_token_expires_in: Double?
            var error: String?
            var error_description: String?
        }
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        guard let access = answer.access_token else {
            // Turned away for the refresh token sent: signed out only when it
            // is still the one kept — not one another refresh has replaced.
            if answer.error == "bad_refresh_token", fields["refresh_token"] == self.tokens?.refresh { signOut() }
            throw GitHubError(answer.error_description ?? answer.error ?? "GitHub did not give a token.")
        }
        let now = Date()
        let tokens = Tokens(access: access, accessExpires: answer.expires_in.map { now.addingTimeInterval($0) },
                            refresh: answer.refresh_token ?? self.tokens?.refresh,
                            refreshExpires: answer.refresh_token_expires_in.map { now.addingTimeInterval($0) } ?? self.tokens?.refreshExpires)
        self.tokens = tokens
        currentToken.value = access
        Keychain.write(Self.tokensKey, try JSONEncoder().encode(tokens))
        if user == nil { try? await loadUser() }
    }

    // MARK: The API

    private func loadUser() async throws {
        let user: User = try await get("https://api.github.com/user")
        self.user = user
        UserDefaults.standard.set(try JSONEncoder().encode(user), forKey: Self.userKey)
    }

    /// The repositories the app was given, on every account it is installed on.
    public func repositories() async throws -> [GitHubRepository] {
        struct Installations: Decodable { var installations: [Installation] }
        struct Installation: Decodable { var id: Int }
        struct Repositories: Decodable { var repositories: [GitHubRepository] }
        if user == nil { try? await loadUser() }
        let installations: Installations = try await get("https://api.github.com/user/installations")
        var found: [GitHubRepository] = []
        for installation in installations.installations {
            let page: Repositories = try await get("https://api.github.com/user/installations/\(installation.id)/repositories?per_page=100")
            found += page.repositories
        }
        return found.sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }
    }

    private func get<T: Decodable>(_ url: String) async throws -> T {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            signOut()
            throw GitHubError("GitHub no longer accepts this sign-in: sign in again.")
        }
        guard (200..<300).contains(status) else { throw GitHubError("GitHub answered \(status).") }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: PKCE

    private static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The token git is handed, from whichever thread git asks on.
public final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    public var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    public var credentials: LibGit2Backend.Credentials? {
        value.map { LibGit2Backend.Credentials(username: "x-access-token", password: $0) }
    }
}

public struct GitHubError: LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The Keychain, for the tokens: on the phone, readable after it is first
/// unlocked, so a sync in the background can use them.
enum Keychain {
    private static let service = "com.mariusae.Reflect.github"

    static func read(_ account: String) -> Data? {
        var result: AnyObject?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    static func write(_ account: String, _ data: Data) {
        delete(account)
        var item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: data]
        #if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
