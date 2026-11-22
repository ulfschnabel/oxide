import CoreGraphics
import Testing

@testable import OxideKit

struct ViewportTests {
    // A landscape picture on a portrait phone: letterboxed top and bottom.
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
    let video = CGSize(width: 1920, height: 1080)
    let display = DisplayRect(x: 0, y: 0, width: 1920, height: 1080)
    var fitted: CGRect { ViewMapping.contentRect(videoSize: video, in: bounds) }

    func host(_ p: CGPoint, _ v: Viewport) -> (Int32, Int32) {
        ViewMapping.hostPoint(p, content: v.rect(fitted: fitted, in: bounds), display: display)
    }

    @Test func startsFitted() {
        let v = Viewport()
        #expect(v.rect(fitted: fitted, in: bounds) == fitted)
        #expect(!v.isZoomed)
    }

    @Test func zoomKeepsThePointUnderTheFingers() {
        var v = Viewport()
        // Vertically centred: at 2× the picture is still shorter than the
        // view, so that axis stays centred rather than anchored.
        let anchor = CGPoint(x: 150, y: 400)
        let before = host(anchor, v)
        v.zoom(by: 2, at: anchor, fitted: fitted, in: bounds)
        #expect(v.scale == 2)
        #expect(host(anchor, v) == before)
        v.zoom(by: 2, at: anchor, fitted: fitted, in: bounds)
        #expect(v.scale == 4)
        #expect(host(anchor, v) == before)
    }

    @Test func zoomStaysBetweenOneAndFour() {
        var v = Viewport()
        v.zoom(by: 10, at: CGPoint(x: 200, y: 400), fitted: fitted, in: bounds)
        #expect(v.scale == Viewport.maxScale)
        v.zoom(by: 0.01, at: CGPoint(x: 200, y: 400), fitted: fitted, in: bounds)
        #expect(v.scale == 1)
        #expect(v.rect(fitted: fitted, in: bounds) == fitted)
    }

    @Test func panStopsAtThePicturesEdges() {
        var v = Viewport()
        v.zoom(by: 4, at: CGPoint(x: 200, y: 400), fitted: fitted, in: bounds)
        v.pan(by: CGPoint(x: 10_000, y: 10_000), fitted: fitted, in: bounds)
        var r = v.rect(fitted: fitted, in: bounds)
        #expect(r.minX == bounds.minX)
        #expect(r.minY == bounds.minY)
        v.pan(by: CGPoint(x: -100_000, y: -100_000), fitted: fitted, in: bounds)
        r = v.rect(fitted: fitted, in: bounds)
        #expect(r.maxX == bounds.maxX)
        #expect(r.maxY == bounds.maxY)
    }

    @Test func aPictureSmallerThanTheViewStaysCentred() {
        var v = Viewport()
        // 2× of a 400×225 picture is 800×450: wider than the view, not taller.
        v.zoom(by: 2, at: CGPoint(x: 200, y: 400), fitted: fitted, in: bounds)
        v.pan(by: CGPoint(x: 0, y: 300), fitted: fitted, in: bounds)
        let r = v.rect(fitted: fitted, in: bounds)
        #expect(r.height == fitted.height * 2)
        #expect(abs(r.midY - bounds.midY) < 0.001)
    }

    @Test func panMovesThePicture() {
        var v = Viewport()
        v.zoom(by: 2, at: CGPoint(x: 200, y: 400), fitted: fitted, in: bounds)
        let before = v.rect(fitted: fitted, in: bounds)
        v.pan(by: CGPoint(x: 30, y: 0), fitted: fitted, in: bounds)
        #expect(v.rect(fitted: fitted, in: bounds).minX == before.minX + 30)
    }

    @Test func resetFits() {
        var v = Viewport()
        v.zoom(by: 3, at: CGPoint(x: 10, y: 300), fitted: fitted, in: bounds)
        v.reset()
        #expect(v.rect(fitted: fitted, in: bounds) == fitted)
    }

    @Test func revealBringsAPointIntoView() {
        var v = Viewport()
        v.zoom(by: 4, at: CGPoint(x: 0, y: 400), fitted: fitted, in: bounds)
        // A cursor just off the right edge.
        let r = v.rect(fitted: fitted, in: bounds)
        let off = CGPoint(x: bounds.maxX + 50, y: 400)
        let cursorHost = ViewMapping.hostPoint(off, content: r, display: display)
        v.reveal(off, margin: 20, fitted: fitted, in: bounds)
        let now = ViewMapping.viewPoint(cursorHost, content: v.rect(fitted: fitted, in: bounds), display: display)
        #expect(now.x <= bounds.maxX - 20 + 0.5)
        #expect(now.x >= bounds.maxX - 20 - 0.5)
        // Inside already: nothing moves.
        let still = v
        v.reveal(CGPoint(x: 200, y: 400), margin: 20, fitted: fitted, in: bounds)
        #expect(v == still)
    }

    @Test func keepsWhereItLooksWhenTheViewChanges() {
        var v = Viewport()
        v.zoom(by: 4, at: CGPoint(x: 100, y: 380), fitted: fitted, in: bounds)
        let centre = host(CGPoint(x: bounds.midX, y: bounds.midY), v)
        // Rotated to landscape.
        let wide = CGRect(x: 0, y: 0, width: 800, height: 400)
        let wideFit = ViewMapping.contentRect(videoSize: video, in: wide)
        let r = v.rect(fitted: wideFit, in: wide)
        let now = ViewMapping.hostPoint(CGPoint(x: wide.midX, y: wide.midY), content: r, display: display)
        #expect(abs(Int(now.0) - Int(centre.0)) <= 1)
        #expect(abs(Int(now.1) - Int(centre.1)) <= 1)
    }
}
