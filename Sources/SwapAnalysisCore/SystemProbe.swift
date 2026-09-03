import Darwin
import Foundation

public enum SystemProbe {
    public static func capture() throws -> SwapSnapshot {
        let startedAt = Date()
        try Task.checkCancellation()
        let system = try readSystemMemory()
        let processScan = try ProcessScanner.scan(kernelPageSize: system.kernelPageSize)
        try Task.checkCancellation()
        let groups = SwapAttributionEstimator.makeGroups(
            processes: processScan.processes,
            system: system
        )
        let attributed = min(
            system.swapUsedBytes,
            groups.reduce(UInt64(0)) { saturatedAdd($0, $1.estimatedSwapBytes) }
        )

        return SwapSnapshot(
            capturedAt: Date(),
            scanDuration: Date().timeIntervalSince(startedAt),
            system: system,
            coverage: processScan.coverage,
            groups: groups,
            attributedSwapBytes: attributed,
            unattributedSwapBytes: system.swapUsedBytes - attributed
        )
    }

    private static func readSystemMemory() throws -> SystemMemoryMetrics {
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        errno = 0
        guard withUnsafeMutablePointer(to: &swap, { pointer in
            sysctlbyname("vm.swapusage", pointer, &swapSize, nil, 0)
        }) == 0 else {
            throw ProbeError.systemCall(name: "vm.swapusage", code: errno)
        }

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &vmStats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw ProbeError.systemCall(name: "host_statistics64", code: result)
        }

        let pageSize = UInt64(vm_kernel_page_size)
        return SystemMemoryMetrics(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            swapTotalBytes: swap.xsu_total,
            swapUsedBytes: swap.xsu_used,
            swapFreeBytes: swap.xsu_avail,
            compressorStorageBytes: saturatedMultiply(UInt64(vmStats.compressor_page_count), pageSize),
            compressorUncompressedBytes: saturatedMultiply(vmStats.total_uncompressed_pages_in_compressor, pageSize),
            swapInsPages: vmStats.swapins,
            swapOutsPages: vmStats.swapouts,
            kernelPageSize: pageSize
        )
    }

    private static func saturatedMultiply(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? UInt64.max : result
    }

    private static func saturatedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : result
    }
}
