import DiskArbitration
import Foundation
import IOKit
import IOKit.storage

public enum DiskStatusProbe {
    public static func capture(
        volumeURL: URL = URL(fileURLWithPath: "/", isDirectory: true)
    ) throws -> DiskIOSnapshot {
        let startedAt = Date()
        try Task.checkCancellation()

        let volume = try readVolumeMetadata(at: volumeURL)
        let device = try readDeviceCounters(volumeBSDName: volume.volumeBSDName)
        try Task.checkCancellation()
        let processScan = try ProcessDiskIOScanner.scan()

        return DiskIOSnapshot(
            capturedAt: Date(),
            scanDuration: Date().timeIntervalSince(startedAt),
            volume: DiskVolumeMetrics(
                name: volume.name,
                mountPath: volume.mountPath,
                totalBytes: volume.totalBytes,
                availableBytes: volume.availableBytes,
                volumeBSDName: volume.volumeBSDName,
                physicalBSDName: device.physicalBSDName
            ),
            device: device.counters,
            processes: processScan.processes,
            coverage: processScan.coverage
        )
    }

    private static func readVolumeMetadata(at url: URL) throws -> VolumeMetadata {
        let standardizedURL = url.standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let values = try? standardizedURL.resourceValues(forKeys: keys),
              let totalCapacity = values.volumeTotalCapacity,
              totalCapacity > 0 else {
            throw DiskStatusProbeError.volumeMetadataUnavailable(path: standardizedURL.path)
        }

        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(
                kCFAllocatorDefault,
                session,
                standardizedURL as CFURL
              ),
              let bsdNamePointer = DADiskGetBSDName(disk) else {
            throw DiskStatusProbeError.volumeDeviceUnavailable(path: standardizedURL.path)
        }

        let availableCapacity = values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)
        return VolumeMetadata(
            name: values.volumeName ?? standardizedURL.lastPathComponent,
            mountPath: standardizedURL.path,
            totalBytes: UInt64(totalCapacity),
            availableBytes: UInt64(max(availableCapacity, 0)),
            volumeBSDName: String(cString: bsdNamePointer)
        )
    }

    private static func readDeviceCounters(
        volumeBSDName: String
    ) throws -> DeviceCounterResult {
        let media = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOBSDNameMatching(kIOMainPortDefault, 0, volumeBSDName)
        )
        guard media != 0 else {
            throw DiskStatusProbeError.volumeDeviceUnavailable(path: volumeBSDName)
        }

        var current = media
        defer {
            if current != 0 { IOObjectRelease(current) }
        }

        var physicalBSDName = volumeBSDName
        for _ in 0..<32 {
            try Task.checkCancellation()

            if let entryBSDName = registryString(
                entry: current,
                key: kIOBSDNameKey as String
            ), !entryBSDName.isEmpty {
                physicalBSDName = entryBSDName
            }

            if IOObjectConformsTo(current, kIOBlockStorageDriverClass) != 0 {
                guard let rawStatistics = IORegistryEntryCreateCFProperty(
                    current,
                    kIOBlockStorageDriverStatisticsKey as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue(),
                      let statistics = rawStatistics as? [String: NSNumber],
                      let readBytes = statistics[
                        kIOBlockStorageDriverStatisticsBytesReadKey
                      ]?.uint64Value,
                      let writtenBytes = statistics[
                        kIOBlockStorageDriverStatisticsBytesWrittenKey
                      ]?.uint64Value else {
                    throw DiskStatusProbeError.deviceStatisticsUnavailable(
                        device: physicalBSDName
                    )
                }

                return DeviceCounterResult(
                    counters: DiskDeviceCounters(
                        bytesRead: readBytes,
                        bytesWritten: writtenBytes
                    ),
                    physicalBSDName: physicalBSDName
                )
            }

            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            guard result == KERN_SUCCESS, parent != 0 else {
                throw DiskStatusProbeError.ioKit(code: result)
            }
            IOObjectRelease(current)
            current = parent
        }

        throw DiskStatusProbeError.deviceStatisticsUnavailable(device: physicalBSDName)
    }

    private static func registryString(
        entry: io_registry_entry_t,
        key: String
    ) -> String? {
        IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String
    }
}

private struct VolumeMetadata {
    let name: String
    let mountPath: String
    let totalBytes: UInt64
    let availableBytes: UInt64
    let volumeBSDName: String
}

private struct DeviceCounterResult {
    let counters: DiskDeviceCounters
    let physicalBSDName: String
}
