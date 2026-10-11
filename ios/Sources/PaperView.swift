import UIKit

/// 필기 아래에 깔리는 종이. 크기는 항상 페이지 크기 그대로 두고, 확대/축소는 transform으로 한다.
/// 무늬의 위치는 노트북 화면(pc/public/app.js의 drawPaper)과 같아야 한다.
final class PaperView: UIView {
    var kind: String = "plain" {
        didSet {
            if kind != oldValue { setNeedsDisplay() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        isUserInteractionEnabled = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 7
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowPath = UIBezierPath(rect: Page.rect).cgPath
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(bounds)

        switch kind {
        case "ruled":
            ctx.setStrokeColor(UIColor(red: 70 / 255, green: 110 / 255, blue: 170 / 255, alpha: 0.30).cgColor)
            ctx.setLineWidth(1)
            var y: CGFloat = 132
            while y <= Page.height - 44 {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: Page.width, y: y))
                y += 44
            }
            ctx.strokePath()

        case "grid":
            ctx.setStrokeColor(UIColor(red: 70 / 255, green: 110 / 255, blue: 170 / 255, alpha: 0.22).cgColor)
            ctx.setLineWidth(1)
            var y: CGFloat = 32
            while y < Page.height {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: Page.width, y: y))
                y += 32
            }
            var x: CGFloat = 32
            while x < Page.width {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: Page.height))
                x += 32
            }
            ctx.strokePath()

        case "dot":
            ctx.setFillColor(UIColor(red: 60 / 255, green: 80 / 255, blue: 110 / 255, alpha: 0.40).cgColor)
            var y: CGFloat = 32
            while y < Page.height {
                var x: CGFloat = 32
                while x < Page.width {
                    ctx.fillEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
                    x += 32
                }
                y += 32
            }

        default:
            break
        }
    }
}
