import Darwin
import Foundation

struct ProcessScanResult {
    let processes: [ProcessMemorySample]
    let coverage: ScanCoverage
}

enum ProcessScanner {
    private static let maximumRegionsPerProcess = 200_000

    static func scan(kernelPageSize: UInt64) throws -> ProcessScanResult {
        let pids = listProcessIDs()
        let metadata = pids.map(readMetadata)
        let metadataByPID = Dictionary(uniqueKeysWithValues: metadata.map { ($0.pid, $0) })

        var nameCache: [String: String] = [:]
        var samples: [ProcessMemorySample] = []
        var readable = 0
        var denied = 0
        var vanished = 0
        var unavailable = 0
        var limited = 0

        for process in metadata {
            try Task.checkCancellation()
            let targetPageSize = effectivePageSize(
                cpuType: process.cpuType,
                kernelPageSize: kernelPageSize
            )

            switch try scanRegions(pid: process.pid, pageSize: targetPageSize) {
            case let .success(compressorBackedBytes, regionCount, hitLimit):
                readable += 1
                if hitLimit { limited += 1 }

                let identity = resolveApplicationIdentity(
                    for: process,
                    metadataByPID: metadataByPID,
                    nameCache: &nameCache
                )
                let task = readTaskInfo(pid: process.pid)

                samples.append(ProcessMemorySample(
                    id: process.pid,
                    parentPID: process.parentPID,
                    processName: process.name,
                    executablePath: process.executablePath,
                    applicationKey: identity.key,
                    applicationName: identity.name,
                    applicationBundlePath: identity.bundlePath,
                    compressorBackedBytes: compressorBackedBytes,
                    residentBytes: task?.pti_resident_size ?? 0,
                    virtualBytes: task?.pti_virtual_size ?? 0,
                    regionCount: regionCount,
                    usesTranslatedArchitecture: isTranslated(cpuType: process.cpuType)
                ))

            case .permissionDenied:
                denied += 1
            case .vanished:
                vanished += 1
            case .unavailable:
                unavailable += 1
            }
        }

        return ProcessScanResult(
            processes: samples,
            coverage: ScanCoverage(
                discoveredProcesses: pids.count,
                readableProcesses: readable,
                permissionDeniedProcesses: denied,
                vanishedProcesses: vanished,
                unavailableProcesses: unavailable,
                regionLimitProcesses: limited
            )
        )
    }

    private static func listProcessIDs() -> [pid_t] {
        let requiredBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard requiredBytes > 0 else { return [] }

        let extraSlots = 128
        var pids = [pid_t](
            repeating: 0,
            count: Int(requiredBytes) / MemoryLayout<pid_t>.size + extraSlots
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
        var uid: uid_t = UInt32.max

        var bsdInfo = proc_bsdinfo()
        let fullResult = withUnsafeMutablePointer(to: &bsdInfo) {
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                $0,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
        }
        if fullResult == MemoryLayout<proc_bsdinfo>.size {
            parentPID = pid_t(bsdInfo.pbi_ppid)
            uid = bsdInfo.pbi_uid
        } else {
            var shortInfo = proc_bsdshortinfo()
            let shortResult = withUnsafeMutablePointer(to: &shortInfo) {
                proc_pidinfo(
                    pid,
                    PROC_PIDT_SHORTBSDINFO,
                    0,
                    $0,
                    Int32(MemoryLayout<proc_bsdshortinfo>.size)
                )
            }
            if shortResult == MemoryLayout<proc_bsdshortinfo>.size {
                parentPID = pid_t(shortInfo.pbsi_ppid)
                uid = shortInfo.pbsi_uid
            }
        }

        let executablePath = readExecutablePath(pid: pid)
        let name = readProcessName(pid: pid)
        let fallbackName = URL(fileURLWithPath: executablePath).lastPathComponent

        return ProcessMetadata(
            pid: pid,
            parentPID: parentPID,
            uid: uid,
            name: name.isEmpty ? (fallbackName.isEmpty ? "PID \(pid)" : fallbackName) : name,
            executablePath: executablePath,
            cpuType: readCPUType(pid: pid)
        )
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
        // PROC_PIDPATHINFO_MAXSIZE is a macro expression that Swift does not
        // import, so keep the SDK's documented 4 * MAXPATHLEN allocation here.
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

    private static func readCPUType(pid: pid_t) -> cpu_type_t? {
        // PROC_PIDARCHINFO (flavor 19) is available on current macOS releases,
        // but older SDK headers do not expose its declarations. Keep the
        // two-field ABI local so the project can still compile against those
        // SDKs; an unsupported runtime simply returns no architecture data.
        var info = ProcessArchitectureInfo()
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(
                pid,
                processArchitectureInfoFlavor,
                0,
                $0,
                Int32(MemoryLayout<ProcessArchitectureInfo>.size)
            )
        }
        return result == MemoryLayout<ProcessArchitectureInfo>.size ? info.cpuType : nil
    }

    private static func readTaskInfo(pid: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(
                pid,
                PROC_PIDTASKINFO,
                0,
                $0,
                Int32(MemoryLayout<proc_taskinfo>.size)
            )
        }
        return result == MemoryLayout<proc_taskinfo>.size ? info : nil
    }

    private static func scanRegions(
        pid: pid_t,
        pageSize: UInt64
    ) throws -> RegionScanResult {
        var address: UInt64 = 0
        var pageCount: UInt64 = 0
        var regionCount = 0

        while regionCount < maximumRegionsPerProcess {
            if regionCount.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            var info = proc_regioninfo()
            errno = 0
            let result = withUnsafeMutablePointer(to: &info) {
                proc_pidinfo(
                    pid,
                    PROC_PIDREGIONINFO,
                    address,
                    $0,
                    Int32(MemoryLayout<proc_regioninfo>.size)
                )
            }

            guard result == MemoryLayout<proc_regioninfo>.size, info.pri_size > 0 else {
                let code = errno
                if regionCount > 0, code == 0 || code == EINVAL {
                    return .success(
                        bytes: saturatedMultiply(pageCount, pageSize),
                        regions: regionCount,
                        hitLimit: false
                    )
                }
                if code == EPERM || code == EACCES {
                    return .permissionDenied
                }
                if code == ESRCH {
                    return .vanished
                }
                return .unavailable
            }

            pageCount = saturatedAdd(pageCount, UInt64(info.pri_pages_swapped_out))
            regionCount += 1

            let nextAddress = info.pri_address.addingReportingOverflow(info.pri_size)
            guard !nextAddress.overflow, nextAddress.partialValue > address else {
                return .success(
                    bytes: saturatedMultiply(pageCount, pageSize),
                    regions: regionCount,
                    hitLimit: false
                )
            }
            address = nextAddress.partialValue
        }

        return .success(
            bytes: saturatedMultiply(pageCount, pageSize),
            regions: regionCount,
            hitLimit: true
        )
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
            if let bundlePath = ApplicationPathResolver.firstApplicationBundlePath(
                in: current.executablePath
            ) {
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

    private static func applicationName(bundlePath: String) -> String {
        let url = URL(fileURLWithPath: bundlePath)
        if let bundle = Bundle(url: url) {
            if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
               !displayName.isEmpty {
                return displayName
            }
            if let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !bundleName.isEmpty {
                return bundleName
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func effectivePageSize(
        cpuType: cpu_type_t?,
        kernelPageSize: UInt64
    ) -> UInt64 {
        #if arch(arm64)
        if cpuType == CPU_TYPE_X86_64 {
            return 4_096
        }
        #endif
        return kernelPageSize
    }

    private static func isTranslated(cpuType: cpu_type_t?) -> Bool {
        #if arch(arm64)
        return cpuType == CPU_TYPE_X86_64
        #else
        return false
        #endif
    }

    private static func saturatedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : result
    }

    private static func saturatedMultiply(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? UInt64.max : result
    }
}

private struct ProcessMetadata {
    let pid: pid_t
    let parentPID: pid_t
    let uid: uid_t
    let name: String
    let executablePath: String
    let cpuType: cpu_type_t?
}

private let processArchitectureInfoFlavor: Int32 = 19

private struct ProcessArchitectureInfo {
    var cpuType: cpu_type_t = 0
    var cpuSubtype: cpu_subtype_t = 0
}

private struct ApplicationIdentity {
    let key: String
    let name: String
    let bundlePath: String?
}

private enum RegionScanResult {
    case success(bytes: UInt64, regions: Int, hitLimit: Bool)
    case permissionDenied
    case vanished
    case unavailable
}
