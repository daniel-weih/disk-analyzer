import Foundation

public struct SystemMemoryMetrics: Sendable, Equatable {
    public let physicalMemoryBytes: UInt64
    public let swapTotalBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapFreeBytes: UInt64
    public let compressorStorageBytes: UInt64
    public let compressorUncompressedBytes: UInt64
    public let swapInsPages: UInt64
    public let swapOutsPages: UInt64
    public let kernelPageSize: UInt64

    public init(
        physicalMemoryBytes: UInt64,
        swapTotalBytes: UInt64,
        swapUsedBytes: UInt64,
        swapFreeBytes: UInt64,
        compressorStorageBytes: UInt64,
        compressorUncompressedBytes: UInt64,
        swapInsPages: UInt64,
        swapOutsPages: UInt64,
        kernelPageSize: UInt64
    ) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.swapTotalBytes = swapTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapFreeBytes = swapFreeBytes
        self.compressorStorageBytes = compressorStorageBytes
        self.compressorUncompressedBytes = compressorUncompressedBytes
        self.swapInsPages = swapInsPages
        self.swapOutsPages = swapOutsPages
        self.kernelPageSize = kernelPageSize
    }

    public static let empty = SystemMemoryMetrics(
        physicalMemoryBytes: 0,
        swapTotalBytes: 0,
        swapUsedBytes: 0,
        swapFreeBytes: 0,
        compressorStorageBytes: 0,
        compressorUncompressedBytes: 0,
        swapInsPages: 0,
        swapOutsPages: 0,
        kernelPageSize: 0
    )
}

public struct ProcessMemorySample: Identifiable, Sendable, Equatable {
    public let id: Int32
    public let parentPID: Int32
    public let processName: String
    public let executablePath: String
    public let applicationKey: String
    public let applicationName: String
    public let applicationBundlePath: String?
    public let compressorBackedBytes: UInt64
    public let residentBytes: UInt64
    public let virtualBytes: UInt64
    public let regionCount: Int
    public let usesTranslatedArchitecture: Bool

    public init(
        id: Int32,
        parentPID: Int32,
        processName: String,
        executablePath: String,
        applicationKey: String,
        applicationName: String,
        applicationBundlePath: String?,
        compressorBackedBytes: UInt64,
        residentBytes: UInt64,
        virtualBytes: UInt64,
        regionCount: Int,
        usesTranslatedArchitecture: Bool
    ) {
        self.id = id
        self.parentPID = parentPID
        self.processName = processName
        self.executablePath = executablePath
        self.applicationKey = applicationKey
        self.applicationName = applicationName
        self.applicationBundlePath = applicationBundlePath
        self.compressorBackedBytes = compressorBackedBytes
        self.residentBytes = residentBytes
        self.virtualBytes = virtualBytes
        self.regionCount = regionCount
        self.usesTranslatedArchitecture = usesTranslatedArchitecture
    }
}

public struct ApplicationMemoryGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let bundlePath: String?
    public let estimatedSwapBytes: UInt64
    public let compressorBackedBytes: UInt64
    public let residentBytes: UInt64
    public let processes: [ProcessMemorySample]

    public init(
        id: String,
        name: String,
        bundlePath: String?,
        estimatedSwapBytes: UInt64,
        compressorBackedBytes: UInt64,
        residentBytes: UInt64,
        processes: [ProcessMemorySample]
    ) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.estimatedSwapBytes = estimatedSwapBytes
        self.compressorBackedBytes = compressorBackedBytes
        self.residentBytes = residentBytes
        self.processes = processes
    }
}

public struct ScanCoverage: Sendable, Equatable {
    public let discoveredProcesses: Int
    public let readableProcesses: Int
    public let permissionDeniedProcesses: Int
    public let vanishedProcesses: Int
    public let unavailableProcesses: Int
    public let regionLimitProcesses: Int

    public init(
        discoveredProcesses: Int,
        readableProcesses: Int,
        permissionDeniedProcesses: Int,
        vanishedProcesses: Int,
        unavailableProcesses: Int,
        regionLimitProcesses: Int
    ) {
        self.discoveredProcesses = discoveredProcesses
        self.readableProcesses = readableProcesses
        self.permissionDeniedProcesses = permissionDeniedProcesses
        self.vanishedProcesses = vanishedProcesses
        self.unavailableProcesses = unavailableProcesses
        self.regionLimitProcesses = regionLimitProcesses
    }

    public static let empty = ScanCoverage(
        discoveredProcesses: 0,
        readableProcesses: 0,
        permissionDeniedProcesses: 0,
        vanishedProcesses: 0,
        unavailableProcesses: 0,
        regionLimitProcesses: 0
    )
}

public struct SwapSnapshot: Sendable, Equatable {
    public let capturedAt: Date
    public let scanDuration: TimeInterval
    public let system: SystemMemoryMetrics
    public let coverage: ScanCoverage
    public let groups: [ApplicationMemoryGroup]
    public let attributedSwapBytes: UInt64
    public let unattributedSwapBytes: UInt64

    public init(
        capturedAt: Date,
        scanDuration: TimeInterval,
        system: SystemMemoryMetrics,
        coverage: ScanCoverage,
        groups: [ApplicationMemoryGroup],
        attributedSwapBytes: UInt64,
        unattributedSwapBytes: UInt64
    ) {
        self.capturedAt = capturedAt
        self.scanDuration = scanDuration
        self.system = system
        self.coverage = coverage
        self.groups = groups
        self.attributedSwapBytes = attributedSwapBytes
        self.unattributedSwapBytes = unattributedSwapBytes
    }

    public static let empty = SwapSnapshot(
        capturedAt: .distantPast,
        scanDuration: 0,
        system: .empty,
        coverage: .empty,
        groups: [],
        attributedSwapBytes: 0,
        unattributedSwapBytes: 0
    )
}

public enum ProbeError: LocalizedError, Sendable {
    case systemCall(name: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case let .systemCall(name, code):
            return "System call \(name) failed (error \(code))"
        }
    }
}
