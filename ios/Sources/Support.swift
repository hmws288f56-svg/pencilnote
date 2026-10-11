import UIKit
import PencilKit

/// 페이지 크기(포인트). 노트북 화면(pc/public/app.js)의 PAGE_W / PAGE_H 와 같아야 한다.
enum Page {
    static let width: CGFloat = 1024
    static let height: CGFloat = 1448
    static let rect = CGRect(x: 0, y: 0, width: width, height: height)
    /// 노트북으로 보내는 이미지의 해상도 배율
    static let imageScale: CGFloat = 2
    static let thumbScale: CGFloat = 0.25
}

/// 노트북이 정해 주는 페이지. gen은 노트북에서 "비우기"를 할 때마다 올라간다.
struct PageRef: Equatable {
    let note: String
    let page: String
    let gen: Int
}

/// JSON에 넣을 수 있는 숫자로 바꾼다. (NaN/무한대가 들어가면 JSONSerialization이 앱을 죽인다)
func num(_ value: CGFloat) -> Double {
    guard value.isFinite else { return 0 }
    return Double((value * 10).rounded() / 10)
}

/// 스크롤 중에도 울리는 일회용 타이머
@discardableResult
func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) -> Timer {
    let timer = Timer(timeInterval: seconds, repeats: false) { _ in block() }
    RunLoop.main.add(timer, forMode: .common)
    return timer
}

extension UIColor {
    /// 밝은 화면 기준의 "#rrggbb"
    var hexString: String {
        let color = resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#000000" }
        func byte(_ v: CGFloat) -> Int {
            guard v.isFinite else { return 0 }
            return Int((min(max(v, 0), 1) * 255).rounded())
        }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }
}

/// 획 하나를 구분하는 값. 필기가 바뀌었을 때 "어느 부분이 달라졌는지" 찾는 데 쓴다.
struct StrokeKey: Hashable {
    private let date: Date
    private let points: Int
    private let ink: String
    private let color: String
    private let x: Int
    private let y: Int
    private let w: Int
    private let h: Int
    private let extra: Int

    init(_ stroke: PKStroke) {
        date = stroke.path.creationDate
        points = stroke.path.count
        ink = stroke.ink.inkType.rawValue
        color = stroke.ink.color.hexString

        let b = stroke.renderBounds
        if b.isNull || b.isInfinite {
            x = 0
            y = 0
            w = 0
            h = 0
        } else {
            x = Self.q(b.minX)
            y = Self.q(b.minY)
            w = Self.q(b.width)
            h = Self.q(b.height)
        }

        // 지우개로 일부만 지웠거나 올가미로 옮긴 경우도 다른 획으로 본다.
        var e = stroke.maskedPathRanges.count
        if let mask = stroke.mask {
            let mb = mask.bounds
            e = e &* 31 &+ Self.q(mb.minX)
            e = e &* 31 &+ Self.q(mb.minY)
            e = e &* 31 &+ Self.q(mb.width)
            e = e &* 31 &+ Self.q(mb.height)
            e = e &+ 1
        }
        let t = stroke.transform
        e = e &* 31 &+ Self.q(t.tx)
        e = e &* 31 &+ Self.q(t.ty)
        e = e &* 31 &+ Self.q(t.a * 100)
        e = e &* 31 &+ Self.q(t.b * 100)
        extra = e
    }

    /// 화면에서 이 획이 차지하는 영역 (없으면 .null)
    var rect: CGRect {
        if w == 0 && h == 0 { return .null }
        return CGRect(x: CGFloat(x) / 4, y: CGFloat(y) / 4, width: CGFloat(w) / 4, height: CGFloat(h) / 4)
    }

    private static func q(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 0 }
        return Int((min(max(value, -1_000_000), 1_000_000) * 4).rounded())
    }

    /// 이전 필기와 지금 필기를 비교해서 다시 그려야 하는 영역을 구한다. 달라진 게 없으면 nil.
    static func changedRect(old: [StrokeKey], new: [StrokeKey]) -> CGRect? {
        var start = 0
        let common = min(old.count, new.count)
        while start < common && old[start] == new[start] { start += 1 }
        if start == old.count && start == new.count { return nil }

        let oldRest = old[start...]
        let newRest = new[start...]
        let oldSet = Set(oldRest)
        let newSet = Set(newRest)
        var rect = CGRect.null
        for key in oldRest where !newSet.contains(key) { rect = rect.union(key.rect) }
        for key in newRest where !oldSet.contains(key) { rect = rect.union(key.rect) }
        if rect.isNull {
            // 획은 같은데 순서만 바뀐 경우: 바뀐 구간 전체
            for key in newRest { rect = rect.union(key.rect) }
        }
        return rect
    }
}

enum Render {
    /// 필기의 일부(또는 전체)를 배경이 투명한 PNG로 만든다. 백그라운드에서 불러도 된다.
    static func png(_ drawing: PKDrawing, in rect: CGRect, scale: CGFloat) -> Data? {
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: rect, scale: scale)
        }
        return image?.pngData()
    }
}

/// 아직 노트북에 올리지 못한 필기를 아이패드에 잠시 보관한다. (연결이 끊긴 채 앱이 꺼져도 잃지 않도록)
enum LocalCache {
    private static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("unsaved", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func url(_ page: PageRef) -> URL {
        folder.appendingPathComponent("\(page.note)_\(page.page)_\(page.gen).drawing")
    }

    /// 파일 = "버전번호\n" + 필기 데이터
    static func write(_ drawing: Data, page: PageRef, rev: Int) {
        var out = Data("\(rev)\n".utf8)
        out.append(drawing)
        try? out.write(to: url(page), options: .atomic)
    }

    static func read(_ page: PageRef) -> (rev: Int, drawing: PKDrawing)? {
        guard let raw = try? Data(contentsOf: url(page)),
              let newline = raw.firstIndex(of: 0x0A),
              let rev = Int(String(decoding: raw[raw.startIndex..<newline], as: UTF8.self)),
              let drawing = try? PKDrawing(data: Data(raw[raw.index(after: newline)...]))
        else { return nil }
        return (rev, drawing)
    }

    static func remove(_ page: PageRef) {
        try? FileManager.default.removeItem(at: url(page))
    }
}
