// 依据公开启动器的 PKCE 接口构建原生授权请求；不模拟 Windows 身份。
// Native authorization requests based on the launcher's public PKCE contract; no Windows identity impersonation.
import Foundation
import CryptoKit
import Security

public enum AuthorizationError: Error, Equatable {
    case invalidRedirect, invalidCallback, invalidState, providerRejected, missingCode, randomFailure
}

public struct PKCEAuthorization {
    public let verifier: String
    public let state: String
    public let redirectURL: URL
    public var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    public init(loopbackPort: UInt16) throws {
        guard loopbackPort != 0 else { throw AuthorizationError.invalidRedirect }
        self.init(verifier: try Self.random(), state: try Self.random(), loopbackPort: loopbackPort)
    }

    init(verifier: String, state: String, loopbackPort: UInt16) {
        self.verifier = verifier
        self.state = state
        self.redirectURL = URL(string: "http://127.0.0.1:\(loopbackPort)/oauth/callback")!
    }

    public func authorizationURL(website: URL = URL(string: "https://www.d2r-reimagined.com/")!) throws -> URL {
        guard website.scheme == "https", website.user == nil, website.password == nil,
              website.host != nil, website.query == nil, website.fragment == nil else {
            throw AuthorizationError.invalidRedirect
        }
        var url = URLComponents(url: website.appendingPathComponent("launcher/authorize"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
                          URLQueryItem(name: "code_challenge", value: challenge),
                          URLQueryItem(name: "state", value: state)]
        return url.url!
    }

    public func code(from callback: URL) throws -> String {
        guard let url = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              url.scheme == redirectURL.scheme, url.host == redirectURL.host,
              url.port == redirectURL.port, url.path == redirectURL.path,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw AuthorizationError.invalidCallback
        }
        var values: [String: String] = [:]
        for item in url.queryItems ?? [] {
            guard values[item.name] == nil, let value = item.value else { throw AuthorizationError.invalidCallback }
            values[item.name] = value
        }
        guard let returnedState = values["state"], Self.equal(returnedState, state) else {
            throw AuthorizationError.invalidState
        }
        guard values["error"] == nil else { throw AuthorizationError.providerRejected }
        guard let code = values["code"], !code.isEmpty else { throw AuthorizationError.missingCode }
        return code
    }

    public func tokenExchangeBody(callback: URL) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["code": code(from: callback),
            "codeVerifier": verifier, "redirectUri": redirectURL.absoluteString])
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AuthorizationError.randomFailure
        }
        return base64URL(Data(bytes))
    }

    private static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
