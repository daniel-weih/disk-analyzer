import DiskStatusCore
import Foundation
import Testing
@testable import DiskAnalyzer

@Suite("Disk status accuracy")
struct DiskStatusCoreTests {
    @Test("SMART JSON preserves every supported NVMe health field")
    func smartJSONDecodingPreservesMetrics() throws {
        let data = Data(#"""
        {
          "smartctl": { "exit_status": 4 },
          "smart_status": { "passed": true },
          "temperature": { "current": 34 },
          "nvme_smart_health_information_log": {
            "critical_warning": 0,
            "temperature": 35,
            "available_spare": 100,
            "available_spare_threshold": 10,
            "percentage_used": 2,
            "data_units_read": 2,
            "data_units_written": 3,
            "host_reads": 400,
            "host_writes": 500,
            "controller_busy_time": 6,
            "power_cycles": 7,
            "power_on_hours": 8,
            "unsafe_shutdowns": 9,
            "media_errors": 10,
            "num_err_log_entries": 11
          }
        }
        """#.utf8)

        let snapshot = try SMARTHealthProbe.decode(
            data,
            capturedAt: Date(timeIntervalSinceReferenceDate: 100),
            deviceBSDName: "disk0",
            executablePath: "/opt/example/smartctl",
            processExitStatus: 0
        )

        #expect(snapshot.exitStatus == 4)
        #expect(snapshot.overallPassed == true)
        #expect(snapshot.criticalWarning == 0)
        #expect(snapshot.temperatureCelsius == 35)
        #expect(snapshot.availableSparePercent == 100)
        #expect(snapshot.availableSpareThresholdPercent == 10)
        #expect(snapshot.percentageUsed == 2)
        #expect(snapshot.estimatedRemainingLifePercent == 98)
        #expect(snapshot.dataUnitsRead == 2)
        #expect(snapshot.dataUnitsWritten == 3)
        #expect(snapshot.dataBytesRead == 1_024_000)
        #expect(snapshot.dataBytesWritten == 1_536_000)
        #expect(snapshot.hostReadCommands == 400)
        #expect(snapshot.hostWriteCommands == 500)
        #expect(snapshot.controllerBusyTimeMinutes == 6)
        #expect(snapshot.powerCycles == 7)
        #expect(snapshot.powerOnHours == 8)
        #expect(snapshot.unsafeShutdowns == 9)
        #expect(snapshot.mediaAndDataIntegrityErrors == 10)
        #expect(snapshot.errorInformationLogEntries == 11)
    }

    @Test("Displayed SSD health safely inverts and clamps NVMe wear")
    func smartRemainingLifeIsClamped() {
        let base = SMARTHealthSnapshot(
            capturedAt: .now,
            deviceBSDName: "disk0",
            executablePath: "/opt/example/smartctl",
            percentageUsed: 120
        )
        let newDrive = SMARTHealthSnapshot(
            capturedAt: .now,
            deviceBSDName: "disk0",
            executablePath: "/opt/example/smartctl",
            percentageUsed: 0
        )

        #expect(base.estimatedRemainingLifePercent == 0)
        #expect(newDrive.estimatedRemainingLifePercent == 100)
    }

    @Test("SMART errors remain explicit when JSON contains no health data")
    func smartJSONWithoutHealthDataIsRejected() {
        let data = Data(#"""
        {
          "smartctl": {
            "exit_status": 2,
            "messages": [
              { "string": "Device access denied", "severity": "error" }
            ]
          }
        }
        """#.utf8)

        #expect(throws: SMARTHealthProbeError.dataUnavailable(
            exitStatus: 2,
            message: "Device access denied"
        )) {
            try SMARTHealthProbe.decode(
                data,
                capturedAt: .now,
                deviceBSDName: "disk0",
                executablePath: "/opt/example/smartctl",
                processExitStatus: 2
            )
        }
    }

    @Test("SMART device arguments accept only whole physical disks")
    func smartDeviceNameIsValidatedBeforeLaunching() {
        #expect(throws: SMARTHealthProbeError.invalidDeviceName("disk0s1")) {
            try SMARTHealthProbe.capture(
                deviceBSDName: "disk0s1",
                executableURL: URL(fileURLWithPath: "/not/used")
            )
        }
    }

    @Test("Opt-in live SMART probe reads the startup physical disk")
    func optInLiveSMARTProbe() throws {
        guard ProcessInfo.processInfo.environment["DISK_ANALYZER_TEST_LIVE_SMART"] == "1" else {
            return
        }
        let executable = try #require(SMARTHealthProbe.executableURL())
        let disk = try DiskStatusProbe.capture().volume.physicalBSDName

        let snapshot = try SMARTHealthProbe.capture(
            deviceBSDName: disk,
            executableURL: executable
        )

        #expect(snapshot.deviceBSDName == disk)
        #expect(snapshot.overallPassed != nil || snapshot.criticalWarning != nil)
        #expect(snapshot.temperatureCelsius != nil)
    }

    @Test("Device and process rates use counter differences over the measured interval")
    func ratesUseMeasuredCounterDifferences() throws {
        let previous = snapshot(
            time: 100,
            deviceRead: 1_000,
            deviceWrite: 2_000,
            processStartTime: 55,
            processRead: 100,
            processWrite: 200
        )
        let current = snapshot(
            time: 102,
            deviceRead: 1_600,
            deviceWrite: 2_600,
            processStartTime: 55,
            processRead: 500,
            processWrite: 800
        )

        let rates = DiskIODeltaCalculator.rates(previous: previous, current: current)

        #expect(rates.interval == 2)
        #expect(rates.deviceReadBytesPerSecond == 300)
        #expect(rates.deviceWriteBytesPerSecond == 300)
        let process = try #require(rates.processes.first)
        #expect(process.bytesReadPerSecond == 200)
        #expect(process.bytesWrittenPerSecond == 300)
    }

    @Test("A reused PID never inherits the previous process counters")
    func reusedPIDDoesNotCreateFalseActivity() {
        let previous = snapshot(
            time: 100,
            deviceRead: 1_000,
            deviceWrite: 2_000,
            processStartTime: 55,
            processRead: 900_000,
            processWrite: 800_000
        )
        let current = snapshot(
            time: 101,
            deviceRead: 1_100,
            deviceWrite: 2_100,
            processStartTime: 99,
            processRead: 1_000,
            processWrite: 2_000
        )

        let rates = DiskIODeltaCalculator.rates(previous: previous, current: current)

        #expect(rates.processes.isEmpty)
    }

    @Test("Counter resets clamp rates to zero instead of underflowing")
    func counterResetClampsToZero() throws {
        let previous = snapshot(
            time: 100,
            deviceRead: 5_000,
            deviceWrite: 6_000,
            processStartTime: 55,
            processRead: 3_000,
            processWrite: 4_000
        )
        let current = snapshot(
            time: 101,
            deviceRead: 10,
            deviceWrite: 20,
            processStartTime: 55,
            processRead: 30,
            processWrite: 40
        )

        let rates = DiskIODeltaCalculator.rates(previous: previous, current: current)

        #expect(rates.deviceReadBytesPerSecond == 0)
        #expect(rates.deviceWriteBytesPerSecond == 0)
        let process = try #require(rates.processes.first)
        #expect(process.bytesReadPerSecond == 0)
        #expect(process.bytesWrittenPerSecond == 0)
    }

    @Test("Application activity aggregates readable process rates without inventing bytes")
    func applicationActivityAggregatesProcesses() throws {
        let processes = [
            processRate(pid: 1, appKey: "app:browser", name: "Browser", read: 200, write: 50),
            processRate(pid: 2, appKey: "app:browser", name: "Browser", read: 100, write: 150),
            processRate(pid: 3, appKey: "exec:indexer", name: "Indexer", read: 25, write: 0)
        ]

        let groups = DiskIOActivityAggregator.groups(from: processes)

        #expect(groups.count == 2)
        let browser = try #require(groups.first(where: { $0.id == "app:browser" }))
        #expect(browser.readBytesPerSecond == 300)
        #expect(browser.writeBytesPerSecond == 200)
        #expect(browser.processCount == 2)
        #expect(groups.first?.id == "app:browser")
    }

    @Test("History retains sixty seconds instead of sixty refresh cycles")
    func historyUsesElapsedTimeWindow() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let history = [
            historyPoint(at: now.addingTimeInterval(-70)),
            historyPoint(at: now.addingTimeInterval(-60)),
            historyPoint(at: now.addingTimeInterval(-5)),
            historyPoint(at: now.addingTimeInterval(5))
        ]

        let result = DiskIOHistoryWindow.appending(historyPoint(at: now), to: history)

        #expect(result.map(\.timestamp) == [
            now.addingTimeInterval(-60),
            now.addingTimeInterval(-5),
            now
        ])
    }

    @Test("Live probe resolves the startup volume and classifies every discovered process")
    func liveProbeIsInternallyConsistent() throws {
        let snapshot = try DiskStatusProbe.capture()

        #expect(!snapshot.volume.name.isEmpty)
        #expect(!snapshot.volume.volumeBSDName.isEmpty)
        #expect(!snapshot.volume.physicalBSDName.isEmpty)
        #expect(snapshot.volume.totalBytes > 0)
        #expect(snapshot.volume.availableBytes <= snapshot.volume.totalBytes)
        #expect(snapshot.coverage.discoveredProcesses > 0)
        #expect(snapshot.coverage.readableProcesses > 0)
        #expect(
            snapshot.coverage.readableProcesses
                + snapshot.coverage.permissionDeniedProcesses
                + snapshot.coverage.vanishedProcesses
                + snapshot.coverage.unavailableProcesses
                == snapshot.coverage.discoveredProcesses
        )
    }

    private func snapshot(
        time: TimeInterval,
        deviceRead: UInt64,
        deviceWrite: UInt64,
        processStartTime: UInt64,
        processRead: UInt64,
        processWrite: UInt64
    ) -> DiskIOSnapshot {
        DiskIOSnapshot(
            capturedAt: Date(timeIntervalSinceReferenceDate: time),
            scanDuration: 0.01,
            volume: DiskVolumeMetrics(
                name: "Sample Disk",
                mountPath: "/",
                totalBytes: 1_000_000,
                availableBytes: 400_000,
                volumeBSDName: "disk3s1",
                physicalBSDName: "disk0"
            ),
            device: DiskDeviceCounters(
                bytesRead: deviceRead,
                bytesWritten: deviceWrite
            ),
            processes: [ProcessDiskIOSample(
                id: 42,
                parentPID: 1,
                processStartTime: processStartTime,
                processName: "Sample Helper",
                executablePath: "/Applications/Sample.app/Contents/MacOS/Sample",
                applicationKey: "app:/Applications/Sample.app",
                applicationName: "Sample",
                applicationBundlePath: "/Applications/Sample.app",
                bytesRead: processRead,
                bytesWritten: processWrite
            )],
            coverage: DiskIOCoverage(
                discoveredProcesses: 1,
                readableProcesses: 1,
                permissionDeniedProcesses: 0,
                vanishedProcesses: 0,
                unavailableProcesses: 0
            )
        )
    }

    private func processRate(
        pid: Int32,
        appKey: String,
        name: String,
        read: Double,
        write: Double
    ) -> ProcessDiskIORate {
        ProcessDiskIORate(
            id: pid,
            processName: name,
            executablePath: "/usr/bin/\(name)",
            applicationKey: appKey,
            applicationName: name,
            applicationBundlePath: appKey.hasPrefix("app:")
                ? String(appKey.dropFirst(4))
                : nil,
            bytesReadPerSecond: read,
            bytesWrittenPerSecond: write
        )
    }

    private func historyPoint(at timestamp: Date) -> DiskIOHistoryPoint {
        DiskIOHistoryPoint(
            timestamp: timestamp,
            readBytesPerSecond: 1,
            writeBytesPerSecond: 2
        )
    }
}
