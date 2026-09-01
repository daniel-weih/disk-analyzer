import Darwin
import Foundation

enum ResultFreshness: Equatable {
    case scanBacked
    case needsVerification

    var needsVerification: Bool {
        self == .needsVerification
    }
}

struct SnapshotTrashUpdate {
    let result: DiskScanResult
    let sourcePath: String
    let destinationPath: String?
    let freshness: ResultFreshness
}

enum SnapshotTrashReconciler {
    static func moved(
        _ source: FileNode,
        destinationURL: URL?,
        in result: DiskScanResult
    ) -> SnapshotTrashUpdate? {
        guard let sourcePath = source.path,
              sourcePath != result.rootURL.standardizedFileURL.path,
              let detached = detach(path: sourcePath, from: result.root) else {
            return nil
        }

        let destinationPath = destinationURL?.standardizedFileURL.path
        let rootPath = result.rootURL.standardizedFileURL.path
        let destinationIsInsideRoot = destinationPath.map {
            isPath($0, insideOrEqualTo: rootPath)
        } ?? false

        var updatedRoot = detached.root
        var attachedInsideRoot = false
        if let destinationPath, destinationIsInsideRoot {
            let destinationParent = URL(fileURLWithPath: destinationPath)
                .deletingLastPathComponent()
                .standardizedFileURL.path
            let movedNode = rebase(
                detached.removed,
                from: sourcePath,
                to: destinationPath,
                parentPath: destinationParent
            )
            if find(path: destinationPath, in: updatedRoot) == nil,
               let attached = attach(
                    movedNode,
                    toDirectoryAt: destinationParent,
                    in: updatedRoot
               ) {
                updatedRoot = attached
                attachedInsideRoot = true
            }
        }

        let effectiveDestinationPath = attachedInsideRoot ? destinationPath : nil

        return SnapshotTrashUpdate(
            result: rebuildResult(
                result,
                root: updatedRoot,
                sourcePath: sourcePath,
                destinationPath: effectiveDestinationPath,
                removedFromRoot: !attachedInsideRoot
            ),
            sourcePath: sourcePath,
            destinationPath: effectiveDestinationPath,
            freshness: .needsVerification
        )
    }

    static func alreadyMissing(
        _ source: FileNode,
        in result: DiskScanResult
    ) -> SnapshotTrashUpdate? {
        guard let sourcePath = source.path,
              sourcePath != result.rootURL.standardizedFileURL.path,
              let detached = detach(path: sourcePath, from: result.root) else {
            return nil
        }
        return SnapshotTrashUpdate(
            result: rebuildResult(
                result,
                root: detached.root,
                sourcePath: sourcePath,
                destinationPath: nil,
                removedFromRoot: true
            ),
            sourcePath: sourcePath,
            destinationPath: nil,
            freshness: .needsVerification
        )
    }

    static func mappedPath(
        _ path: String,
        sourcePath: String,
        destinationPath: String?
    ) -> String? {
        guard isPath(path, insideOrEqualTo: sourcePath) else { return path }
        guard let destinationPath else { return nil }
        return replacingPrefix(path, sourcePath: sourcePath, destinationPath: destinationPath)
    }

    private struct DetachedNode {
        let root: FileNode
        let removed: FileNode
    }

    private struct DirectoryMetadata {
        let logicalBytes: Int64
        let allocatedBytes: Int64
        let isDirectory: Bool
    }

    private static func detach(path: String, from root: FileNode) -> DetachedNode? {
        guard root.isDirectory, let rootPath = root.path,
              isPath(path, insideOrEqualTo: rootPath), path != rootPath else {
            return nil
        }

        var removed: FileNode?
        var changed = false
        var children: [FileNode] = []
        children.reserveCapacity(root.children.count)

        for child in root.children {
            if child.path == path {
                removed = child
                changed = true
                continue
            }
            if child.isDirectory,
               let childPath = child.path,
               isPath(path, insideOrEqualTo: childPath),
               let nested = detach(path: path, from: child) {
                children.append(nested.root)
                removed = nested.removed
                changed = true
            } else {
                children.append(child)
            }
        }

        guard changed, let removed else { return nil }
        return DetachedNode(
            root: rebuildDirectory(root, children: children),
            removed: removed
        )
    }

    private static func attach(
        _ childToInsert: FileNode,
        toDirectoryAt parentPath: String,
        in root: FileNode
    ) -> FileNode? {
        guard root.isDirectory, let rootPath = root.path,
              isPath(parentPath, insideOrEqualTo: rootPath) else {
            return nil
        }

        if rootPath == parentPath {
            guard !root.isUnreadable,
                  root.children.allSatisfy({ $0.path != childToInsert.path }) else {
                return nil
            }
            return rebuildDirectory(root, children: root.children + [childToInsert])
        }

        var changed = false
        let children = root.children.map { child -> FileNode in
            guard !changed,
                  child.isDirectory,
                  let childPath = child.path,
                  isPath(parentPath, insideOrEqualTo: childPath),
                  let updated = attach(
                    childToInsert,
                    toDirectoryAt: parentPath,
                    in: child
                  ) else {
                return child
            }
            changed = true
            return updated
        }
        guard changed else { return nil }
        return rebuildDirectory(root, children: children)
    }

    private static func rebase(
        _ node: FileNode,
        from sourcePath: String,
        to destinationPath: String,
        parentPath: String
    ) -> FileNode {
        let newPath = node.path.map {
            replacingPrefix(
                $0,
                sourcePath: sourcePath,
                destinationPath: destinationPath
            )
        }
        let newParentPath = newPath.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.path
        } ?? parentPath
        let newChildren = node.children.map {
            rebase(
                $0,
                from: sourcePath,
                to: destinationPath,
                parentPath: newPath ?? newParentPath
            )
        }

        let newID: String
        if node.kind == .otherFiles {
            newID = "aggregate:\(parentPath)"
        } else if let oldPath = node.path, let newPath, node.id == oldPath {
            newID = newPath
        } else if let oldPath = node.path, let newPath, node.id.hasSuffix(oldPath) {
            newID = String(node.id.dropLast(oldPath.count)) + newPath
        } else {
            newID = node.id
        }

        let name = node.path == sourcePath
            ? URL(fileURLWithPath: destinationPath).lastPathComponent
            : node.name
        if node.isDirectory {
            return rebuildDirectory(
                node,
                id: newID,
                path: newPath,
                name: name,
                children: newChildren
            )
        }
        return FileNode(
            id: newID,
            path: newPath,
            name: name,
            kind: node.kind,
            logicalBytes: node.logicalBytes,
            allocatedBytes: node.allocatedBytes,
            ownLogicalBytes: node.ownLogicalBytes,
            ownAllocatedBytes: node.ownAllocatedBytes,
            children: newChildren,
            fileCount: node.fileCount,
            directoryCount: node.directoryCount,
            omittedItemCount: node.omittedItemCount,
            isUnreadable: node.isUnreadable,
            isSharedReference: node.isSharedReference
        )
    }

    private static func rebuildDirectory(
        _ original: FileNode,
        id: String? = nil,
        path: String? = nil,
        name: String? = nil,
        children: [FileNode]
    ) -> FileNode {
        let resolvedPath = path ?? original.path
        let metadata = resolvedPath.flatMap(directoryMetadata)
        let ownLogical = metadata?.isDirectory == true
            ? metadata!.logicalBytes
            : original.ownLogicalBytes
        let ownAllocated = metadata?.isDirectory == true
            ? metadata!.allocatedBytes
            : original.ownAllocatedBytes
        let sortedChildren = children.sorted(by: defaultNodeOrder)
        let logical = ownLogical + sortedChildren.reduce(Int64(0)) { $0 + $1.logicalBytes }
        let allocated = ownAllocated + sortedChildren.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        let fileCount = sortedChildren.reduce(0) { $0 + $1.fileCount }
        let directoryCount = 1 + sortedChildren.reduce(0) { $0 + $1.directoryCount }
        return FileNode(
            id: id ?? original.id,
            path: resolvedPath,
            name: name ?? original.name,
            kind: original.kind,
            logicalBytes: logical,
            allocatedBytes: allocated,
            ownLogicalBytes: ownLogical,
            ownAllocatedBytes: ownAllocated,
            children: sortedChildren,
            fileCount: fileCount,
            directoryCount: directoryCount,
            omittedItemCount: original.omittedItemCount,
            isUnreadable: original.isUnreadable,
            isSharedReference: original.isSharedReference
        )
    }

    private static func rebuildResult(
        _ original: DiskScanResult,
        root: FileNode,
        sourcePath: String,
        destinationPath: String?,
        removedFromRoot: Bool
    ) -> DiskScanResult {
        let allDirectories = collectDirectories(from: root)
        let largestDirectories = rankByBothMetrics(
            allDirectories,
            limit: original.scanOptions.largestItemLimit
        )
        let byPath = indexByPath(root)
        let largestFiles = original.largestFiles.compactMap { node -> FileNode? in
            guard let path = node.path else { return node }
            if isPath(path, insideOrEqualTo: sourcePath) {
                guard !removedFromRoot, let destinationPath else { return nil }
                let mapped = replacingPrefix(
                    path,
                    sourcePath: sourcePath,
                    destinationPath: destinationPath
                )
                return byPath[mapped] ?? rebase(
                    node,
                    from: sourcePath,
                    to: destinationPath,
                    parentPath: URL(fileURLWithPath: mapped)
                        .deletingLastPathComponent().path
                )
            }
            return byPath[path] ?? node
        }.sorted(by: rankingNodeOrder)

        let issues: [ScanIssue]
        let skippedVolumes: [SkippedVolumeInfo]
        let removedIssues: [ScanIssue]
        if removedFromRoot {
            removedIssues = original.diagnostics.issues.filter {
                isPath($0.path, insideOrEqualTo: sourcePath)
            }
            issues = original.diagnostics.issues.filter {
                !isPath($0.path, insideOrEqualTo: sourcePath)
            }
            skippedVolumes = original.diagnostics.skippedVolumes.filter {
                !isPath($0.path, insideOrEqualTo: sourcePath)
            }
        } else if let destinationPath {
            removedIssues = []
            issues = original.diagnostics.issues.map {
                guard isPath($0.path, insideOrEqualTo: sourcePath) else { return $0 }
                return ScanIssue(
                    kind: $0.kind,
                    path: replacingPrefix(
                        $0.path,
                        sourcePath: sourcePath,
                        destinationPath: destinationPath
                    ),
                    errorCode: $0.errorCode
                )
            }
            skippedVolumes = original.diagnostics.skippedVolumes.map {
                guard isPath($0.path, insideOrEqualTo: sourcePath) else { return $0 }
                return SkippedVolumeInfo(
                    name: $0.name,
                    path: replacingPrefix(
                        $0.path,
                        sourcePath: sourcePath,
                        destinationPath: destinationPath
                    ),
                    kind: $0.kind
                )
            }
        } else {
            removedIssues = []
            issues = original.diagnostics.issues
            skippedVolumes = original.diagnostics.skippedVolumes
        }

        let removedUnreadable = removedIssues.filter {
            $0.kind == .unreadableDirectory
        }.count
        let removedMetadata = removedIssues.filter {
            $0.kind == .metadataUnavailable
        }.count
        let diagnostics = ScanDiagnostics(
            unreadableDirectoryCount: max(
                original.diagnostics.unreadableDirectoryCount - removedUnreadable,
                0
            ),
            metadataErrorCount: max(
                original.diagnostics.metadataErrorCount - removedMetadata,
                0
            ),
            skippedVolumes: skippedVolumes,
            duplicateDirectoryCount: original.diagnostics.duplicateDirectoryCount,
            duplicateFileCount: original.diagnostics.duplicateFileCount,
            issues: issues
        )

        return DiskScanResult(
            root: root,
            rootURL: original.rootURL,
            volume: original.volume,
            isVolumeRoot: original.isVolumeRoot,
            elapsedSeconds: original.elapsedSeconds,
            diagnostics: diagnostics,
            largestDirectories: largestDirectories,
            largestFiles: largestFiles,
            scanOptions: original.scanOptions
        )
    }

    private static func collectDirectories(from root: FileNode) -> [FileNode] {
        var directories: [FileNode] = []
        var stack = root.children
        while let node = stack.popLast() {
            guard node.isDirectory else { continue }
            directories.append(node)
            stack.append(contentsOf: node.children)
        }
        return directories
    }

    private static func indexByPath(_ root: FileNode) -> [String: FileNode] {
        var result: [String: FileNode] = [:]
        var stack = [root]
        while let node = stack.popLast() {
            if let path = node.path { result[path] = node }
            stack.append(contentsOf: node.children)
        }
        return result
    }

    private static func rankByBothMetrics(
        _ nodes: [FileNode],
        limit: Int
    ) -> [FileNode] {
        let count = max(limit, 1)
        let byAllocated = nodes.sorted {
            if $0.allocatedBytes != $1.allocatedBytes {
                return $0.allocatedBytes > $1.allocatedBytes
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.prefix(count)
        let byLogical = nodes.sorted {
            if $0.logicalBytes != $1.logicalBytes {
                return $0.logicalBytes > $1.logicalBytes
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.prefix(count)
        var retained: [String: FileNode] = [:]
        for node in byAllocated { retained[node.id] = node }
        for node in byLogical { retained[node.id] = node }
        return retained.values.sorted(by: rankingNodeOrder)
    }

    private static func find(path: String, in root: FileNode) -> FileNode? {
        var stack = [root]
        while let node = stack.popLast() {
            if node.path == path { return node }
            stack.append(contentsOf: node.children)
        }
        return nil
    }

    private static func directoryMetadata(_ path: String) -> DirectoryMetadata? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return DirectoryMetadata(
            logicalBytes: max(Int64(info.st_size), 0),
            allocatedBytes: max(Int64(info.st_blocks) * 512, 0),
            isDirectory: (info.st_mode & S_IFMT) == S_IFDIR
        )
    }

    private static func defaultNodeOrder(_ lhs: FileNode, _ rhs: FileNode) -> Bool {
        if lhs.allocatedBytes != rhs.allocatedBytes {
            return lhs.allocatedBytes > rhs.allocatedBytes
        }
        if lhs.logicalBytes != rhs.logicalBytes {
            return lhs.logicalBytes > rhs.logicalBytes
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func rankingNodeOrder(_ lhs: FileNode, _ rhs: FileNode) -> Bool {
        let lhsScore = max(lhs.allocatedBytes, lhs.logicalBytes)
        let rhsScore = max(rhs.allocatedBytes, rhs.logicalBytes)
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func isPath(_ path: String, insideOrEqualTo rootPath: String) -> Bool {
        let pathComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let rootComponents = URL(fileURLWithPath: rootPath).standardizedFileURL.pathComponents
        guard pathComponents.count >= rootComponents.count else { return false }
        return zip(pathComponents, rootComponents).allSatisfy(==)
    }

    private static func replacingPrefix(
        _ path: String,
        sourcePath: String,
        destinationPath: String
    ) -> String {
        let pathComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let sourceComponents = URL(fileURLWithPath: sourcePath)
            .standardizedFileURL.pathComponents
        guard pathComponents.count >= sourceComponents.count,
              zip(pathComponents, sourceComponents).allSatisfy(==) else {
            return path
        }
        var result = URL(fileURLWithPath: destinationPath)
        for component in pathComponents.dropFirst(sourceComponents.count) {
            result.appendPathComponent(component)
        }
        return result.standardizedFileURL.path
    }
}
