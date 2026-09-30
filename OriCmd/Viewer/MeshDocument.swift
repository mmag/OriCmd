import Foundation
import simd

/// A 3D model for the Lister's model view, as the helper service reads it (see
/// MeshParser): the triangles' corners, checked as coming from a stranger — the
/// size must be exactly what the count says, every number finite — with a normal
/// for each triangle and the model's bounds.
nonisolated struct MeshDocument: Sendable {
    /// Three corners a triangle, one after another.
    let positions: [SIMD3<Float>]
    /// The triangle's normal, once for each of its corners.
    let normals: [SIMD3<Float>]
    let minimum: SIMD3<Float>
    let maximum: SIMD3<Float>

    var triangleCount: Int { positions.count / 3 }

    private static let maxTriangles = 4_000_000

    init?(_ data: Data) {
        guard data.count >= 8, data.starts(with: Array("OMS1".utf8)) else { return nil }
        let count = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))) }
        guard count > 0, count <= Self.maxTriangles, data.count == 8 + count * 36 else { return nil }
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(count * 3)
        let finite = data.withUnsafeBytes { raw -> Bool in
            for corner in 0..<(count * 3) {
                let base = 8 + corner * 12
                func value(_ index: Int) -> Float {
                    Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: base + index * 4, as: UInt32.self)))
                }
                let point = SIMD3(value(0), value(1), value(2))
                guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return false }
                positions.append(point)
            }
            return true
        }
        guard finite else { return nil }
        var normals: [SIMD3<Float>] = []
        normals.reserveCapacity(positions.count)
        var minimum = positions[0], maximum = positions[0]
        for triangle in 0..<count {
            let a = positions[triangle * 3], b = positions[triangle * 3 + 1], c = positions[triangle * 3 + 2]
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            // Degenerate triangles (and ones too large for Float) get any normal.
            let normal = length.isFinite && length > 0 ? cross / length : SIMD3<Float>(0, 0, 1)
            normals.append(normal)
            normals.append(normal)
            normals.append(normal)
            minimum = simd_min(minimum, simd_min(a, simd_min(b, c)))
            maximum = simd_max(maximum, simd_max(a, simd_max(b, c)))
        }
        guard (maximum - minimum).x.isFinite, (maximum - minimum).y.isFinite, (maximum - minimum).z.isFinite
        else { return nil }
        self.positions = positions
        self.normals = normals
        self.minimum = minimum
        self.maximum = maximum
    }
}
