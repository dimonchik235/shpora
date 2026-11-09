import Foundation
import Compression

/// Минимальная распаковка .zip (без сторонних библиотек): методы «без сжатия» и Deflate.
/// Этого хватает для архивов из Finder («Сжать»), Windows, 7-Zip и `zip` в терминале.
nonisolated enum ZipReader {
    enum ZipError: LocalizedError {
        case notZip, unsupported(String), corrupted(String)

        var errorDescription: String? {
            switch self {
            case .notZip: "Файл не похож на ZIP-архив"
            case .unsupported(let name): "Не поддерживается сжатие файла «\(name)»"
            case .corrupted(let name): "Архив повреждён: «\(name)»"
            }
        }
    }

    /// Распаковывает архив в папку `destination`. Служебные файлы macOS пропускаются.
    static func extract(_ archive: URL, to destination: URL) throws {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        for entry in try entries(in: data) {
            let parts = entry.name.split(separator: "/").map(String.init)
            guard !parts.isEmpty, !parts.contains(".."), !parts.contains("."),
                  parts.first != "__MACOSX", !parts.contains(where: { $0 == ".DS_Store" || $0.hasPrefix("._") })
            else { continue }
            let url = parts.reduce(destination) { $0.appendingPathComponent($1) }

            if entry.name.hasSuffix("/") {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content(of: entry, in: data).write(to: url)
        }
    }

    // MARK: - Формат ZIP

    private struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
    }

    private static func entries(in data: Data) throws -> [Entry] {
        // Конец центрального каталога ищем с конца (после него может быть комментарий до 64 КБ).
        guard data.count >= 22 else { throw ZipError.notZip }
        var eocd = -1
        var i = data.count - 22
        let lowest = max(0, data.count - 22 - 0xFFFF)
        while i >= lowest {
            if data.u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }

        let count = Int(data.u16(eocd + 10))
        var offset = Int(data.u32(eocd + 16))
        guard count != 0xFFFF, offset != 0xFFFF_FFFF else { throw ZipError.unsupported("ZIP64") }

        var result: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count, data.u32(offset) == 0x02014b50 else { throw ZipError.corrupted("каталог") }
            let flags = data.u16(offset + 8)
            let method = data.u16(offset + 10)
            let compressedSize = Int(data.u32(offset + 20))
            let size = Int(data.u32(offset + 24))
            let nameLength = Int(data.u16(offset + 28))
            let extraLength = Int(data.u16(offset + 30))
            let commentLength = Int(data.u16(offset + 32))
            let localOffset = Int(data.u32(offset + 42))
            guard offset + 46 + nameLength <= data.count else { throw ZipError.corrupted("каталог") }
            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            if compressedSize == 0xFFFF_FFFF || size == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw ZipError.unsupported("ZIP64")
            }
            result.append(Entry(name: decodeName(nameData, utf8Flag: flags & 0x0800 != 0),
                                method: method, compressedSize: compressedSize, size: size,
                                localHeaderOffset: localOffset))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return result
    }

    /// Имена: UTF-8 (Mac, современные архиваторы) или CP866 (старые архивы из Windows с русскими именами).
    private static func decodeName(_ data: Data, utf8Flag: Bool) -> String {
        if let s = String(data: data, encoding: .utf8) {
            // В macOS имена хранятся в разложенном виде («й» = «и» + «˘»)
            return s.precomposedStringWithCanonicalMapping
        }
        let cp866 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosRussian.rawValue)))
        return String(data: data, encoding: cp866) ?? String(decoding: data, as: UTF8.self)
    }

    private static func content(of entry: Entry, in data: Data) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, data.u32(header) == 0x04034b50 else { throw ZipError.corrupted(entry.name) }
        let start = header + 30 + Int(data.u16(header + 26)) + Int(data.u16(header + 28))
        guard start + entry.compressedSize <= data.count else { throw ZipError.corrupted(entry.name) }
        let compressed = data.subdata(in: start..<(start + entry.compressedSize))

        switch entry.method {
        case 0:
            return compressed
        case 8:
            if entry.size == 0 { return Data() }
            guard !compressed.isEmpty else { throw ZipError.corrupted(entry.name) }
            // COMPRESSION_ZLIB в Apple Compression — это «сырой» Deflate, как раз как в ZIP.
            var output = Data(count: entry.size)
            let written = output.withUnsafeMutableBytes { out in
                compressed.withUnsafeBytes { input in
                    compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                                              input.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { throw ZipError.corrupted(entry.name) }
            return output
        default:
            throw ZipError.unsupported(entry.name)
        }
    }
}

private extension Data {
    nonisolated func u16(_ offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    nonisolated func u32(_ offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
