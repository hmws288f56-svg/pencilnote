import UIKit

/// 노트북 주소와 연결 코드를 넣는 화면
final class ConnectViewController: UIViewController, UITextFieldDelegate {
    var onClose: (() -> Void)?

    private let link: PadLink
    private let hostField = UITextField()
    private let codeField = UITextField()
    private let statusLabel = UILabel()
    private let scanButton = UIButton(type: .system)
    private let connectButton = UIButton(type: .system)
    private var waiting = false
    private var hintTimer: Timer?
    private var scannedOnce = false

    init(link: PadLink) {
        self.link = link
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
        preferredContentSize = CGSize(width: 480, height: 460)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.text = "노트북에 연결"
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("닫기", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 17)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        let header = UIStackView(arrangedSubviews: [titleLabel, closeButton])
        header.axis = .horizontal
        header.alignment = .firstBaseline

        let help = UILabel()
        help.text = "노트북에서 ‘펜슬노트 시작’을 실행하면 화면 왼쪽 아래에 주소와 연결 코드가 나옵니다. 연결 코드는 처음 한 번만 필요하고, 그 뒤로는 암호화된 연결로 자동으로 붙어요. 처음 등록은 집 Wi-Fi나 내 핫스팟에서 하세요."
        help.font = .systemFont(ofSize: 15)
        help.textColor = .secondaryLabel
        help.numberOfLines = 0

        style(hostField, placeholder: "주소 (예: 192.168.0.14)", keyboard: .numbersAndPunctuation)
        hostField.text = link.host
        hostField.returnKeyType = .next

        style(codeField, placeholder: link.isPaired ? "연결 코드 (다시 등록할 때만)" : "연결 코드 6자리", keyboard: .numberPad)

        scanButton.setTitle("자동으로 찾기", for: .normal)
        scanButton.titleLabel?.font = .systemFont(ofSize: 17)
        scanButton.addTarget(self, action: #selector(scan), for: .touchUpInside)
        scanButton.layer.cornerRadius = 10
        scanButton.layer.borderWidth = 1
        scanButton.layer.borderColor = UIColor.systemBlue.cgColor
        scanButton.heightAnchor.constraint(equalToConstant: 48).isActive = true

        connectButton.setTitle("연결", for: .normal)
        connectButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        connectButton.setTitleColor(.white, for: .normal)
        connectButton.backgroundColor = .systemBlue
        connectButton.layer.cornerRadius = 10
        connectButton.addTarget(self, action: #selector(connect), for: .touchUpInside)
        connectButton.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let buttons = UIStackView(arrangedSubviews: [scanButton, connectButton])
        buttons.axis = .horizontal
        buttons.spacing = 12
        buttons.distribution = .fillEqually

        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [header, help, hostField, codeField, buttons, statusLabel])
        stack.axis = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(8, after: header)
        stack.setCustomSpacing(20, after: help)
        stack.setCustomSpacing(20, after: codeField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(statusChanged), name: PadLink.statusChanged, object: link)

        if case .denied(let reason) = link.status {
            show(Self.message(for: reason), isError: true)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !scannedOnce && (hostField.text ?? "").isEmpty {
            scannedOnce = true
            scan()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        hintTimer?.invalidate()
        onClose?()
    }

    private func style(_ field: UITextField, placeholder: String, keyboard: UIKeyboardType) {
        field.placeholder = placeholder
        field.keyboardType = keyboard
        field.borderStyle = .roundedRect
        field.font = .monospacedDigitSystemFont(ofSize: 20, weight: .regular)
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.clearButtonMode = .whileEditing
        field.delegate = self
        field.heightAnchor.constraint(equalToConstant: 48).isActive = true
    }

    private func show(_ text: String, isError: Bool) {
        statusLabel.text = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabel
    }

    private static func message(for reason: String) -> String {
        switch reason {
        case "locked":
            return "코드를 여러 번 틀려서 잠시 막혔어요. 5분 뒤에 다시 시도하세요."
        case "token":
            return "노트북에서 등록이 해제됐어요. 노트북 화면의 연결 코드를 입력해 다시 연결하세요."
        case "unreachable":
            return "노트북에 닿지 않아요. 노트북에서 펜슬노트가 켜져 있는지, 같은 Wi-Fi인지, 이 앱에 ‘로컬 네트워크’ 권한을 허용했는지 확인하세요. 카페·학교 Wi-Fi가 기기끼리의 통신을 막는 경우에는 휴대폰 핫스팟을 쓰세요."
        case "replaced":
            return "다른 기기가 이 노트북에 연결했어요. 이 아이패드로 쓰려면 ‘연결’을 누르세요."
        case "none":
            return "연결 코드를 입력하세요."
        default:
            return "연결 코드가 맞지 않아요. 노트북 화면 왼쪽 아래의 코드를 다시 확인하세요."
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === hostField {
            codeField.becomeFirstResponder()
        } else {
            connect()
        }
        return true
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    @objc private func connect() {
        let host = PadLink.cleanHost(hostField.text ?? "")
        let code = (codeField.text ?? "").filter { "0123456789".contains($0) }
        guard !host.isEmpty else {
            show("노트북 주소를 입력하세요. ‘자동으로 찾기’를 눌러도 돼요.", isError: true)
            return
        }
        view.endEditing(true)

        // 이미 등록되어 있고 코드를 비워 뒀으면 주소만 바꿔서 다시 붙는다.
        // (다른 Wi-Fi로 옮겨 주소가 달라져도 코드를 다시 넣을 필요가 없다. 진짜 내 노트북인지는 인증서로 확인한다)
        if code.isEmpty && link.isPaired {
            link.changeHost(host)
            waitForConnection()
            return
        }
        guard code.count == 6 else {
            show("연결 코드 6자리를 입력하세요.", isError: true)
            return
        }
        connectButton.isEnabled = false
        show("등록하는 중…", isError: false)
        link.pair(host: host, code: code) { [weak self] problem in
            guard let self = self else { return }
            self.connectButton.isEnabled = true
            if let problem = problem {
                self.show(Self.message(for: problem), isError: true)
            } else {
                self.codeField.text = ""
                self.waitForConnection()
            }
        }
    }

    private func waitForConnection() {
        waiting = true
        show("연결하는 중…", isError: false)
        link.start()
        hintTimer?.invalidate()
        hintTimer = after(6) { [weak self] in
            guard let self = self, self.waiting else { return }
            self.show(Self.message(for: "unreachable"), isError: true)
        }
    }

    @objc private func statusChanged() {
        guard waiting else { return }
        switch link.status {
        case .connected:
            waiting = false
            dismiss(animated: true)
        case .denied(let reason):
            waiting = false
            show(Self.message(for: reason), isError: true)
        case .off, .connecting:
            break
        }
    }

    @objc private func scan() {
        scanButton.isEnabled = false
        show("같은 Wi-Fi에서 노트북을 찾는 중…", isError: false)
        link.scan { [weak self] found in
            guard let self = self else { return }
            self.scanButton.isEnabled = true
            guard let first = found.first else {
                self.show("찾지 못했어요. 노트북에서 펜슬노트가 켜져 있는지 확인하세요. 방금 ‘로컬 네트워크’ 권한을 허용했다면 한 번 더 눌러 주세요.", isError: true)
                return
            }
            self.hostField.text = first.host
            if found.count == 1 {
                self.show(self.link.isPaired
                    ? "찾았어요: \(first.name). ‘연결’을 누르세요. (이미 등록된 노트북이면 코드는 비워 두면 돼요)"
                    : "찾았어요: \(first.name). 연결 코드를 입력하고 ‘연결’을 누르세요.", isError: false)
            } else {
                self.show("노트북이 \(found.count)대 보여요. \(first.name)의 주소를 넣었어요.", isError: false)
            }
            if !self.link.isPaired && (self.codeField.text ?? "").isEmpty { self.codeField.becomeFirstResponder() }
        }
    }
}
