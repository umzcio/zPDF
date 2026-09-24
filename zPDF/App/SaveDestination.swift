import Foundation

struct SaveDestination: Sendable {
    let url: URL
    let overwrite: Bool

    static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.resolvingSymlinksInPath().standardizedFileURL == rhs.resolvingSymlinksInPath().standardizedFileURL { return true }
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .volumeIdentifierKey]
        guard let left = try? lhs.resourceValues(forKeys: keys),
              let right = try? rhs.resourceValues(forKeys: keys),
              let leftID = left.fileResourceIdentifier as? NSObject,
              let rightID = right.fileResourceIdentifier as? NSObject,
              let leftVolume = left.volumeIdentifier as? NSObject,
              let rightVolume = right.volumeIdentifier as? NSObject else { return false }
        return leftID.isEqual(rightID) && leftVolume.isEqual(rightVolume)
    }
}
