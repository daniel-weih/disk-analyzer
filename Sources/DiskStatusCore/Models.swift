import Foundation

public struct DiskVolumeMetrics: Sendable, Equatable {
    public let name: String
    public let mountPath: String
    public let totalBytes: UInt64
    public let availableBytes: UInt64
    public let volumeBSDName: String
    public let physicalBSDName: String

    public init(
        name: String,
        mountPath: String,
        totalBytes: UInt64,
        availableBytes: UInt64,
        volumeBSDName: String,
        physicalBSDName: String
    ) {
        self.name = name
        self.mountPath = mountPath
        self.totalBytes = totalBytes
        self.availableBytes = min(availableBytes, totalBytes)
        self.volumeBSDName = volumeBSDName
        self.physicalBSDName = physicalBSDName
    }

    public var usedBytes: UInt64 {
        totalBytes - availableBytes
    }
}

public struct DiskDeviceCounters: Sendable, Equatable {
    public let bytesRead: UInt64
    public let bytesWritten: UInt64

    public init(bytesRead: UInt64, bytesWritten: UInt64) {
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
    }

    public static let zero = DiskDeviceCounters(bytesRead: 0, bytesWritten: 0)
}

public struct ProcessDiskIOSample: Identifiable, Sendable, Equatable {
    public let id: Int32
    public let parentPID: Int32
    public let processStartTime: UInt64
    public let processName: String
    public let executablePath: String
    public let applicationKey: String
    public let applicationName: String
    public let applicationBundlePath: String?
    public let bytesRead: UInt64
    public let bytesWritten: UInt64

    public init(
        id: Int32,
        parentPID: Int32,
        processStartTime: UInt64,
        processName: String,
        executablePath: String,
        applicationKey: String,
        applicationName: String,
        applicationBundlePath: String?,
        bytesRead: UInt64,
        bytesWritten: UInt64
    ) {
        self.id = id
        self.parentPID = parentPID
        self.processStartTime = processStartTime
        self.processName = processName
        self.executablePath = executablePath
        self.applicationKey = applicationKey
        self.applicationName = applicationName
        self.applicationBundlePath = applicationBundlePath
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
    }
}

public struct DiskIOCoverage: Sendable, Equatable {
    public let discoveredProcesses: Int
    public let readableProcesses: Int
    public let permissionDeniedProcesses: Int
    public let vanishedProcesses: Int
    public let unavailableProcesses: Int

    public init(
        discoveredProcesses: Int,
        readableProcesses: Int,
        permissionDeniedProcesses: Int,
        vanishedProcesses: Int,
        unavailableProcesses: Int
    ) {
        self.discoveredProcesses = discoveredProcesses
        self.readableProcesses = readableProcesses
        self.permissionDeniedProcesses = permissionDeniedProcesses
        self.vanishedProcesses = vanishedProcesses
        self.unavailableProcesses = unavailableProcesses
    }

    public static let zero = DiskIOCoverage(
        discoveredProcesses: 0,
        readableProcesses: 0,
        permissionDeniedProcesses: 0,
        vanishedProcesses: 0,
        unavailableProcesses: 0
    )
}

public struct DiskIOSnapshot: Sendable, Equatable {
    public let capturedAt: Date
    public let scanDuration: TimeInterval
    public let volume: DiskVolumeMetrics
    public let device: DiskDeviceCounters
    public let processes: [ProcessDiskIOSample]
    public let coverage: DiskIOCoverage

    public init(
        capturedAt: Date,
        scanDuration: TimeInterval,
        volume: DiskVolumeMetrics,
        device: DiskDeviceCounters,
        processes: [ProcessDiskIOSample],
        coverage: DiskIOCoverage
    ) {
        self.capturedAt = capturedAt
        self.scanDuration = scanDuration
        self.volume = volume
        self.device = device
        self.processes = processes
        self.coverage = coverage
    }
}

public struct ProcessDiskIORate: Identifiable, Sendable, Equatable {
    public let id: Int32
    public let processName: String
    public let executablePath: String
    public let applicationKey: String
    public let applicationName: String
    public let applicationBundlePath: String?
    public let bytesReadPerSecond: Double
    public let bytesWrittenPerSecond: Double

    public init(
        id: Int32,
        processName: String,
        executablePath: String,
        applicationKey: String,
        applicationName: String,
        applicationBundlePath: String?,
        bytesReadPerSecond: Double,
        bytesWrittenPerSecond: Double
    ) {
        self.id = id
        self.processName = processName
        self.executablePath = executablePath
        self.applicationKey = applicationKey
        self.applicationName = applicationName
        self.applicationBundlePath = applicationBundlePath
        self.bytesReadPerSecond = bytesReadPerSecond
        self.bytesWrittenPerSecond = bytesWrittenPerSecond
    }
}

public struct DiskIORates: Sendable, Equatable {
    public let interval: TimeInterval
    public let deviceReadBytesPerSecond: Double
    public let deviceWriteBytesPerSecond: Double
    public let processes: [ProcessDiskIORate]

    public init(
        interval: TimeInterval,
        deviceReadBytesPerSecond: Double,
        deviceWriteBytesPerSecond: Double,
        processes: [ProcessDiskIORate]
    ) {
        self.interval = interval
        self.deviceReadBytesPerSecond = deviceReadBytesPerSecond
        self.deviceWriteBytesPerSecond = deviceWriteBytesPerSecond
        self.processes = processes
    }

    public static let zero = DiskIORates(
        interval: 0,
        deviceReadBytesPerSecond: 0,
        deviceWriteBytesPerSecond: 0,
        processes: []
    )
}

public enum DiskIODeltaCalculator {
    public static func rates(
        previous: DiskIOSnapshot,
        current: DiskIOSnapshot
    ) -> DiskIORates {
        let interval = current.capturedAt.timeIntervalSince(previous.capturedAt)
        guard interval > 0 else { return .zero }

        let previousByPID = Dictionary(
            uniqueKeysWithValues: previous.processes.map { ($0.id, $0) }
        )
        let processRates = current.processes.compactMap { sample -> ProcessDiskIORate? in
            guard let earlier = previousByPID[sample.id],
                  earlier.processStartTime == sample.processStartTime else {
                return nil
            }
            return ProcessDiskIORate(
                id: sample.id,
                processName: sample.processName,
                executablePath: sample.executablePath,
                applicationKey: sample.applicationKey,
                applicationName: sample.applicationName,
                applicationBundlePath: sample.applicationBundlePath,
                bytesReadPerSecond: rate(
                    current: sample.bytesRead,
                    previous: earlier.bytesRead,
                    interval: interval
                ),
                bytesWrittenPerSecond: rate(
                    current: sample.bytesWritten,
                    previous: earlier.bytesWritten,
                    interval: interval
                )
            )
        }

        return DiskIORates(
            interval: interval,
            deviceReadBytesPerSecond: rate(
                current: current.device.bytesRead,
                previous: previous.device.bytesRead,
                interval: interval
            ),
            deviceWriteBytesPerSecond: rate(
                current: current.device.bytesWritten,
                previous: previous.device.bytesWritten,
                interval: interval
            ),
            processes: processRates
        )
    }

    private static func rate(
        current: UInt64,
        previous: UInt64,
        interval: TimeInterval
    ) -> Double {
        guard current >= previous else { return 0 }
        return Double(current - previous) / interval
    }
}

public enum DiskStatusProbeError: LocalizedError, Sendable, Equatable {
    case volumeMetadataUnavailable(path: String)
    case volumeDeviceUnavailable(path: String)
    case deviceStatisticsUnavailable(device: String)
    case ioKit(code: Int32)

    public var errorDescription: String? {
        switch self {
        case let .volumeMetadataUnavailable(path):
            return "Volume metadata is unavailable for \(path)"
        case let .volumeDeviceUnavailable(path):
            return "The backing disk is unavailable for \(path)"
        case let .deviceStatisticsUnavailable(device):
            return "Disk I/O statistics are unavailable for \(device)"
        case let .ioKit(code):
            return "IOKit failed with error \(code)"
        }
    }
}
