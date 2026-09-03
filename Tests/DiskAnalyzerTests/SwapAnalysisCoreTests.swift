import Foundation
import SwapAnalysisCore
import Testing

@Suite("Swap analysis accuracy")
struct SwapAnalysisCoreTests {
    @Test("Nested helper executables are grouped under the outer application")
    func nestedApplicationPathResolution() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        #expect(
            ApplicationPathResolver.firstApplicationBundlePath(in: helper)
                == "/Applications/Google Chrome.app"
        )
        #expect(ApplicationPathResolver.firstApplicationBundlePath(in: "/usr/bin/python3") == nil)
    }

    @Test("Application estimates never exceed real system swap usage")
    func estimatesStayWithinSystemTotal() throws {
        let processes = [
            sample(pid: 10, appKey: "app:a", appName: "A", compressorBytes: 900),
            sample(pid: 11, appKey: "app:a", appName: "A", compressorBytes: 900),
            sample(pid: 20, appKey: "app:b", appName: "B", compressorBytes: 700)
        ]
        let system = metrics(swapUsed: 1_000, compressorUncompressed: 1_000)
        let groups = SwapAttributionEstimator.makeGroups(
            processes: processes,
            system: system
        )

        let groupA = try #require(groups.first { $0.id == "app:a" })
        #expect(groupA.processes.count == 2)
        #expect(groupA.compressorBackedBytes == 1_800)
        #expect(groups.reduce(UInt64(0)) { $0 + $1.estimatedSwapBytes } <= 1_000)
    }

    @Test("Live system probe returns internally consistent totals")
    func liveSystemProbeIsConsistent() throws {
        let snapshot = try SystemProbe.capture()

        #expect(snapshot.system.physicalMemoryBytes > 0)
        #expect(snapshot.system.kernelPageSize > 0)
        #expect(snapshot.system.swapTotalBytes >= snapshot.system.swapUsedBytes)
        #expect(snapshot.coverage.discoveredProcesses > 0)
        #expect(snapshot.coverage.readableProcesses > 0)
        #expect(snapshot.attributedSwapBytes <= snapshot.system.swapUsedBytes)
        #expect(
            snapshot.attributedSwapBytes + snapshot.unattributedSwapBytes
                == snapshot.system.swapUsedBytes
        )
    }

    @Test("A cancelled probe stops instead of publishing a partial snapshot")
    func cancelledProbeStops() async {
        let task = Task.detached {
            try SystemProbe.capture()
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("A cancelled probe unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
    }

    private func sample(
        pid: Int32,
        appKey: String,
        appName: String,
        compressorBytes: UInt64
    ) -> ProcessMemorySample {
        ProcessMemorySample(
            id: pid,
            parentPID: 1,
            processName: "process-\(pid)",
            executablePath: "/tmp/process-\(pid)",
            applicationKey: appKey,
            applicationName: appName,
            applicationBundlePath: nil,
            compressorBackedBytes: compressorBytes,
            residentBytes: 100,
            virtualBytes: 0,
            regionCount: 1,
            usesTranslatedArchitecture: false
        )
    }

    private func metrics(
        swapUsed: UInt64,
        compressorUncompressed: UInt64
    ) -> SystemMemoryMetrics {
        SystemMemoryMetrics(
            physicalMemoryBytes: 16_000,
            swapTotalBytes: 4_000,
            swapUsedBytes: swapUsed,
            swapFreeBytes: 4_000 - swapUsed,
            compressorStorageBytes: 0,
            compressorUncompressedBytes: compressorUncompressed,
            swapInsPages: 0,
            swapOutsPages: 0,
            kernelPageSize: 4_096
        )
    }
}
