import Foundation

/// Line-by-line comparison of two texts (or of two hex dumps), aligned for a
/// side-by-side view: equal lines face each other, removed and added lines
/// face a gap, and a removal next to an addition is shown as a change.
nonisolated enum TextDiff {
    enum Kind: Sendable {
        case same, changed, leftOnly, rightOnly
    }

    struct Row: Sendable {
        /// Line indices on each side (nil for a gap).
        let left: Int?
        let right: Int?
        let kind: Kind
    }

    /// Above this many surely-different lines the alignment would be too slow;
    /// lines are then compared by position.
    private static let alignmentLimit = 20_000
    /// Longer stretches are first split at lines that occur once on each side
    /// (patience diff); the full diff runs on the pieces between them.
    private static let directDiffLimit = 6_000

    static func lines(of text: String) -> [Substring] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.count > 1, lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    /// Aligned rows for `left` and `right`; with `ignoringWhitespace`, lines that
    /// differ only in spaces and tabs count as equal.
    static func rows(_ left: [Substring], _ right: [Substring], ignoringWhitespace: Bool) -> [Row] {
        let a = ignoringWhitespace ? left.map(withoutWhitespace) : left.map(String.init)
        let b = ignoringWhitespace ? right.map(withoutWhitespace) : right.map(String.init)

        // Common head and tail need no diff.
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        let middleA = a[head..<(a.count - tail)]
        let middleB = b[head..<(b.count - tail)]

        var rows: [Row] = (0..<head).map { Row(left: $0, right: $0, kind: .same) }
        if lowerBoundOfDifferences(middleA, middleB) > alignmentLimit {
            rows += positional(middleA, middleB)
        } else {
            rows += aligned(middleA, middleB)
        }
        rows += (0..<tail).map { Row(left: a.count - tail + $0, right: b.count - tail + $0, kind: .same) }
        return rows
    }

    /// Hex dump rows compared by position: line `k` of one file faces line `k` of the other.
    static func binaryRows(_ left: Data, _ right: Data, bytesPerLine: Int) -> [Row] {
        let leftLines = (left.count + bytesPerLine - 1) / bytesPerLine
        let rightLines = (right.count + bytesPerLine - 1) / bytesPerLine
        var rows: [Row] = []
        rows.reserveCapacity(max(leftLines, rightLines))
        left.withUnsafeBytes { a in
            right.withUnsafeBytes { b in
                for line in 0..<max(leftLines, rightLines) {
                    let start = line * bytesPerLine
                    if line >= leftLines {
                        rows.append(Row(left: nil, right: line, kind: .rightOnly))
                    } else if line >= rightLines {
                        rows.append(Row(left: line, right: nil, kind: .leftOnly))
                    } else {
                        let lengthA = min(bytesPerLine, a.count - start)
                        let lengthB = min(bytesPerLine, b.count - start)
                        let same = lengthA == lengthB
                            && memcmp(a.baseAddress! + start, b.baseAddress! + start, lengthA) == 0
                        rows.append(Row(left: line, right: line, kind: same ? .same : .changed))
                    }
                }
            }
        }
        return rows
    }

    /// Where the rows of the differing blocks start.
    static func blockStarts(_ rows: [Row]) -> [Int] {
        rows.indices.filter { index in
            rows[index].kind != .same && (index == 0 || rows[index - 1].kind == .same)
        }
    }

    /// The differing middle of two lines (after their common prefix and suffix),
    /// as UTF-16 ranges for highlighting.
    static func changedRanges(_ left: String, _ right: String) -> (NSRange, NSRange) {
        let a = Array(left.utf16)
        let b = Array(right.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        return (NSRange(location: prefix, length: a.count - prefix - suffix),
                NSRange(location: prefix, length: b.count - prefix - suffix))
    }

    private static func withoutWhitespace(_ line: Substring) -> String {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// Lines that occur more often on one side than on the other: the diff has at
    /// least this many edits.
    private static func lowerBoundOfDifferences(_ a: ArraySlice<String>, _ b: ArraySlice<String>) -> Int {
        var counts: [String: Int] = [:]
        for line in a { counts[line, default: 0] += 1 }
        for line in b { counts[line, default: 0] -= 1 }
        return counts.values.reduce(0) { $0 + abs($1) }
    }

    private static func aligned(_ a: ArraySlice<String>, _ b: ArraySlice<String>) -> [Row] {
        guard a.count + b.count > directDiffLimit else { return diffed(a, b) }
        let anchors = uniqueAnchors(a, b)
        guard !anchors.isEmpty else { return positional(a, b) }
        var rows: [Row] = []
        var (i, j) = (a.startIndex, b.startIndex)
        for (anchorA, anchorB) in anchors {
            rows += aligned(a[i..<anchorA], b[j..<anchorB])
            rows.append(Row(left: anchorA, right: anchorB, kind: .same))
            (i, j) = (anchorA + 1, anchorB + 1)
        }
        rows += aligned(a[i...], b[j...])
        return rows
    }

    /// Pairs of equal lines that occur exactly once on each side, the longest
    /// chain of them in the same order on both sides.
    private static func uniqueAnchors(_ a: ArraySlice<String>, _ b: ArraySlice<String>) -> [(Int, Int)] {
        var counts: [String: (a: Int, b: Int, indexB: Int)] = [:]
        for line in a { counts[line, default: (0, 0, 0)].a += 1 }
        for index in b.indices {
            counts[b[index], default: (0, 0, 0)].b += 1
            counts[b[index]]?.indexB = index
        }
        let pairs = a.indices.compactMap { index -> (Int, Int)? in
            guard let count = counts[a[index]], count.a == 1, count.b == 1 else { return nil }
            return (index, count.indexB)
        }
        // Longest increasing subsequence of the positions in `b` (patience sorting).
        var pileTops: [Int] = []
        var previous = [Int](repeating: -1, count: pairs.count)
        for (index, pair) in pairs.enumerated() {
            var low = 0
            var high = pileTops.count
            while low < high {
                let middle = (low + high) / 2
                if pairs[pileTops[middle]].1 < pair.1 { low = middle + 1 } else { high = middle }
            }
            if low > 0 { previous[index] = pileTops[low - 1] }
            if low == pileTops.count { pileTops.append(index) } else { pileTops[low] = index }
        }
        var chain: [(Int, Int)] = []
        var index = pileTops.last ?? -1
        while index >= 0 {
            chain.append(pairs[index])
            index = previous[index]
        }
        return chain.reversed()
    }

    private static func diffed(_ a: ArraySlice<String>, _ b: ArraySlice<String>) -> [Row] {
        let difference = Array(b).difference(from: Array(a))
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var rows: [Row] = []
        var i = 0
        var j = 0
        let baseA = a.startIndex
        let baseB = b.startIndex
        while i < a.count || j < b.count {
            let isRemoved = i < a.count && removed.contains(i)
            let isInserted = j < b.count && inserted.contains(j)
            if isRemoved && isInserted {
                rows.append(Row(left: baseA + i, right: baseB + j, kind: .changed))
                i += 1
                j += 1
            } else if isRemoved {
                rows.append(Row(left: baseA + i, right: nil, kind: .leftOnly))
                i += 1
            } else if isInserted {
                rows.append(Row(left: nil, right: baseB + j, kind: .rightOnly))
                j += 1
            } else if i < a.count, j < b.count {
                rows.append(Row(left: baseA + i, right: baseB + j, kind: .same))
                i += 1
                j += 1
            } else if i < a.count {
                rows.append(Row(left: baseA + i, right: nil, kind: .leftOnly))
                i += 1
            } else {
                rows.append(Row(left: nil, right: baseB + j, kind: .rightOnly))
                j += 1
            }
        }
        return rows
    }

    private static func positional(_ a: ArraySlice<String>, _ b: ArraySlice<String>) -> [Row] {
        (0..<max(a.count, b.count)).map { offset in
            let left = offset < a.count ? a.startIndex + offset : nil
            let right = offset < b.count ? b.startIndex + offset : nil
            let kind: Kind = switch (left, right) {
            case let (left?, right?): a[left] == b[right] ? .same : .changed
            case (_?, nil): .leftOnly
            default: .rightOnly
            }
            return Row(left: left, right: right, kind: kind)
        }
    }
}
