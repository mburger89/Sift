import MetalUI
import MetalUITesting
import SiftCore
import SiftKit
import Testing

extension TestWindow {
    /// The centre of an element's frame, in window points.
    func centre(of element: TestElement) -> Point<Pixels> {
        Point(x: element.frame.origin.x + element.frame.size.width / 2, y: element.frame.origin.y + element.frame.size.height / 2)
    }

    /// The sidebar row for a node token (`sidebar.<token>`).
    func sidebarRow(_ token: String) throws -> TestElement { try element(identifier: "sidebar.\(token)") }

    /// Clicks a sidebar row's chevron to expand or collapse it, then lets the 245 ms splice animation finish
    /// (it keeps the display link drawing until the clock passes it, so a frame count taken before would be
    /// the animation's). A label sits at x 25 + 12 per level (a chevron cell
    /// 13 wide at 12 + 12 per level, OG-J), so the depth follows from where the label is.
    func toggleRow(_ token: String) throws {
        let label = try sidebarRow(token)
        let depth = ((label.frame.origin.x.value - 25) / 12).rounded()
        click(at: Point(x: Pixels(12 + 12 * depth + 6), y: label.frame.origin.y + label.frame.size.height / 2))
        advance(by: 1)
    }

    /// Whether a sidebar row exists (a collapsed group's children do not).
    func hasRow(_ token: String) -> Bool { (try? sidebarRow(token)) != nil }

    /// Every element whose label, value or identifier contains `text`: for "this text appears nowhere".
    func elementsContaining(_ text: String) throws -> [TestElement] {
        try elements { element in
            [element.label, element.value, element.identifier].contains { $0?.contains(text) == true }
        }
    }
}
