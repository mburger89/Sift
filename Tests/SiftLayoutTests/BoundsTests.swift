import Testing

@testable import SiftLayout

@Suite struct BoundsTests {
    @Test(arguments: 0..<100)
    func boundsEncloseEveryNodeAndRoute(seed: Int) {
        let g = randomGraph(seed: UInt64(seed), n: 30, e: 50)
        let result = LayeredLayout.layout(g)
        let box = result.bounds
        var routePoints = 0
        for node in g.nodes {
            let p = result.positions[node.id]!
            #expect(p.x >= box.x && p.y >= box.y)
            #expect(p.x + node.width <= box.x + box.width + 1e-9)
            #expect(p.y + node.height <= box.y + box.height + 1e-9)
        }
        for route in result.routes.values {
            for p in route {
                routePoints += 1
                #expect(p.x >= box.x && p.x <= box.x + box.width + 1e-9)
                #expect(p.y >= box.y && p.y <= box.y + box.height + 1e-9)
            }
        }
        if seed == 0 { #expect(routePoints > 0) }
    }

    @Test func theBoundsAreTightAroundTheNodes() {
        let result = LayeredLayout.layout(graph(3, [(0, 1), (1, 2)]))
        #expect(result.bounds == LayoutRect(x: 0, y: 0, width: 840, height: 100))
        #expect(LayeredLayout.layout(LayoutGraph()).bounds == LayoutRect(x: 0, y: 0, width: 0, height: 0))
    }

    @Test func selfLoopsHaveNoRoute() {
        let result = LayeredLayout.layout(graph(2, [(0, 0), (0, 1), (1, 1)]))
        #expect(result.routes[0] == nil)
        #expect(result.routes[2] == nil)
        #expect(result.routes[1] == [])
        #expect(result.selfLoops == [0, 2])
    }
}
