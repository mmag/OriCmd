import Foundation
import simd

/// A 3D model for the Lister's model view, as the helper service reads it (see
/// MeshParser): the triangles' corners, checked as coming from a stranger — the
/// size must be exactly what the count says, every number finite — centered and
/// brought to one size (reckoned in Double: corners near Float's limits would
/// overflow), with a normal for each triangle and the model's real size.
nonisolated struct MeshDocument: Sendable {
    /// Three corners a triangle, one after another, within a sphere of radius 1.
    let positions: [SIMD3<Float>]
    /// The triangle's normal, once for each of its corners.
    let normals: [SIMD3<Float>]
    /// Width, depth and height in the file's units.
    let size: SIMD3<Double>

    var triangleCount: Int { positions.count / 3 }

    private static let maxTriangles = 4_000_000

    init?(_ data: Data) {
        guard data.count >= 8, data.starts(with: Array("OMS1".utf8)) else { return nil }
        let count = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))) }
        guard count > 0, count <= Self.maxTriangles, data.count == 8 + count * 36 else { return nil }
        var corners: [SIMD3<Double>] = []
        corners.reserveCapacity(count * 3)
        let finite = data.withUnsafeBytes { raw -> Bool in
            for corner in 0..<(count * 3) {
                let base = 8 + corner * 12
                func value(_ index: Int) -> Double {
                    Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: base + index * 4,
                                                                                     as: UInt32.self))))
                }
                let point = SIMD3(value(0), value(1), value(2))
                guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return false }
                corners.append(point)
            }
            return true
        }
        guard finite else { return nil }
        var minimum = corners[0], maximum = corners[0]
        for corner in corners {
            minimum = simd_min(minimum, corner)
            maximum = simd_max(maximum, corner)
        }
        let center = (minimum + maximum) / 2
        let radius = simd_length(maximum - minimum) / 2
        let scale = radius > 0 ? 1 / radius : 1
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        positions.reserveCapacity(corners.count)
        normals.reserveCapacity(corners.count)
        for triangle in 0..<count {
            let a = (corners[triangle * 3] - center) * scale
            let b = (corners[triangle * 3 + 1] - center) * scale
            let c = (corners[triangle * 3 + 2] - center) * scale
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            // Degenerate triangles get any normal.
            let normal = length > 0 ? SIMD3<Float>(cross / length) : SIMD3<Float>(0, 0, 1)
            positions += [SIMD3<Float>(a), SIMD3<Float>(b), SIMD3<Float>(c)]
            normals.append(normal)
            normals.append(normal)
            normals.append(normal)
        }
        self.positions = positions
        self.normals = normals
        self.size = maximum - minimum
    }
}
