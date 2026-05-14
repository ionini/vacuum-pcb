import Foundation

struct Point: Codable, Hashable {
    var x: Double
    var y: Double

    static let zero = Point(x: 0, y: 0)
}

struct Rect: Codable, Hashable {
    var origin: Point
    var size: Size

    var minX: Double { origin.x }
    var minY: Double { origin.y }
    var maxX: Double { origin.x + size.width }
    var maxY: Double { origin.y + size.height }
}

struct Size: Codable, Hashable {
    var width: Double
    var height: Double
}

enum Rotation: String, Codable, CaseIterable {
    case r0, r90, r180, r270

    var radians: Double {
        switch self {
        case .r0: return 0
        case .r90: return .pi / 2
        case .r180: return .pi
        case .r270: return 3 * .pi / 2
        }
    }
}

enum Layer: String, Codable, CaseIterable {
    case top, bottom
}
