import Foundation

public enum ApplicationPathResolver {
    public static func firstApplicationBundlePath(in executablePath: String) -> String? {
        guard executablePath.hasPrefix("/") else { return nil }

        let components = URL(fileURLWithPath: executablePath).pathComponents
        guard let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
            return nil
        }

        return NSString.path(withComponents: Array(components.prefix(through: index)))
    }
}

public enum SwapAttributionEstimator {
    public static func makeGroups(
        processes: [ProcessMemorySample],
        system: SystemMemoryMetrics
    ) -> [ApplicationMemoryGroup] {
        let grouped = Dictionary(grouping: processes, by: \.applicationKey)
        let attributedCompressorBytes = processes.reduce(UInt64(0)) {
            saturatedAdd($0, $1.compressorBackedBytes)
        }

        // Region data can count a shared VM object more than once. Keeping the
        // denominator at least as large as the readable total prevents the UI
        // from attributing more bytes than the real system swap usage.
        let denominator = max(system.compressorUncompressedBytes, attributedCompressorBytes)
        let scale = denominator == 0
            ? 0
            : Double(system.swapUsedBytes) / Double(denominator)

        return grouped.map { key, samples in
            let compressorBytes = samples.reduce(UInt64(0)) {
                saturatedAdd($0, $1.compressorBackedBytes)
            }
            let residentBytes = samples.reduce(UInt64(0)) {
                saturatedAdd($0, $1.residentBytes)
            }
            let estimate = scaleEstimate(compressorBytes, scale: scale)
            let orderedProcesses = samples.sorted {
                if $0.compressorBackedBytes != $1.compressorBackedBytes {
                    return $0.compressorBackedBytes > $1.compressorBackedBytes
                }
                return $0.id < $1.id
            }

            return ApplicationMemoryGroup(
                id: key,
                name: samples.first?.applicationName ?? key,
                bundlePath: samples.compactMap(\.applicationBundlePath).first,
                estimatedSwapBytes: estimate,
                compressorBackedBytes: compressorBytes,
                residentBytes: residentBytes,
                processes: orderedProcesses
            )
        }
        .sorted {
            if $0.estimatedSwapBytes != $1.estimatedSwapBytes {
                return $0.estimatedSwapBytes > $1.estimatedSwapBytes
            }
            if $0.compressorBackedBytes != $1.compressorBackedBytes {
                return $0.compressorBackedBytes > $1.compressorBackedBytes
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func scaleEstimate(_ bytes: UInt64, scale: Double) -> UInt64 {
        guard bytes > 0, scale.isFinite, scale > 0 else { return 0 }
        let value = Double(bytes) * scale
        guard value < Double(UInt64.max) else { return UInt64.max }
        return UInt64(value.rounded(.down))
    }

    private static func saturatedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : result
    }
}
