import UIKit
import PencilKit

/// 필기 화면. 어떤 노트의 몇 페이지를 열지는 노트북이 정하고, 이 화면은 그 페이지에 쓴 필기를 노트북으로 보낸다.
///
/// 노트북으로 보내는 것은 세 가지다.
/// - live : 펜이 움직이는 동안의 위치 (노트북이 임시 선을 그림)
/// - patch: 획이 끝날 때마다, 달라진 사각형 영역의 그림
/// - save : 잠깐 쉬는 사이에, 페이지 전체(필기 원본 + 그림 + 작은 미리보기)
final class NoteViewController: UIViewController, PKCanvasViewDelegate, PadLinkDelegate {
    private static let margin: CGFloat = 12

    private let link = PadLink()
    private let bar = UIView()
    private let stage = UIView()
    private let paper = PaperView(frame: Page.rect)
    private let canvas = PKCanvasView()
    private let toolPicker = PKToolPicker()
    private let messageLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    private let statusButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let pageLabel = UILabel()
    private lazy var themeButton = barButton("moon", "어두운 화면", #selector(themeTapped))
    private lazy var undoButton = barButton("arrow.uturn.backward", "실행 취소", #selector(undoTapped))
    private lazy var redoButton = barButton("arrow.uturn.forward", "다시 실행", #selector(redoTapped))
    private lazy var prevButton = barButton("chevron.left", "이전 페이지", #selector(prevTapped))
    private lazy var nextButton = barButton("chevron.right", "다음 페이지", #selector(nextTapped))
    private lazy var addButton = barButton("plus", "새 페이지", #selector(addTapped))

    // 노트북이 알려 준 현재 페이지
    private var wanted: PageRef?
    private var wantedRev = 0
    private var wantedPaper = "plain"
    private var noteTitle = ""
    private var pageIndex = 0
    private var pageCount = 1

    // 지금 화면에 올라와 있는 페이지
    private var loaded: PageRef?
    private var loading: PageRef?
    private var rev = 0
    private var keys: [StrokeKey] = []
    private var lastLoad = Date.distantPast

    // 조각 보내기
    private let renderQueue = DispatchQueue(label: "pencilnote.render", qos: .userInitiated)
    private var patchBase = 0
    private var patchBusy = false
    private var pendingRect: CGRect?

    // 전체 저장
    private var dirty = false
    private var saving = false
    private var saveTimer: Timer?

    // 쓰는 중인 획
    private var strokeId = 0
    private var livePoints: [Double] = []
    private var lastLiveSend: CFTimeInterval = 0

    // 화면 배치
    private var lastStageSize = CGSize.zero
    private var lastViewSend: CFTimeInterval = 0
    private var viewTimer: Timer?
    private var pickerReady = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.bar
        setupBar()
        setupStage()

        link.delegate = self
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appBecameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillResign), name: UIApplication.willResignActiveNotification, object: nil)

        refresh()
        link.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !pickerReady else { return }
        pickerReady = true
        applyTheme()
        toolPicker.setVisible(true, forFirstResponder: canvas)
        toolPicker.addObserver(canvas)
        canvas.becomeFirstResponder()
        if !link.isPaired { showConnect() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = stage.bounds.size
        guard size.width > 0, size.height > 0, size != lastStageSize else { return }
        lastStageSize = size
        stage.layoutIfNeeded()

        // 회전 등으로 크기가 바뀌면 너비에 맞추되, 보고 있던 세로 위치는 유지한다.
        let oldZoom = canvas.zoomScale
        let top = oldZoom > 0 ? (canvas.contentOffset.y + canvas.contentInset.top) / oldZoom : 0
        let fitWidth = max(0.1, (size.width - Self.margin * 2) / Page.width)
        let fitAll = max(0.1, min(fitWidth, (size.height - Self.margin * 2) / Page.height))
        canvas.minimumZoomScale = fitAll
        canvas.maximumZoomScale = max(fitWidth * 4, 3)
        canvas.zoomScale = fitWidth
        geometryChanged()
        scroll(toTop: top)
    }

    // MARK: 화면 만들기

    private func barButton(_ symbol: String, _ label: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 42).isActive = true
        button.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return button
    }

    private func setupBar() {
        bar.backgroundColor = Theme.bar
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)

        let line = UIView()
        line.backgroundColor = Theme.line
        line.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(line)

        statusButton.setImage(UIImage(systemName: "laptopcomputer"), for: .normal)
        statusButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        statusButton.addTarget(self, action: #selector(showConnect), for: .touchUpInside)
        statusButton.setContentHuggingPriority(.required, for: .horizontal)
        statusButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = Theme.title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pageLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        pageLabel.textColor = Theme.dim
        pageLabel.textAlignment = .center
        pageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        pageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [statusButton, titleLabel, themeButton, undoButton, redoButton, prevButton, pageLabel, nextButton, addButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 4
        row.setCustomSpacing(16, after: statusButton)
        row.setCustomSpacing(18, after: redoButton)
        row.setCustomSpacing(14, after: themeButton)
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            row.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
            row.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            row.heightAnchor.constraint(equalToConstant: 46),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -2),

            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func setupStage() {
        stage.backgroundColor = Theme.stage
        stage.clipsToBounds = true
        stage.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(stage, belowSubview: bar)

        // 종이는 캔버스 "뒤"에 따로 두고, 캔버스가 스크롤/확대될 때 위치를 맞춰 준다.
        paper.isHidden = true
        stage.addSubview(paper)

        canvas.delegate = self
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .default
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.alwaysBounceVertical = true
        canvas.drawingGestureRecognizer.isEnabled = false
        canvas.drawingGestureRecognizer.addTarget(self, action: #selector(drawingGesture(_:)))
        canvas.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(canvas)

        messageLabel.font = .systemFont(ofSize: 18, weight: .medium)
        messageLabel.textColor = Theme.dim
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(messageLabel)

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(spinner)

        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: bar.bottomAnchor),
            stage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            canvas.topAnchor.constraint(equalTo: stage.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: stage.bottomAnchor),

            messageLabel.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: stage.leadingAnchor, constant: 32),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: stage.trailingAnchor, constant: -32),

            spinner.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
        ])
    }

    /// 위쪽 막대와 안내 문구를 현재 상태에 맞춘다.
    private func refresh() {
        let connected = link.status == .connected
        let hasPage = loaded != nil

        var statusText = ""
        var statusColor = UIColor.systemBlue
        var hint = ""
        switch link.status {
        case .connected:
            statusText = link.serverName.isEmpty ? "연결됨" : link.serverName
            statusColor = UIColor(red: 0.10, green: 0.56, blue: 0.30, alpha: 1)
        case .connecting:
            statusText = "연결 중…"
            statusColor = .systemOrange
            hint = link.certProblem
                ? "이 주소의 기기는 등록한 노트북이 아니에요.\n노트북을 다시 찾는 중… 계속 안 되면 믿을 수 있는 Wi-Fi에서 다시 등록하세요."
                : "노트북을 찾는 중…\n노트북에서 ‘펜슬노트 시작’을 실행했는지 확인하세요."
        case .off:
            statusText = "노트북 연결"
            hint = "노트북에 연결하면 필기를 시작할 수 있어요.\n왼쪽 위의 ‘노트북 연결’을 누르세요."
        case .denied(let reason):
            statusText = reason == "replaced" ? "다른 기기가 연결됨" : "다시 등록 필요"
            statusColor = .systemRed
            hint = reason == "replaced"
                ? "다른 기기가 이 노트북에 연결했어요.\n왼쪽 위를 눌러 다시 연결할 수 있어요."
                : "노트북에서 등록이 해제됐어요.\n왼쪽 위를 눌러 연결 코드를 다시 입력하세요."
        }
        statusButton.setTitle(" " + statusText, for: .normal)
        statusButton.tintColor = statusColor

        titleLabel.text = hasPage ? noteTitle : ""
        pageLabel.text = hasPage ? "\(pageIndex + 1) / \(pageCount)" : ""
        prevButton.isEnabled = connected && hasPage && pageIndex > 0
        nextButton.isEnabled = connected && hasPage && pageIndex < pageCount - 1
        addButton.isEnabled = connected && hasPage
        undoButton.isEnabled = hasPage
        redoButton.isEnabled = hasPage

        messageLabel.text = hint
        messageLabel.isHidden = hasPage || hint.isEmpty
        UIApplication.shared.isIdleTimerDisabled = connected
    }

    // MARK: 노트북에서 온 소식

    func linkStatusChanged() {
        refresh()
        if link.status == .connected {
            sendView()
        } else {
            loading = nil
            spinner.stopAnimating()
            canvas.drawingGestureRecognizer.isEnabled = loaded != nil
        }
    }

    func linkReceived(_ message: [String: Any]) {
        switch message["t"] as? String {
        case "state":
            applyState(message)
        case "flush":
            saveNow()
        default:
            break
        }
    }

    private func applyState(_ m: [String: Any]) {
        guard let note = m["note"] as? [String: Any],
              let page = m["page"] as? [String: Any],
              let noteId = note["id"] as? String,
              let pageId = page["id"] as? String else { return }

        noteTitle = note["title"] as? String ?? ""
        pageIndex = (m["index"] as? NSNumber)?.intValue ?? 0
        pageCount = (m["count"] as? NSNumber)?.intValue ?? 1
        wantedPaper = page["paper"] as? String ?? "plain"
        wantedRev = (page["rev"] as? NSNumber)?.intValue ?? 0
        let target = PageRef(note: noteId, page: pageId, gen: (page["gen"] as? NSNumber)?.intValue ?? 0)
        wanted = target

        if target == loaded {
            paper.kind = wantedPaper
            refresh()
            sendView()
            // 끊겨 있는 동안 쓴 필기가 있으면 지금 올린다.
            if dirty { saveNow() }
        } else {
            refresh()
            openWanted()
        }
    }

    // MARK: 페이지 열기

    private func openWanted() {
        guard let target = wanted, target != loaded, target != loading else { return }
        // 보고 있던 페이지에 아직 올리지 않은 필기가 있으면 먼저 올리기 시작한다.
        if dirty { saveNow() }

        loading = target
        let serverRev = wantedRev
        canvas.drawingGestureRecognizer.isEnabled = false
        spinner.startAnimating()

        link.request("GET", "/api/notes/\(target.note)/pages/\(target.page)/drawing") { [weak self] data, response in
            guard let self = self, self.loading == target else { return }
            self.loading = nil

            guard let response = response, response.statusCode == 200 || response.statusCode == 204 else {
                // 받지 못함: 연결이 살아 있고 아직 이 페이지를 원하면 잠시 뒤 다시 시도
                after(1) { [weak self] in
                    guard let self = self, self.link.status == .connected else { return }
                    self.openWanted()
                }
                return
            }
            guard self.wanted == target else {
                self.openWanted()
                return
            }

            var drawing = PKDrawing()
            if response.statusCode == 200, let data = data, !data.isEmpty, let saved = try? PKDrawing(data: data) {
                drawing = saved
            }
            var pageRev = Int(response.value(forHTTPHeaderField: "X-Rev") ?? "") ?? serverRev
            var needsUpload = false
            // 지난번에 노트북으로 올리지 못한 필기가 아이패드에 남아 있으면 그쪽이 더 최신이다.
            if let kept = LocalCache.read(target), kept.rev > pageRev {
                drawing = kept.drawing
                pageRev = kept.rev
                needsUpload = true
            }
            self.display(drawing, as: target, rev: pageRev, needsUpload: needsUpload)
        }
    }

    private func display(_ drawing: PKDrawing, as page: PageRef, rev pageRev: Int, needsUpload: Bool) {
        saveTimer?.invalidate()
        saveTimer = nil
        lastLoad = Date()
        keys = drawing.strokes.map { StrokeKey($0) }
        loaded = page
        rev = pageRev
        patchBase = pageRev
        pendingRect = nil
        dirty = false

        canvas.drawing = drawing
        canvas.undoManager?.removeAllActions()
        canvas.drawingGestureRecognizer.isEnabled = true
        paper.kind = wantedPaper
        paper.isHidden = false
        spinner.stopAnimating()
        geometryChanged()
        scroll(toTop: 0)
        refresh()
        sendView()

        if needsUpload {
            dirty = true
            scheduleSave(0.3)
        }
    }

    // MARK: 필기가 바뀜

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard loaded != nil else { return }
        let newKeys = canvasView.drawing.strokes.map { StrokeKey($0) }
        var rect: CGRect
        if let changed = StrokeKey.changedRect(old: keys, new: newKeys) {
            rect = changed
        } else {
            // 달라진 획이 없다: 페이지를 막 불러와서 온 알림이면 무시하고, 아니면 안전하게 전체를 다시 보낸다.
            if Date().timeIntervalSince(lastLoad) < 0.7 { return }
            rect = Page.rect
        }
        if rect.isNull || rect.isInfinite { rect = Page.rect }

        keys = newKeys
        rev += 1
        dirty = true
        scheduleSave(1.5)
        queuePatch(rect)
    }

    private func queuePatch(_ rect: CGRect) {
        pendingRect = pendingRect.map { $0.union(rect) } ?? rect
        pumpPatch()
    }

    /// 달라진 영역을 그림으로 만들어 보낸다. 한 번에 하나씩만 만들고, 그 사이에 쌓인 변경은 합쳐서 다음에 보낸다.
    private func pumpPatch() {
        guard !patchBusy, let rect = pendingRect, let page = loaded else { return }
        pendingRect = nil
        guard link.status == .connected else {
            // 연결이 없으면 보내지 않는다. 다시 연결되면 전체 저장으로 맞춰진다.
            return
        }
        patchBusy = true
        let drawing = canvas.drawing
        let patchRev = rev
        let base = patchBase
        patchBase = patchRev
        let area = rect.insetBy(dx: -6, dy: -6).intersection(Page.rect).integral
        let scale = Page.imageScale

        renderQueue.async { [weak self] in
            let visible = !area.isNull && area.width >= 1 && area.height >= 1
            let box = visible ? area : CGRect.zero
            let png = visible ? (Render.png(drawing, in: area, scale: scale)?.base64EncodedString() ?? "") : ""
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.patchBusy = false
                self.link.send([
                    "t": "patch",
                    "note": page.note,
                    "page": page.page,
                    "rev": patchRev,
                    "base": base,
                    "x": Int(box.minX),
                    "y": Int(box.minY),
                    "w": Int(box.width),
                    "h": Int(box.height),
                    "png": png,
                ])
                self.pumpPatch()
            }
        }
    }

    // MARK: 전체 저장

    private func scheduleSave(_ delay: TimeInterval) {
        saveTimer?.invalidate()
        saveTimer = after(delay) { [weak self] in self?.saveNow() }
    }

    /// 지금 페이지 전체를 노트북에 올린다. 연결이 없으면 아이패드에만 보관해 둔다.
    private func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard dirty, let page = loaded else { return }
        if saving {
            scheduleSave(0.5)
            return
        }

        let drawing = canvas.drawing
        let saveRev = rev
        let online = link.status == .connected
        let imageScale = Page.imageScale
        let thumbScale = Page.thumbScale
        if online {
            dirty = false
            saving = true
        }

        renderQueue.async { [weak self] in
            let data = drawing.dataRepresentation()
            LocalCache.write(data, page: page, rev: saveRev)
            guard online else { return }

            let image = Render.png(drawing, in: Page.rect, scale: imageScale) ?? Data()
            let thumb = Render.png(drawing, in: Page.rect, scale: thumbScale) ?? Data()
            var body = data
            body.append(image)
            body.append(thumb)
            let path = "/api/notes/\(page.note)/pages/\(page.page)/save?rev=\(saveRev)&gen=\(page.gen)&dlen=\(data.count)&ilen=\(image.count)"

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.link.request("PUT", path, body: body) { _, response in
                    self.saving = false
                    let status = response?.statusCode ?? 0
                    let current = self.loaded == page && self.rev == saveRev
                    if status == 200 || status == 404 || status == 409 {
                        // 올라갔거나, 노트북에서 그 페이지가 지워졌거나 비워졌다. 어느 쪽이든 보관본은 필요 없다.
                        // (그 사이에 더 쓴 게 있으면 보관본은 다음 저장 때 정리된다)
                        if current || self.loaded != page { LocalCache.remove(page) }
                    } else if current {
                        // 실패: 그 뒤로 바뀐 게 없으면 다시 올려야 한다.
                        self.dirty = true
                        if self.link.status == .connected { self.scheduleSave(3) }
                    }
                }
            }
        }
    }

    // MARK: 쓰는 중인 획

    @objc private func drawingGesture(_ gesture: UIGestureRecognizer) {
        guard loaded != nil, link.status == .connected else { return }
        let zoom = canvas.zoomScale
        guard zoom > 0 else { return }
        let point = gesture.location(in: canvas)
        let x = num(point.x / zoom)
        let y = num(point.y / zoom)

        switch gesture.state {
        case .began:
            strokeId += 1
            livePoints = [x, y]
            sendLive("begin")
        case .changed:
            livePoints.append(x)
            livePoints.append(y)
            if CACurrentMediaTime() - lastLiveSend > 0.03 { sendLive("move") }
        case .ended, .cancelled, .failed:
            sendLive("end")
        default:
            break
        }
    }

    private func sendLive(_ phase: String) {
        guard let page = loaded else { return }
        var tool = "pen"
        var color = "#000000"
        var width = 3.0
        if let ink = canvas.tool as? PKInkingTool {
            if ink.inkType == .marker {
                tool = "marker"
            } else if ink.inkType == .pencil {
                tool = "pencil"
            }
            color = ink.color.hexString
            width = num(ink.width)
        } else if canvas.tool is PKEraserTool {
            tool = "eraser"
        } else if canvas.tool is PKLassoTool {
            tool = "lasso"
        }
        link.send([
            "t": "live",
            "note": page.note,
            "page": page.page,
            "sid": strokeId,
            "phase": phase,
            "tool": tool,
            "color": color,
            "width": width,
            "pts": livePoints,
        ])
        livePoints.removeAll(keepingCapacity: true)
        lastLiveSend = CACurrentMediaTime()
    }

    // MARK: 스크롤 / 확대

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        syncPaper()
        sendViewSoon()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        geometryChanged()
    }

    /// 확대 배율이 바뀌었을 때 내용 크기와 여백을 다시 맞춘다. 페이지가 화면보다 작으면 가운데에 둔다.
    private func geometryChanged() {
        let zoom = canvas.zoomScale
        let content = CGSize(width: Page.width * zoom, height: Page.height * zoom)
        if canvas.contentSize != content { canvas.contentSize = content }

        let size = stage.bounds.size
        let insetX = max(Self.margin, (size.width - content.width) / 2)
        let insetY = max(Self.margin, (size.height - content.height) / 2)
        let inset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        if canvas.contentInset != inset { canvas.contentInset = inset }

        syncPaper()
        sendViewSoon()
    }

    private func syncPaper() {
        let zoom = canvas.zoomScale
        let offset = canvas.contentOffset
        paper.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        paper.center = CGPoint(x: Page.width * zoom / 2 - offset.x, y: Page.height * zoom / 2 - offset.y)
    }

    /// 페이지의 세로 위치 top(페이지 좌표)이 화면 맨 위에 오도록 스크롤한다.
    private func scroll(toTop top: CGFloat) {
        let zoom = canvas.zoomScale
        let inset = canvas.contentInset
        let maxY = max(-inset.top, canvas.contentSize.height + inset.bottom - stage.bounds.height)
        let y = min(max(top * zoom - inset.top, -inset.top), maxY)
        canvas.contentOffset = CGPoint(x: -inset.left, y: y)
        syncPaper()
    }

    /// 지금 보고 있는 영역을 노트북에 알린다. (노트북의 "아이패드 화면" 보기가 이걸 따라간다)
    private func sendViewSoon() {
        if CACurrentMediaTime() - lastViewSend > 0.06 {
            sendView()
        } else if viewTimer == nil {
            viewTimer = after(0.08) { [weak self] in
                self?.viewTimer = nil
                self?.sendView()
            }
        }
    }

    private func sendView() {
        guard loaded != nil, link.status == .connected else { return }
        let zoom = canvas.zoomScale
        let size = stage.bounds.size
        guard zoom > 0, size.width > 0, size.height > 0 else { return }
        lastViewSend = CACurrentMediaTime()
        let offset = canvas.contentOffset
        link.send([
            "t": "view",
            "x": num(offset.x / zoom),
            "y": num(offset.y / zoom),
            "w": num(size.width / zoom),
            "h": num(size.height / zoom),
        ])
    }

    // MARK: 밝은 화면 / 어두운 화면

    /// 어두운 화면에서는 PencilKit이 잉크의 밝기를 뒤집어 보여 준다(검정 → 흰색). 저장되는 필기와 노트북으로 보내는 그림은 그대로다.
    private func applyTheme() {
        let style = Theme.style
        view.window?.overrideUserInterfaceStyle = style
        toolPicker.overrideUserInterfaceStyle = style
        toolPicker.colorUserInterfaceStyle = style
        paper.dark = Theme.isDark
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        themeButton.setImage(UIImage(systemName: Theme.isDark ? "moon.fill" : "moon", withConfiguration: config), for: .normal)
        themeButton.accessibilityLabel = Theme.isDark ? "밝은 화면으로" : "어두운 화면으로"
    }

    @objc private func themeTapped() {
        Theme.isDark.toggle()
        applyTheme()
    }

    // MARK: 버튼

    @objc private func showConnect() {
        guard presentedViewController == nil else { return }
        let sheet = ConnectViewController(link: link)
        sheet.onClose = { [weak self] in
            self?.canvas.becomeFirstResponder()
        }
        present(sheet, animated: true)
    }

    @objc private func undoTapped() {
        canvas.undoManager?.undo()
    }

    @objc private func redoTapped() {
        canvas.undoManager?.redo()
    }

    @objc private func prevTapped() {
        link.send(["t": "cmd", "cmd": "prev"])
    }

    @objc private func nextTapped() {
        link.send(["t": "cmd", "cmd": "next"])
    }

    @objc private func addTapped() {
        link.send(["t": "cmd", "cmd": "add"])
    }

    // MARK: 앱이 앞/뒤로 갈 때

    @objc private func appBecameActive() {
        link.wake()
    }

    @objc private func appWillResign() {
        guard dirty else { return }
        // 홈으로 나가도 올리던 것을 마칠 수 있게 잠깐 시간을 얻는다.
        let app = UIApplication.shared
        let token = app.beginBackgroundTask(expirationHandler: nil)
        saveNow()
        after(6) {
            app.endBackgroundTask(token)
        }
    }
}
