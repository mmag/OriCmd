import Foundation

/// Total Commander's Split File / Combine Files: `photos.zip` cut into pieces
/// named `photos.001`, `photos.002`…, with `photos.crc` (the whole name, size and
/// CRC32) beside them; the pieces put together again, checked against that file
/// when it is there.
nonisolated enum FileSplitter {
    /// Cuts `file` into pieces of `pieceSize` bytes in `folder`; returns the pieces.
    @concurrent
    static func split(_ file: URL, pieceSize: Int64, into folder: URL, progress: TransferProgress) async throws -> [URL] {
        guard pieceSize > 0 else { throw TransferError(message: String(localized: "The piece size must be more than 0.")) }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let size = Int64((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0)
        guard size > pieceSize else {
            throw TransferError(message: String(localized: "\u{201C}\(file.lastPathComponent)\u{201D} is not bigger than one piece."))
        }
        let count = Int((size + pieceSize - 1) / pieceSize)
        guard count <= 999 else {
            throw TransferError(message: String(localized: "That would make more than 999 pieces: choose bigger ones."))
        }
        progress.update { $0.totalBytes = size }
        var crc = CRC32()
        var pieces: [URL] = []
        let base = (file.lastPathComponent as NSString).deletingPathExtension
        for index in 1...count {
            let piece = folder.appending(path: base + String(format: ".%03d", index))
            guard FileManager.default.createFile(atPath: piece.path, contents: nil),
                  let output = FileHandle(forWritingAtPath: piece.path) else { throw TransferError.posix(piece.path) }
            defer { try? output.close() }
            pieces.append(piece)
            let pieceBytes = min(pieceSize, size - Int64(index - 1) * pieceSize)
            var left = pieceBytes
            progress.update {
                $0.source = file.path
                $0.target = piece.path
                $0.fileBytes = pieceBytes
                $0.fileDoneBytes = 0
            }
            while left > 0 {
                if progress.isCancelled {
                    pieces.forEach { try? FileManager.default.removeItem(at: $0) }
                    throw CancellationError()
                }
                guard let chunk = try input.read(upToCount: Int(min(left, 1 << 20))), !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
                crc.update(chunk)
                left -= Int64(chunk.count)
                progress.pace(Int64(chunk.count))
                progress.update {
                    $0.doneBytes += Int64(chunk.count)
                    $0.fileDoneBytes += Int64(chunk.count)
                }
            }
        }
        let summary = "filename=\(file.lastPathComponent)\r\nsize=\(size)\r\ncrc32=\(String(format: "%08X", crc.value))\r\n"
        try summary.write(to: folder.appending(path: base + ".crc"), atomically: true, encoding: .utf8)
        return pieces
    }

    /// The name the pieces share ("photos.001" → "photos"), when `piece` is one.
    static func baseName(of piece: URL) -> String? {
        let ext = piece.pathExtension
        guard ext.count == 3, ext.allSatisfy(\.isNumber) else { return nil }
        return piece.deletingPathExtension().lastPathComponent
    }

    /// The name the pieces starting with `first` make: the one the `.crc` file
    /// beside them gives, or theirs.
    static func combinedName(of first: URL) -> String? {
        guard let base = baseName(of: first) else { return nil }
        let crcURL = first.deletingLastPathComponent().appending(path: base + ".crc")
        guard let text = try? String(contentsOf: crcURL, encoding: .utf8) else { return base }
        let name = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.split(separator: "=", maxSplits: 1)
            return parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "filename"
                ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        }.first
        return name.flatMap { $0.isEmpty || $0.contains("/") ? nil : $0 } ?? base
    }

    /// Puts the pieces starting with `first` (`name.001`) together in `folder`,
    /// under the name the `.crc` file beside them gives (checking the size and
    /// CRC32), or as `name` without one. Returns the file made.
    @concurrent
    static func combine(_ first: URL, into folder: URL, progress: TransferProgress) async throws -> URL {
        guard let base = baseName(of: first) else {
            throw TransferError(message: String(localized: "Choose the first piece (a name ending in .001)."))
        }
        let source = first.deletingLastPathComponent()
        var name = base
        var pieces: [URL] = []
        while true {
            let piece = source.appending(path: base + String(format: ".%03d", pieces.count + 1))
            guard FileManager.default.fileExists(atPath: piece.path) else { break }
            pieces.append(piece)
        }
        guard !pieces.isEmpty else { throw TransferError.posix(first.path) }
        let crcURL = source.appending(path: base + ".crc")
        let crcFile: URL? = FileManager.default.fileExists(atPath: crcURL.path) ? crcURL : nil
        var expected: (size: Int64, crc: UInt32)?
        if let crcFile, let text = try? String(contentsOf: crcFile, encoding: .utf8) {
            var fields: [String: String] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { fields[parts[0].lowercased()] = parts[1] }
            }
            if let original = fields["filename"], !original.isEmpty, !original.contains("/") { name = original }
            if let size = fields["size"].flatMap(Int64.init), let crc = fields["crc32"].flatMap({ UInt32($0, radix: 16) }) {
                expected = (size, crc)
            }
        }
        let total = pieces.reduce(Int64(0)) { sum, piece in
            sum + Int64((try? FileManager.default.attributesOfItem(atPath: piece.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        progress.update { $0.totalBytes = total }
        let target = folder.appending(path: name)
        let partial = folder.appending(path: ".oricmd-\(UUID().uuidString.prefix(12)).part")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil),
              let output = FileHandle(forWritingAtPath: partial.path) else { throw TransferError.posix(partial.path) }
        var crc = CRC32()
        var written: Int64 = 0
        do {
            defer { try? output.close() }
            for piece in pieces {
                let input = try FileHandle(forReadingFrom: piece)
                defer { try? input.close() }
                progress.update {
                    $0.source = piece.path
                    $0.target = target.path
                }
                while true {
                    if progress.isCancelled { throw CancellationError() }
                    guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                    try output.write(contentsOf: chunk)
                    crc.update(chunk)
                    written += Int64(chunk.count)
                    progress.pace(Int64(chunk.count))
                    progress.update { $0.doneBytes += Int64(chunk.count) }
                }
            }
            if let expected, expected.size != written || expected.crc != crc.value {
                throw TransferError(message: String(localized:
                    "The pieces do not make \u{201C}\(name)\u{201D}: its size or CRC differs from the .crc file (a piece is missing or damaged)."))
            }
            guard Darwin.rename(partial.path, target.path) == 0 else { throw TransferError.posix(target.path) }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        return target
    }
}

/// CRC-32 as zip and Total Commander's .crc files have it.
nonisolated struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in crc & 1 != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    private var crc: UInt32 = 0xFFFF_FFFF

    var value: UInt32 { crc ^ 0xFFFF_FFFF }

    mutating func update(_ data: Data) {
        var crc = self.crc
        data.withUnsafeBytes { bytes in
            for byte in bytes {
                crc = Self.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        self.crc = crc
    }
}
