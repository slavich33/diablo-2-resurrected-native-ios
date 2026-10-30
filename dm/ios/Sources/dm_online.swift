// Reimagined 原生账户与赛季界面；当前没有游戏准入或服务器存档写入路径。
// Native Reimagined account and ladder UI; no gameplay admission or server-save write path yet.
import UIKit
import SafariServices

@MainActor private func onlineText(_ key: String) -> String {
    key.withCString { String(cString: dm_ui($0)) }
}

@MainActor
private final class OnlineController: UIViewController, UITableViewDataSource, UITableViewDelegate, SFSafariViewControllerDelegate {
    private let api = try! ReimaginedAPIClient()
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
            } catch is CancellationError {} catch { self.show(error) }
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
