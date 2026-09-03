import Darwin
import Foundation

struct ProcessDiskIOScanResult {
    let processes: [ProcessDiskIOSample]
    let coverage: DiskIOCoverage
}

enum ProcessDiskIOScanner {
    static func scan() throws -> ProcessDiskIOScanResult {
        let pids = listProcessIDs()
        let metadata = pids.map(readMetadata)
        let metadataByPID = Dictionary(uniqueKeysWithValues: metadata.map { ($0.pid, $0) })

        var nameCache: [String: String] = [:]
        var samples: [ProcessDiskIOSample] = []
        var readable = 0
        var denied = 0
        var vanished = 0
        var unavailable = 0

        for (index, process) in metadata.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }

            switch readUsage(pid: process.pid) {
            case let .success(usage):
                readable += 1
                let identity = resolveApplicationIdentity(
                    for: process,
                    metadataByPID: metadataByPID,
                    nameCache: &nameCache
                )
                samples.append(ProcessDiskIOSample(
                    id: process.pid,
                    parentPID: process.parentPID,
                    processStartTime: usage.ri_proc_start_abstime,
                    processName: process.name,
                    executablePath: process.executablePath,
                    applicationKey: identity.key,
                    applicationName: identity.name,
                    applicationBundlePath: identity.bundlePath,
                    bytesRead: usage.ri_diskio_bytesread,
                    bytesWritten: usage.ri_diskio_byteswritten
                ))
            case .permissionDenied:
                denied += 1
            case .vanished:
                vanished += 1
            case .unavailable:
                unavailable += 1
            }
        }

        return ProcessDiskIOScanResult(
            processes: samples,
            coverage: DiskIOCoverage(
                discoveredProcesses: pids.count,
                readableProcesses: readable,
                permissionDeniedProcesses: denied,
                vanishedProcesses: vanished,
                unavailableProcesses: unavailable
            )
        )
    }

    private static func listProcessIDs() -> [pid_t] {
        let requiredBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard requiredBytes > 0 else { return [] }

        var pids = [pid_t](
            repeating: 0,
            count: Int(requiredBytes) / MemoryLayout<pid_t>.size + 128
        )
        let writtenBytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard writtenBytes > 0 else { return [] }

        let count = min(pids.count, Int(writtenBytes) / MemoryLayout<pid_t>.size)
        return Array(Set(pids.prefix(count).filter { $0 > 0 })).sorted()
    }

    private static func readMetadata(pid: pid_t) -> ProcessMetadata {
        var parentPID: pid_t = 0
        var bsdInfo = proc_bsdinfo()
        let bsdResult = withUnsafeMutablePointer(to: &bsdInfo) {
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                $0,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
        }
        if bsdResult == MemoryLayout<proc_bsdinfo>.size {
            parentPID = pid_t(bsdInfo.pbi_ppid)
        }

        let executablePath = readExecutablePath(pid: pid)
        let processName = readProcessName(pid: pid)
        let fallbackName = URL(fileURLWithPath: executablePath).lastPathComponent
        return ProcessMetadata(
            pid: pid,
            parentPID: parentPID,
            name: processName.isEmpty
                ? (fallbackName.isEmpty ? "PID \(pid)" : fallbackName)
                : processName,
            executablePath: executablePath
        )
    }

    private static func readUsage(pid: pid_t) -> UsageResult {
        var usage = rusage_info_v2()
        errno = 0
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else {
            switch errno {
            case EPERM, EACCES: return .permissionDenied
            case ESRCH: return .vanished
            default: return .unavailable
            }
        }
        return .success(usage)
    }

    private static func readProcessName(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBufferPointer {
            proc_name(pid, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return "" }
        return buffer.withUnsafeBufferPointer {
            guard let baseAddress = $0.baseAddress else { return "" }
            return String(cString: baseAddress)
        }
    }

    private static func readExecutablePath(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = buffer.withUnsafeMutableBufferPointer {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return "" }
        return buffer.withUnsafeBufferPointer {
            guard let baseAddress = $0.baseAddress else { return "" }
            return String(cString: baseAddress)
        }
    }

    private static func resolveApplicationIdentity(
        for process: ProcessMetadata,
        metadataByPID: [pid_t: ProcessMetadata],
        nameCache: inout [String: String]
    ) -> ApplicationIdentity {
        var candidate: ProcessMetadata? = process
        var visited: Set<pid_t> = []

        for _ in 0..<12 {
            guard let current = candidate, visited.insert(current.pid).inserted else { break }
            if let bundlePath = firstApplicationBundlePath(in: current.executablePath) {
                let name: String
                if let cached = nameCache[bundlePath] {
                    name = cached
                } else {
                    name = applicationName(bundlePath: bundlePath)
                    nameCache[bundlePath] = name
                }
                return ApplicationIdentity(
                    key: "app:\(bundlePath)",
                    name: name,
                    bundlePath: bundlePath
                )
            }
            candidate = metadataByPID[current.parentPID]
        }

        if !process.executablePath.isEmpty {
            let executableName = URL(fileURLWithPath: process.executablePath).lastPathComponent
            return ApplicationIdentity(
                key: "exec:\(process.executablePath)",
                name: executableName.isEmpty ? process.name : executableName,
                bundlePath: nil
            )
        }

        return ApplicationIdentity(
            key: "name:\(process.name)",
            name: process.name,
            bundlePath: nil
        )
    }

    private static func firstApplicationBundlePath(in executablePath: String) -> String? {
        guard executablePath.hasPrefix("/") else { return nil }
        let components = URL(fileURLWithPath: executablePath).pathComponents
        guard let index = components.firstIndex(where: {
            $0.lowercased().hasSuffix(".app")
        }) else { return nil }
        return NSString.path(withComponents: Array(components.prefix(through: index)))
    }

    private static func applicationName(bundlePath: String) -> String {
        let url = URL(fileURLWithPath: bundlePath)
        if let bundle = Bundle(url: url) {
            if let displayName = bundle.object(
                forInfoDictionaryKey: "CFBundleDisplayName"
            ) as? String, !displayName.isEmpty {
                return displayName
            }
            if let bundleName = bundle.object(
                forInfoDictionaryKey: "CFBundleName"
            ) as? String, !bundleName.isEmpty {
                return bundleName
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }
}

private struct ProcessMetadata {
    let pid: pid_t
    let parentPID: pid_t
    let name: String
    let executablePath: String
}

private struct ApplicationIdentity {
    let key: String
    let name: String
    let bundlePath: String?
}

private enum UsageResult {
    case success(rusage_info_v2)
    case permissionDenied
    case vanished
    case unavailable
}
