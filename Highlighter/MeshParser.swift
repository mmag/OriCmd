import Foundation

/// 3D models for the Lister's model view: STL, binary (by its size: 84 bytes and
/// 50 a triangle) or text ("vertex x y z", three a triangle). The reply is plain
/// data: "OMS1", the triangle count (UInt32) and nine Float32 a triangle (three
/// corners), little-endian; corners that are not finite numbers drop their
/// triangle. At most `maxTriangles`; nil when there are none.
enum MeshParser {
    static let maxTriangles = 4_000_000

    static func parse(_ data: Data, format: String) -> Data? {
        guard format == "stl" else { return nil }
        let bytes = [UInt8](data)
        let triangles = isBinarySTL(bytes) ? binarySTL(bytes) : textSTL(bytes)
        guard !triangles.isEmpty else { return nil }
        var output = Data("OMS1".utf8)
        output.reserveCapacity(8 + triangles.count * 4)
        withUnsafeBytes(of: UInt32(triangles.count / 9).littleEndian) { output.append(contentsOf: $0) }
        triangles.withUnsafeBytes { output.append(contentsOf: $0) }
        return output
    }

    /// A binary STL has exactly the size its triangle count says (text STL files
    /// start with "solid", and so do many binary ones).
    private static func isBinarySTL(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 84 else { return false }
        let count = bytes[80..<84].reversed().reduce(0) { $0 << 8 | Int($1) }
        return 84 + count * 50 == bytes.count
    }

    /// Records of 50 bytes: the normal (left out: computed again), three corners, two
    /// bytes of attributes.
    private static func binarySTL(_ bytes: [UInt8]) -> [Float] {
        let count = min((bytes.count - 84) / 50, maxTriangles)
        var triangles: [Float] = []
        triangles.reserveCapacity(count * 9)
        bytes.withUnsafeBytes { raw in
            for index in 0..<count {
                let start = 84 + index * 50 + 12
                var finite = true
                for corner in 0..<9 {
                    let value = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: start + corner * 4,
                                                                                          as: UInt32.self)))
                    finite = finite && value.isFinite
                    triangles.append(value)
                }
                if !finite { triangles.removeLast(9) }
            }
        }
        return triangles
    }

    /// Every "vertex" followed by three numbers; three make a triangle, whatever
    /// else the file holds.
    private static func textSTL(_ bytes: [UInt8]) -> [Float] {
        var triangles: [Float] = []
        var corner: [Float] = []
        let keyword = Array("vertex".utf8)
        // Terminated, so that strtod always stops inside the buffer.
        let text = bytes + [0]
        text.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var index = 0
            while index + keyword.count < bytes.count, triangles.count < maxTriangles * 9 {
                // "vertex" (any case) as a word of its own.
                guard text[index] | 0x20 == keyword[0],
                      (0..<keyword.count).allSatisfy({ text[index + $0] | 0x20 == keyword[$0] }),
                      index == 0 || text[index - 1] <= 0x20 else {
                    index += 1
                    continue
                }
                index += keyword.count
                var numbers: [Float] = []
                for _ in 0..<3 {
                    var end: UnsafeMutablePointer<CChar>?
                    let start = UnsafeMutableRawPointer(mutating: base + index).assumingMemoryBound(to: CChar.self)
                    let value = strtod(start, &end)
                    guard let end, end != start else { break }
                    index = UnsafeRawPointer(end) - UnsafeRawPointer(base)
                    numbers.append(Float(value))
                }
                guard numbers.count == 3 else {
                    corner = []
                    continue
                }
                corner += numbers
                if corner.count == 9 {
                    if corner.allSatisfy(\.isFinite) { triangles += corner }
                    corner = []
                }
            }
        }
        return triangles
    }
}
