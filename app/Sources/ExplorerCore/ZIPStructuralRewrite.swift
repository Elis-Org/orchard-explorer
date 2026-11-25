import CoreFoundation
import CryptoKit
import Foundation

/// A byte-preserving record edit. No compressed payload is decoded or rewritten.
struct ZIPStructuralPlan {
    var removed: Set<Int> = []
    var renamed: [Int: [String]] = [:]
    var mappings: [ArchiveRenameMapping] = []
    var changedLocations: [URL] = []

    init() {}

    func minimumCandidateBytes(manifest: ZIPArchiveManifest, layout: ZIPValidatedLayout,
                               addedRecords: Int, additionHeaders: UInt64) throws -> UInt64 {
        let retained = manifest.records.filter { !removed.contains($0.id) }
        guard retained.count + addedRecords <= 100_000 else { throw ZIPListingError.limitExceeded }
        var bytes = UInt64(22 + manifest.archiveComment.count) + additionHeaders
        if manifest.envelope.rawZIP64Record != nil || retained.count + addedRecords >= Int(UInt16.max) { bytes += 76 }
        for record in retained {
            guard let member = layout.records[record.id] else { throw ZIPListingError.corrupt }
            if renamed[record.id] != nil {
                // Both fixed headers plus at least one byte for each nonempty
                // name. Unknown compression savings are never assumed.
                bytes += member.payloadRange.length + (member.descriptorRange?.length ?? 0) + 78
            } else { bytes += member.completeRange.length + UInt64(record.centralRange.count) }
        }
        return bytes
    }

    init(edits: [ArchiveEdit], context: ArchiveOperationContext, manifest: ZIPArchiveManifest,
         checkpoint: () throws -> Void = {},
         validateCompanion: (ZIPCentralRecord) throws -> Void = { _ in
             throw ArchiveOperationError.unsupported("This item has associated AppleDouble metadata that could not be verified.")
         }) throws {
        guard !edits.isEmpty else { throw ArchiveOperationError.invalidName("No archive items were selected.") }
        let origins = try ZIPOriginCompanionIndex(manifest: manifest)
        var touched: Set<Int> = []
        var names = Set(manifest.records.map(\.pathKey) + manifest.directories.map(\.pathKey))
        var introduced: [[String]] = [], companionReservations: [Data: Data] = [:]
        for edit in edits {
            let target: ArchiveMemberTarget, newName: String?
            switch edit {
            case .remove(let source), .removeAfterVerifiedCopy(let source, _): target = source; newName = nil
            case .rename(let source, let name): target = source; newName = name
            case .add: throw ArchiveOperationError.unsupported("Adding files is not available in this transaction.")
            }
            guard target.revision == context.revision,
                  target.location.archiveURL == context.location.archiveURL,
                  !target.location.components.isEmpty,
                  ZIPArchiveManifest.pathKey(Array(target.location.components.dropLast())) == ZIPArchiveManifest.pathKey(context.location.components) else {
                throw ArchiveOperationError.changed
            }
            let selected = try manifest.selection(at: target.location)
            let selectedKey = ZIPArchiveManifest.pathKey(target.location.components)
            for record in selected.records {
                if let member = origins.memberComponents(forCompanionRecordID: record.id),
                   !ZIPArchiveManifest.contains(ZIPArchiveManifest.pathKey(member), in: selectedKey) {
                    throw ArchiveOperationError.unsupported("Origin metadata cannot be edited independently. Edit its associated archive item instead.")
                }
            }
            var companions: [Int: ZIPCentralRecord] = [:]
            for components in selected.records.map(\.components) + selected.directories.map(\.components) {
                if let companion = try origins.companion(for: components) {
                    guard let owner = origins.memberComponents(forCompanionRecordID: companion.id),
                          ZIPArchiveManifest.pathKey(owner) == ZIPArchiveManifest.pathKey(components) else {
                        throw ArchiveOperationError.unsupported("This item has ambiguous AppleDouble metadata belonging to another ZIP item.")
                    }
                    if companions[companion.id] == nil {
                        try validateCompanion(companion)
                        companions[companion.id] = companion
                    }
                }
            }
            let ids = Set(selected.records.map(\.id)).union(companions.keys)
            guard !ids.isEmpty, touched.isDisjoint(with: ids) else { throw ArchiveOperationError.changed }
            touched.formUnion(ids)
            if let newName {
                guard ArchiveLocation.validComponent(newName), newName.utf8.count <= 4_096 else {
                    throw ArchiveOperationError.invalidName("Enter one valid archive item name.")
                }
                let oldPrefix = target.location.components
                let newPrefix = Array(oldPrefix.dropLast()) + [newName]
                let newKey = ZIPArchiveManifest.pathKey(newPrefix)
                guard newKey != ZIPArchiveManifest.pathKey(oldPrefix) else { throw ArchiveOperationError.invalidName("The name has not changed.") }
                guard !names.contains(newKey) else { throw ArchiveOperationError.collision(newName) }
                introduced += selected.directories.map { newPrefix + $0.components.dropFirst(oldPrefix.count) }
                introduced += selected.records.filter { $0.kind != .directory && companions[$0.id] == nil }
                    .map { newPrefix + $0.components.dropFirst(oldPrefix.count) }
                for record in selected.records {
                    let components = newPrefix + record.components.dropFirst(oldPrefix.count)
                    let key = ZIPArchiveManifest.pathKey(components)
                    renamed[record.id] = Array(components)
                    names.insert(key)
                }
                for companion in companions.values where renamed[companion.id] == nil {
                    guard let member = origins.memberComponents(forCompanionRecordID: companion.id) else { throw ZIPListingError.corrupt }
                    let destinationMember = newPrefix + member.dropFirst(oldPrefix.count)
                    let components: [String]
                    if companion.components.first == "__MACOSX" {
                        components = ZIPOriginCompanionIndex.components(for: Array(destinationMember))
                    } else {
                        components = Array(destinationMember.dropLast()) + ["._" + destinationMember.last!]
                    }
                    let key = ZIPArchiveManifest.pathKey(components)
                    guard !names.contains(key) else { throw ArchiveOperationError.collision(components.last!) }
                    renamed[companion.id] = components; names.insert(key)
                }
                for companion in companions.values {
                    guard let oldOwner = origins.memberComponents(forCompanionRecordID: companion.id),
                          let destinationCompanion = renamed[companion.id] else { throw ZIPListingError.corrupt }
                    let owner = newPrefix + oldOwner.dropFirst(oldPrefix.count)
                    let key = ZIPArchiveManifest.pathKey(destinationCompanion), ownerKey = ZIPArchiveManifest.pathKey(Array(owner))
                    guard companionReservations[key] == nil else { throw ZIPListingError.corrupt }
                    companionReservations[key] = ownerKey
                }
                let destination = try ArchiveLocation(archiveURL: context.location.archiveURL, components: newPrefix)
                mappings.append(ArchiveRenameMapping(sourceURL: target.location.url, destinationURL: destination.url))
                changedLocations.append(destination.url)
            } else {
                removed.formUnion(ids)
                changedLocations.append(target.location.url)
            }
        }
        try ZIPOriginCompanionIndex.validateDestinations(introduced: introduced,
            retained: manifest.records.filter { !removed.contains($0.id) && renamed[$0.id] == nil }.map(\.components),
            planned: Array(renamed.values), companions: companionReservations, checkpoint: checkpoint)
    }
}

struct ZIPRewriteResult {
    let originalDigest: Data
    let candidateDigest: Data
    let candidateLength: UInt64
}

enum ZIPStructuralRewrite {
    /// Independent prepublication comparison of the permitted changes. The
    /// source digest used for displaced-file verification still comes only from
    /// the sequential write pass; these reads validate the resulting candidate.
    static func verify(manifest: ZIPArchiveManifest, layout: ZIPValidatedLayout, plan: ZIPStructuralPlan,
                       reader: any ZIPPositionalReading, candidate: ZIPArchiveManifest,
                       candidateLayout: ZIPValidatedLayout, candidateReader: any ZIPPositionalReading,
                       checkpoint: () throws -> Void) throws {
        let retained = manifest.records.filter { !plan.removed.contains($0.id) }
        guard candidate.records.count == retained.count, candidate.archiveComment == manifest.archiveComment else { throw ZIPListingError.corrupt }
        func compare(_ old: ZIPByteRange, _ new: ZIPByteRange) throws {
            guard old.length == new.length else { throw ZIPListingError.corrupt }
            var offset: UInt64 = 0
            while offset < old.length {
                try checkpoint()
                let count = Int(min(65_536, old.length - offset))
                guard try reader.read(offset: old.offset + offset, count: count) == candidateReader.read(offset: new.offset + offset, count: count) else { throw ZIPListingError.corrupt }
                offset += UInt64(count)
            }
        }
        try reader.validateUnchanged(); try candidateReader.validateUnchanged()
        for (old, new) in zip(retained, candidate.records) {
            try checkpoint()
            guard let oldLayout = layout.records[old.id], let newLayout = candidateLayout.records[new.id],
                  new.pathKey == ZIPArchiveManifest.pathKey(plan.renamed[old.id] ?? old.components) else { throw ZIPListingError.corrupt }
            var expectedCentral = old.centralBytes.subdata(in: old.centralRange)
            if let components = plan.renamed[old.id] {
                let original = try readHeader(oldLayout, reader: reader)
                let patch = try ZIPRenameMetadata.make(record: old, components: components, localExtra: original.extra)
                var fixed = Array(original.fixed), centralFixed = Array(expectedCentral.prefix(46))
                ZIPBytes.put16(patch.flags, into: &fixed, at: 6)
                ZIPBytes.put16(UInt16(patch.name.count), into: &fixed, at: 26)
                ZIPBytes.put16(UInt16(patch.localExtra.count), into: &fixed, at: 28)
                let expectedHeader = Data(fixed) + patch.name + patch.localExtra
                guard UInt64(expectedHeader.count) == newLayout.localHeaderRange.length,
                      try candidateReader.read(offset: newLayout.localHeaderRange.offset, count: expectedHeader.count) == expectedHeader else { throw ZIPListingError.corrupt }
                ZIPBytes.put16(patch.flags, into: &centralFixed, at: 8)
                ZIPBytes.put16(UInt16(patch.name.count), into: &centralFixed, at: 28)
                ZIPBytes.put16(UInt16(patch.centralExtra.count), into: &centralFixed, at: 30)
                ZIPBytes.put16(UInt16(patch.comment.count), into: &centralFixed, at: 32)
                expectedCentral = Data(centralFixed) + patch.name + patch.centralExtra + patch.comment
                try compare(ZIPByteRange(offset: oldLayout.payloadRange.offset, length: oldLayout.payloadRange.length + (oldLayout.descriptorRange?.length ?? 0)),
                            ZIPByteRange(offset: newLayout.payloadRange.offset, length: newLayout.payloadRange.length + (newLayout.descriptorRange?.length ?? 0)))
            } else { try compare(oldLayout.completeRange, newLayout.completeRange) }
            guard try changingOffset(expectedCentral, to: new.localHeaderOffset) == new.centralBytes.subdata(in: new.centralRange) else { throw ZIPListingError.corrupt }
        }
        try reader.validateUnchanged(); try candidateReader.validateUnchanged()
    }

    static func digest(reader: any ZIPPositionalReading, range: ZIPByteRange,
                       checkpoint: () throws -> Void) throws -> Data {
        guard range.offset <= reader.length, range.length <= reader.length - range.offset else { throw ZIPListingError.corrupt }
        var digest = SHA256(), position: UInt64 = 0
        while position < range.length {
            try checkpoint()
            let count = Int(min(65_536, range.length - position))
            let data = try reader.read(offset: range.offset + position, count: count)
            guard data.count == count else { throw ZIPListingError.changed }
            digest.update(data: data); position += UInt64(count)
        }
        return Data(digest.finalize())
    }

    /// Every original byte is read and hashed in this single monotonically
    /// increasing pass, including discarded records and the old index/envelope.
    static func write(manifest: ZIPArchiveManifest, layout: ZIPValidatedLayout, plan: ZIPStructuralPlan,
                      reader: any ZIPPositionalReading, output: (Data) throws -> Void,
                      checkpoint: () throws -> Void = {}) throws -> ZIPRewriteResult {
        try reader.validateUnchanged()
        var patchedHeaders: [Int: Data] = [:], patchedDirectories: [Int: Data] = [:]
        var preparedBytes = 0
        // All bounded metadata reads precede the sequential copy/hash pass.
        for record in manifest.records where plan.removed.contains(record.id) || plan.renamed[record.id] != nil {
            try checkpoint()
            guard let member = layout.records[record.id] else { throw ZIPListingError.corrupt }
            let original = try readHeader(member, reader: reader)
            if plan.removed.contains(record.id) {
                try ZIPRenameMetadata.validateUnicode(extra: record.extraBytes, name: record.nameBytes,
                                                       comment: record.commentBytes, flags: record.flags)
                try ZIPRenameMetadata.validateUnicode(extra: original.extra, name: record.nameBytes,
                                                       comment: record.commentBytes, flags: record.flags)
                continue
            }
            let patch = try ZIPRenameMetadata.make(record: record, components: plan.renamed[record.id]!, localExtra: original.extra)
            var fixed = Array(original.fixed), centralFixed = Array(record.centralBytes[record.centralRange].prefix(46))
            ZIPBytes.put16(patch.flags, into: &fixed, at: 6)
            ZIPBytes.put16(UInt16(patch.name.count), into: &fixed, at: 26)
            ZIPBytes.put16(UInt16(patch.localExtra.count), into: &fixed, at: 28)
            ZIPBytes.put16(patch.flags, into: &centralFixed, at: 8)
            ZIPBytes.put16(UInt16(patch.name.count), into: &centralFixed, at: 28)
            ZIPBytes.put16(UInt16(patch.centralExtra.count), into: &centralFixed, at: 30)
            ZIPBytes.put16(UInt16(patch.comment.count), into: &centralFixed, at: 32)
            let header = Data(fixed) + patch.name + patch.localExtra
            let directory = Data(centralFixed) + patch.name + patch.centralExtra + patch.comment
            guard header.count + directory.count <= 128 * 1_024 * 1_024 - preparedBytes else { throw ZIPListingError.limitExceeded }
            preparedBytes += header.count + directory.count
            patchedHeaders[record.id] = header; patchedDirectories[record.id] = directory
        }
        try reader.validateUnchanged()
        var cursor: UInt64 = 0, written: UInt64 = 0, digest = SHA256(), candidateDigest = SHA256(), central = Data()
        func emit(_ bytes: Data) throws {
            try checkpoint()
            guard UInt64(bytes.count) <= 2 * 1_024 * 1_024 * 1_024 - written else {
                throw ArchiveOperationError.limitExceeded("The rewritten ZIP exceeds the 2 GiB limit.")
            }
            try output(bytes); candidateDigest.update(data: bytes); written += UInt64(bytes.count)
        }
        func consume(to end: UInt64, copy: Bool) throws {
            guard end >= cursor, end <= reader.length else { throw ZIPListingError.corrupt }
            while cursor < end {
                try checkpoint()
                let count = Int(min(65_536, end - cursor))
                let bytes = try reader.read(offset: cursor, count: count)
                guard bytes.count == count else { throw ZIPListingError.changed }
                digest.update(data: bytes); cursor += UInt64(count)
                if copy { try emit(bytes) }
            }
        }
        var retainedCount = 0
        for record in manifest.records {
            guard let member = layout.records[record.id] else { throw ZIPListingError.corrupt }
            // A validated canonical mutation layout has no unexplained gaps;
            // consume still handles them explicitly rather than omitting hashes.
            try consume(to: member.completeRange.offset, copy: true)
            if plan.removed.contains(record.id) {
                try consume(to: member.completeRange.offset + member.completeRange.length, copy: false)
                continue
            }
            let newOffset = written
            var directory = record.centralBytes.subdata(in: record.centralRange)
            if let header = patchedHeaders[record.id] {
                try consume(to: member.payloadRange.offset, copy: false)
                try emit(header)
                try consume(to: member.completeRange.offset + member.completeRange.length, copy: true)
                directory = patchedDirectories[record.id]!
            } else {
                try consume(to: member.completeRange.offset + member.completeRange.length, copy: true)
            }
            directory = try changingOffset(directory, to: newOffset)
            guard directory.count <= 64 * 1_024 * 1_024 - central.count else { throw ZIPListingError.limitExceeded }
            central.append(directory); retainedCount += 1
        }
        try consume(to: reader.length, copy: false)
        try reader.validateUnchanged()
        let centralOffset = written
        try emit(central)
        try emit(try envelope(manifest.envelope, count: retainedCount, directoryOffset: centralOffset,
                              directoryLength: UInt64(central.count)))
        return ZIPRewriteResult(originalDigest: Data(digest.finalize()), candidateDigest: Data(candidateDigest.finalize()), candidateLength: written)
    }

    private static func readHeader(_ layout: ZIPRecordLayout, reader: any ZIPPositionalReading) throws -> (fixed: Data, extra: Data) {
        // Validation metadata reads are separate from the single source hashing
        // pass. They never substitute for hashing the original header bytes.
        let fixed = try reader.read(offset: layout.localHeaderRange.offset, count: 30)
        let extra = try reader.read(offset: layout.extraRange.offset, count: Int(layout.extraRange.length))
        guard fixed.count == 30, extra.count == Int(layout.extraRange.length) else { throw ZIPListingError.changed }
        return (fixed, extra)
    }

    static func changingOffset(_ record: Data, to offset: UInt64) throws -> Data {
        var bytes = Array(record)
        if ZIPBytes.u32(bytes, 42) != UInt32.max {
            guard offset < UInt64(UInt32.max) else { throw ZIPListingError.limitExceeded }
            ZIPBytes.put32(UInt32(offset), into: &bytes, at: 42)
        } else {
            let start = 46 + Int(ZIPBytes.u16(bytes, 28)), length = Int(ZIPBytes.u16(bytes, 30))
            let extra = Data(bytes[start..<(start + length)])
            guard let field = try ZIPExtraFields.parse(extra).first(where: { $0.tag == 1 }) else { throw ZIPListingError.corrupt }
            var position = start + field.dataRange.lowerBound
            if ZIPBytes.u32(bytes, 24) == UInt32.max { position += 8 }
            if ZIPBytes.u32(bytes, 20) == UInt32.max { position += 8 }
            guard position + 8 <= start + field.dataRange.upperBound else { throw ZIPListingError.corrupt }
            ZIPBytes.put64(offset, into: &bytes, at: position)
        }
        return Data(bytes)
    }

    private static func envelope(_ old: ZIPArchiveEnvelope, count: Int, directoryOffset: UInt64,
                                 directoryLength: UInt64) throws -> Data {
        var result = Data(), end = Array(old.rawEndRecord)
        let zip64 = old.rawZIP64Record != nil || count >= Int(UInt16.max)
        if zip64 {
            var record = Array(old.rawZIP64Record ?? Data(count: 56))
            if old.rawZIP64Record == nil {
                ZIPBytes.put32(0x06064b50, into: &record, at: 0); ZIPBytes.put64(44, into: &record, at: 4)
                ZIPBytes.put16(45, into: &record, at: 12); ZIPBytes.put16(45, into: &record, at: 14)
            }
            ZIPBytes.put64(UInt64(count), into: &record, at: 24); ZIPBytes.put64(UInt64(count), into: &record, at: 32)
            ZIPBytes.put64(directoryLength, into: &record, at: 40); ZIPBytes.put64(directoryOffset, into: &record, at: 48)
            var locator = Array(old.rawZIP64Locator ?? Data(count: 20))
            ZIPBytes.put32(0x07064b50, into: &locator, at: 0); ZIPBytes.put32(1, into: &locator, at: 16)
            ZIPBytes.put64(directoryOffset + directoryLength, into: &locator, at: 8)
            result.append(contentsOf: record); result.append(contentsOf: locator)
        }
        let count16 = count >= Int(UInt16.max) ? UInt16.max : UInt16(count)
        ZIPBytes.put16(zip64 && ZIPBytes.u16(end, 8) == .max ? .max : count16, into: &end, at: 8)
        ZIPBytes.put16(zip64 && ZIPBytes.u16(end, 10) == .max ? .max : count16, into: &end, at: 10)
        ZIPBytes.put32(zip64 && ZIPBytes.u32(end, 12) == .max ? .max : UInt32(directoryLength), into: &end, at: 12)
        ZIPBytes.put32(zip64 && ZIPBytes.u32(end, 16) == .max ? .max : UInt32(directoryOffset), into: &end, at: 16)
        result.append(contentsOf: end); return result
    }
}

private enum ZIPRenameMetadata {
    static let cp437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
    struct Patch { let flags: UInt16; let name: Data; let comment: Data; let localExtra: Data; let centralExtra: Data }

    static func make(record: ZIPCentralRecord, components: [String], localExtra: Data) throws -> Patch {
        let encoding = record.flags & 0x800 != 0 ? String.Encoding.utf8 : cp437
        guard let rawName = String(data: record.nameBytes, encoding: encoding),
              let commentText = String(data: record.commentBytes, encoding: encoding) else { throw ZIPListingError.invalidEncoding }
        // Preserve original separator spelling (including mixed backslashes).
        var parts = rawName.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard parts.count == components.count || parts.count == components.count + 1 && parts.last == "" else { throw ZIPListingError.invalidPath }
        for index in components.indices { parts[index] = components[index] }
        let separators = rawName.filter { $0 == "/" || $0 == "\\" }
        var nameText = parts[0]
        for (index, separator) in separators.enumerated() { nameText.append(separator); nameText += parts[index + 1] }
        let sameEncoding = nameText.data(using: encoding, allowLossyConversion: false)
        let flags = sameEncoding == nil ? record.flags | 0x800 : record.flags
        let name = sameEncoding ?? Data(nameText.utf8)
        let comment = sameEncoding == nil ? Data(commentText.utf8) : record.commentBytes
        guard name.count <= 4_096, comment.count <= Int(UInt16.max) else { throw ZIPListingError.limitExceeded }
        let local = try rewriteExtra(localExtra, oldName: record.nameBytes, oldComment: record.commentBytes,
                                     oldFlags: record.flags, newName: name, newComment: comment,
                                     nameText: nameText, commentText: commentText)
        let central = try rewriteExtra(record.extraBytes, oldName: record.nameBytes, oldComment: record.commentBytes,
                                       oldFlags: record.flags, newName: name, newComment: comment,
                                       nameText: nameText, commentText: commentText)
        return Patch(flags: flags, name: name, comment: comment, localExtra: local, centralExtra: central)
    }

    static func validateUnicode(extra: Data, name: Data, comment: Data, flags: UInt16) throws {
        let encoding = flags & 0x800 != 0 ? String.Encoding.utf8 : cp437
        var seen: Set<UInt16> = []
        for field in try ZIPExtraFields.parse(extra) where field.tag == 0x7075 || field.tag == 0x6375 {
            guard seen.insert(field.tag).inserted else { throw ZIPListingError.unsupportedMetadata }
            let value = Array(extra[field.dataRange]), raw = field.tag == 0x7075 ? name : comment
            guard value.count >= 5, value[0] == 1, ZIPBytes.u32(value, 1) == (try ZIPCRC32.checksum(raw)),
                  let text = String(data: Data(value.dropFirst(5)), encoding: .utf8),
                  let decoded = String(data: raw, encoding: encoding) else { throw ZIPListingError.unsupportedMetadata }
            let lhs = field.tag == 0x7075 ? text.replacingOccurrences(of: "\\", with: "/") : text
            let rhs = field.tag == 0x7075 ? decoded.replacingOccurrences(of: "\\", with: "/") : decoded
            guard Data(lhs.utf8) == Data(rhs.utf8) else {
                throw ArchiveOperationError.unsupported("This item has conflicting legacy Unicode metadata and cannot be changed safely.")
            }
        }
    }

    private static func rewriteExtra(_ extra: Data, oldName: Data, oldComment: Data, oldFlags: UInt16,
                                     newName: Data, newComment: Data, nameText: String, commentText: String) throws -> Data {
        try validateUnicode(extra: extra, name: oldName, comment: oldComment, flags: oldFlags)
        let allowed: Set<UInt16> = [0x0001, 0x000a, 0x5455, 0x5855, 0x7855, 0x7875, 0x7075, 0x6375]
        var output = Data()
        for field in try ZIPExtraFields.parse(extra) {
            guard allowed.contains(field.tag) else {
                throw ArchiveOperationError.unsupported("This item's extra metadata cannot be safely preserved during Rename.")
            }
            if field.tag == 0x7075 || field.tag == 0x6375 {
                let text = field.tag == 0x7075 ? nameText : commentText
                let bytes = field.tag == 0x7075 ? newName : newComment
                let utf8 = Data(text.utf8)
                guard utf8.count <= Int(UInt16.max) - 5 else { throw ZIPListingError.limitExceeded }
                var header = [UInt8](repeating: 0, count: 9)
                ZIPBytes.put16(field.tag, into: &header, at: 0); ZIPBytes.put16(UInt16(utf8.count + 5), into: &header, at: 2)
                header[4] = 1; ZIPBytes.put32(try ZIPCRC32.checksum(bytes), into: &header, at: 5)
                output.append(contentsOf: header); output.append(utf8)
            } else { output.append(extra.subdata(in: field.range)) }
        }
        guard output.count <= Int(UInt16.max) else { throw ZIPListingError.limitExceeded }
        return output
    }
}
