// Reimagined 原生账户与赛季界面；当前没有游戏准入或服务器存档写入路径。
// Native Reimagined account and ladder UI; no gameplay admission or server-save write path yet.
import UIKit
import SafariServices
import CryptoKit

@MainActor private func onlineText(_ key: String) -> String {
    key.withCString { String(cString: dm_ui($0)) }
}

private final class OnlineDiagnosticTransport: HTTPTransport {
    private let base = SessionTransport()
    private let lock = NSLock()
    private var observations: [[String: Any]] = []
    private var registrationReplies: [[String: Any]] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result = try await base.send(request)
        if ProcessInfo.processInfo.environment["DM_ONLINE_PACKAGE_DIAGNOSTICS"] == "1" {
            record(request.url?.path ?? "", status: result.1.statusCode)
        }
        if ProcessInfo.processInfo.environment["DM_ONLINE_REGISTER_DIAGNOSTICS"] == "1" {
            recordRegistration(request.url?.path ?? "", body: result.0, status: result.1.statusCode)
        }
        return result
    }
    private func record(_ path: String, status: Int) {
        let routes = [("/launch-ticket", "ticket"), ("/game-token", "game-token"),
                      ("/game-token/revoke", "game-token-revoke"), ("/characters/saves", "save-list"),
                      ("/v2/games", "game-list"), ("/client-policy", "policy"),
                      ("/ladders/schedule", "schedule"), ("/auth/launcher/refresh", "refresh"),
                      ("/auth/launcher/token", "authorization"), ("/characters/saves/snapshot", "new-character")]
        guard let route = routes.first(where: { path.hasSuffix($0.0) })?.1 else { return }
        lock.lock()
        observations.append(["route": route, "httpStatus": status])
        observations = Array(observations.suffix(32))
        let snapshot: [String: Any] = ["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                                      "requests": observations]
        lock.unlock()
        guard let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) else { return }
        try? data.write(to: root.appendingPathComponent("online-http-state.json"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func recordRegistration(_ path: String, body: Data, status: Int) {
        let route: String
        if path.hasSuffix("/characters/saves/snapshot") { route = "submit" }
        else if path.contains("/characters/saves/snapshot/receipts/") { route = "receipt" }
        else if path.hasSuffix("/characters/saves") { route = "manifest" }
        else { return }
        guard body.count <= 65_536, let object = try? JSONSerialization.jsonObject(with: body) else { return }
        func shape(_ object: Any) -> Any {
            if let value = object as? [String: Any] { return value.mapValues(shape) }
            if let value = object as? [Any] { return ["count": value.count, "sample": value.first.map(shape) ?? NSNull()] }
            if object is NSNull { return NSNull() }
            if object is NSNumber { return "number-or-boolean" }
            return "string"
        }
        var observation: [String: Any] = ["route": route, "httpStatus": status, "shape": shape(object)]
        if let root = object as? [String: Any], let code = root["code"] as? String, code.utf8.count <= 128,
           code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) {
            observation["code"] = code
        }
        lock.lock(); registrationReplies.append(observation); registrationReplies = Array(registrationReplies.suffix(16))
        let snapshot = registrationReplies; lock.unlock()
        guard let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) else { return }
        try? data.write(to: root.appendingPathComponent("online-registration-replies.json"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

@MainActor
private final class OnlineController: UIViewController, UITableViewDataSource, UITableViewDelegate, SFSafariViewControllerDelegate {
    private let api = try! ReimaginedAPIClient(transport: OnlineDiagnosticTransport())
    private let store = SessionKeychain()
    private var session: LauncherSession?
    private var operation: Task<Void, Never>?
    private var login: LoopbackLogin?
    private var safari: SFSafariViewController?
    private var ladders: [LadderScheduleEntry] = []
    private var regions: [LobbyRegion] = []
    private var selectedLadder: UUID?
    private let status = UILabel()
    private let empty = UILabel()
    private let signIn = UIButton(type: .system)
    private let refresh = UIButton(type: .system)
    private let signOut = UIButton(type: .system)
    private let table = UITableView(frame: .zero, style: .insetGrouped)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        title = onlineText("dmOnlineTitle")
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: onlineText("dmOnlineClose"), style: .plain, target: self, action: #selector(close))
        let note = UILabel()
        note.text = onlineText("dmOnlineNotReady")
        note.font = .preferredFont(forTextStyle: .footnote)
        note.textColor = .secondaryLabel
        note.numberOfLines = 0
        status.font = .preferredFont(forTextStyle: .body)
        status.numberOfLines = 0
        for (button, key, action) in [(signIn, "dmOnlineSignIn", #selector(connect)), (refresh, "dmOnlineRefresh", #selector(reload)), (signOut, "dmOnlineSignOut", #selector(disconnect))] {
            button.configuration = .gray()
            button.setTitle(onlineText(key), for: .normal)
            button.titleLabel?.numberOfLines = 2
            button.addTarget(self, action: action, for: .touchUpInside)
        }
        let buttons = UIStackView(arrangedSubviews: [signIn, refresh, signOut])
        buttons.spacing = 10
        buttons.distribution = .fillProportionally
        let header = UIStackView(arrangedSubviews: [note, status, buttons])
        header.axis = .vertical
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.delegate = self
        table.accessibilityIdentifier = "ReimaginedLadders"
        view.addSubview(table)
        empty.text = onlineText("dmOnlineNoLadders")
        empty.textColor = .secondaryLabel
        empty.textAlignment = .center
        empty.numberOfLines = 0
        empty.font = .preferredFont(forTextStyle: .body)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            table.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor), table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        do { session = try store.load(origin: api.origin) }
        catch { status.text = onlineText("dmOnlineError") }
        reload()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if navigationController?.presentingViewController == nil { navigationItem.rightBarButtonItem = nil }
        recordDiagnostics()
    }

    /// Explicit device-test switch. Captures only this account screen, never
    /// the authorization browser, account identifiers, credentials or responses.
    private func recordDiagnostics() {
        guard ProcessInfo.processInfo.environment["DM_ONLINE_DIAGNOSTICS"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isViewLoaded, self.view.window != nil,
                  self.safari == nil, self.presentedViewController == nil else { return }
            let target = self.navigationController?.view ?? self.view!
            target.layoutIfNeeded()
            let snapshot: [String: Any] = [
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "nativeUserAgent": self.api.identity.userAgent,
                "signedIn": self.session != nil,
                "ladderCount": self.ladders.count, "regionCount": self.regions.count,
                "status": self.status.text ?? "", "signInEnabled": self.signIn.isEnabled,
                "width": target.bounds.width, "height": target.bounds.height,
                "gameAdmissionImplemented": false
            ]
            do {
                let root = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
                let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
                try data.write(to: root.appendingPathComponent("online-state.json"), options: options)
                let picture = UIGraphicsImageRenderer(bounds: target.bounds).image { _ in
                    target.drawHierarchy(in: target.bounds, afterScreenUpdates: true)
                }
                if let png = picture.pngData() {
                    try png.write(to: root.appendingPathComponent("online-ui.png"), options: options)
                }
            } catch { /* Diagnostics must not interrupt account or game use. */ }
        }
    }

    @objc private func close() {
        operation?.cancel()
        login?.cancel()
        dismiss(animated: true)
    }

    private func busy(_ value: Bool) {
        signIn.isEnabled = !value && session == nil
        refresh.isEnabled = !value
        signOut.isEnabled = !value && session != nil
        table.isUserInteractionEnabled = !value
        if value { status.text = onlineText("dmOnlineLoading") }
        else { recordDiagnostics() }
    }

    private func currentSession() async throws -> LauncherSession? {
        guard let old = session else { return nil }
        if old.expiresAtUtc > Date().addingTimeInterval(30) { return old }
        let updated = try await api.refresh(old)
        try Task.checkCancellation()
        try store.save(updated, origin: api.origin)
        session = updated
        return updated
    }

    @objc private func reload() {
        guard operation == nil else { return }
        busy(true)
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.busy(false); self.operation = nil }
            do {
                let credentials = try await self.currentSession()
                let result = try await self.api.schedule(accessToken: credentials?.accessToken)
                try Task.checkCancellation()
                self.ladders = result.ladders
                self.regions = []
                self.selectedLadder = nil
                self.status.text = onlineText(self.session == nil ? "dmOnlineSignedOut" : "dmOnlineSignedIn")
                self.table.backgroundView = result.ladders.isEmpty ? self.empty : nil
                self.table.reloadData()
                if let credentials { await self.inspectPackageIfRequested(credentials) }
            } catch is CancellationError {} catch { self.show(error) }
        }
    }

    /// Explicit development inspection using a complete operator-provided ZIP
    /// and an independently pinned public key OUTSIDE that ZIP. No trust key is
    /// downloaded or accepted from the archive; no game/character is started.
    private func inspectPackageIfRequested(_ credentials: LauncherSession) async {
        guard ProcessInfo.processInfo.environment["DM_ONLINE_PACKAGE_DIAGNOSTICS"] == "1",
              let entry = ladders.first(where: \.isLive) else { return }
        var report: [String: Any] = ["gameAdmission": false, "characterWritten": false,
                                  "nativeUserAgent": api.identity.userAgent]
        var stage = "policy"
        func saveReport() {
            report["stage"] = stage
            report["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            guard let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                  let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
            try? data.write(to: root.appendingPathComponent("online-package-state.json"),
                            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        do {
            saveReport()
            let policy = try await api.policy(for: entry, accessToken: credentials.accessToken)
            guard let bundle = policy.activeBundle else { throw ClientError.invalidResponse }
            let hash = bundle.artifactSha256.lowercased(), keyID = bundle.signingKeyId
            guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  !keyID.isEmpty, keyID.utf8.count <= 64,
                  keyID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
                throw ClientError.invalidResponse
            }
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let archive = root.appendingPathComponent("ReimaginedPackages/" + hash + ".zip")
            let trust = root.appendingPathComponent("ReimaginedTrust/" + keyID + ".pem")
            let attrs = try FileManager.default.attributesOfItem(atPath: trust.path)
            guard ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 4096,
                  attrs[.type] as? FileAttributeType == .typeRegular else { throw ClientError.invalidResponse }
            let pem = try String(contentsOf: trust, encoding: .utf8)
            stage = "complete-package-validation"; saveReport()
            let worker = Task.detached(priority: .utility) {
                let key = try P256.Signing.PublicKey(pemRepresentation: pem)
                return try LadderArchiveVerifier(trustedKeys: [keyID: key]).verify(archive: archive, descriptor: bundle)
            }
            let verified = try await withTaskCancellationHandler(operation: { try await worker.value },
                                                                  onCancel: { worker.cancel() })
            report["packageFilesVerified"] = verified.fileCount
            report["packageRevision"] = verified.revision
            try Task.checkCancellation()
            stage = "fresh-policy-check"; saveReport()
            let fresh = try await api.policy(for: entry, accessToken: credentials.accessToken)
            guard let current = fresh.activeBundle, verified.matches(current) else { throw ClientError.policyChanged }
            stage = "game-save-api-reads"; saveReport()
            let result = try await api.inspectLadderAccount(bundle: current, verifiedPackage: verified, session: credentials)
            report["serverSaveFiles"] = result.saves.files.count
            report["serverAuthoritative"] = result.saves.serverAuthoritative
            report["lobbyRooms"] = result.lobby.games.count
            report["lobbyPlayers"] = result.lobby.totalPlayers
            report["narrowTokenRevocationAccepted"] = true
            if ProcessInfo.processInfo.environment["DM_ONLINE_REGISTER_DIAGNOSTICS"] == "1" {
                stage = "new-character-registration"; saveReport()
                let inputURL = root.appendingPathComponent("ReimaginedRegistration/input.json")
                struct Input: Decodable { let characterName: String; let expectedSHA256: String }
                let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: inputURL))
                guard (2...15).contains(input.characterName.utf8.count), input.characterName.utf8.allSatisfy({
                    (65...90).contains($0) || (97...122).contains($0)
                }) else { throw NewCharacterError.invalidName }
                // Dedicated original-engine test creation only; never scans or
                // selects from the player's Documents/save directory.
                let name = input.characterName
                let source = root.appendingPathComponent("phase18-native-registration/save/\(name)/\(name).d2s")
                let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.size] as? NSNumber)?.intValue == 403 else { throw NewCharacterError.unsupportedHeader }
                let header = try NewCharacterHeader(characterName: name, bytes: Data(contentsOf: source))
                guard header.sha256 == input.expectedSHA256.lowercased() else { throw NewCharacterError.checksumMismatch }
                let registered = try await api.registerNewCharacter(header: header, bundle: current, package: verified,
                    session: credentials, root: root)
                report["initialCharacterRegistered"] = true
                report["serverSaveFilesBeforeRegistration"] = result.saves.files.count
                report["serverSaveFiles"] = registered.snapshotFileCount
                report["initialCharacterBytes"] = registered.initialCharacter.bytes.count
                report["initialCharacterGameEdition"] = header.bytes[248]
                report["serverCharacterVersion"] = registered.initialCharacter.metadata.version
                report["initialCharacterExactReadback"] = registered.initialCharacter.bytes == header.bytes
                report["isolatedSnapshotPrepared"] = true
                report["snapshotFileCount"] = registered.snapshotFileCount
                report["characterWritten"] = true
                report["registrationTokenRevocationAccepted"] = true
            }
            stage = "complete"; saveReport()
        } catch {
            // A narrow-token/ticket refusal must not remove the launcher's
            // separate Keychain session or expose raw server responses.
            report["failed"] = true
            if case ClientError.http(let code) = error { report["httpStatus"] = code }
            else { report["errorType"] = String(reflecting: type(of: error)) }
            if let failure = error as? RegistrationError { report["registrationError"] = String(describing: failure) }
            if case DecodingError.keyNotFound(let key, _) = error { report["missingField"] = key.stringValue }
            saveReport()
        }
    }

    @objc private func connect() {
        guard operation == nil else { return }
        busy(true)
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.login = nil; self.busy(false); self.operation = nil }
            do {
                let flow = try LoopbackLogin()
                self.login = flow
                let browser = SFSafariViewController(url: try flow.authorization.authorizationURL())
                browser.delegate = self
                self.safari = browser
                self.present(browser, animated: true)
                let callback = try await flow.waitForCallback(timeout: 600)
                let credentials = try await self.api.exchange(authorization: flow.authorization, callback: callback)
                try Task.checkCancellation()
                try self.store.save(credentials, origin: self.api.origin)
                self.session = credentials
                self.safari?.dismiss(animated: true)
                self.safari = nil
                self.status.text = onlineText("dmOnlineSignedIn")
                let result = try await self.api.schedule(accessToken: credentials.accessToken)
                try Task.checkCancellation()
                self.ladders = result.ladders
                self.table.backgroundView = result.ladders.isEmpty ? self.empty : nil
                self.table.reloadData()
                await self.inspectPackageIfRequested(credentials)
            } catch is CancellationError { self.status.text = onlineText("dmOnlineCancelled") }
            catch LoginListenerError.cancelled { self.status.text = onlineText("dmOnlineCancelled") }
            catch {
                self.safari?.dismiss(animated: true)
                self.safari = nil
                self.show(error)
            }
        }
    }

    nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        Task { @MainActor [weak self] in
            self?.login?.cancel()
            self?.operation?.cancel()
            self?.safari = nil
        }
    }

    @objc private func disconnect() {
        guard operation == nil, let credentials = session else { return }
        busy(true)
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.busy(false); self.operation = nil }
            do {
                try await self.api.revoke(credentials)
                try self.store.remove(origin: self.api.origin)
                self.session = nil
                self.ladders = []; self.regions = []; self.selectedLadder = nil
                self.status.text = onlineText("dmOnlineSignedOut")
                self.table.backgroundView = self.empty
                self.table.reloadData()
            } catch { self.show(error) }
        }
    }

    private func show(_ error: Error) {
        if error as? ClientError == .http(401) {
            try? store.remove(origin: api.origin)
            session = nil
            status.text = onlineText("dmOnlineSessionExpired")
        } else { status.text = onlineText("dmOnlineError") }
    }

    func numberOfSections(in tableView: UITableView) -> Int { selectedLadder == nil ? 1 : 2 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? ladders.count : regions.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        onlineText(section == 0 ? "dmOnlineLadders" : "dmOnlineRegions")
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        if indexPath.section == 0 {
            let item = ladders[indexPath.row]
            cell.textLabel?.text = item.name
            cell.detailTextLabel?.text = onlineText(item.isLive ? "dmOnlineLive" : "dmOnlineUpcoming")
            cell.accessoryType = selectedLadder == item.id ? .checkmark : .disclosureIndicator
        } else {
            let item = regions[indexPath.row]
            cell.textLabel?.text = item.name
            cell.detailTextLabel?.text = onlineText(item.available ? "dmOnlineAvailable" : "dmOnlineUnavailable")
            let choices = UserDefaults.standard.stringArray(forKey: regionKey()) ?? []
            cell.accessoryType = choices.contains(item.id) ? .checkmark : .none
            cell.selectionStyle = item.available ? .default : .none
        }
        return cell
    }

    private func regionKey() -> String { "reimagined.regions.\(selectedLadder?.uuidString ?? "")" }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard operation == nil else { return }
        if indexPath.section == 1 {
            let item = regions[indexPath.row]
            guard item.available else { return }
            var choices = Set(UserDefaults.standard.stringArray(forKey: regionKey()) ?? [])
            if !choices.insert(item.id).inserted { choices.remove(item.id) }
            UserDefaults.standard.set(choices.sorted(), forKey: regionKey())
            table.reloadData()
            return
        }
        let entry = ladders[indexPath.row]
        busy(true)
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.busy(false); self.operation = nil }
            do {
                let credentials = try await self.currentSession()
                _ = try await self.api.policy(for: entry, accessToken: credentials?.accessToken)
                let result = try await self.api.regions(ladderID: entry.id, accessToken: credentials?.accessToken)
                try Task.checkCancellation()
                self.selectedLadder = entry.id
                self.regions = result
                self.status.text = onlineText(self.session == nil ? "dmOnlineSignedOut" : "dmOnlineSignedIn")
                self.table.reloadData()
            } catch is CancellationError {} catch { self.show(error) }
        }
    }
}

@MainActor
@_cdecl("dm_online_root_controller")
func onlineRootControllerPointer() -> UnsafeMutableRawPointer {
    let nav = UINavigationController(rootViewController: OnlineController())
    nav.isModalInPresentation = true
    return Unmanaged.passRetained(nav).toOpaque()
}

@MainActor
@_cdecl("dm_online_present")
func presentOnlineController() {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow), var controller = window.rootViewController else { return }
    while let presented = controller.presentedViewController { controller = presented }
    guard !(controller is OnlineController) else { return }
    let nav = Unmanaged<UINavigationController>.fromOpaque(onlineRootControllerPointer()).takeRetainedValue()
    nav.modalPresentationStyle = .formSheet
    controller.present(nav, animated: true)
}
