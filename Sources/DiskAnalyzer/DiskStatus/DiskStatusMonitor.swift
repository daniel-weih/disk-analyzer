import DiskStatusCore
import Foundation

struct DiskIOHistoryPoint: Identifiable, Equatable {
    var id: Date { timestamp }
    let timestamp: Date
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
}

enum DiskIOHistoryWindow {
    static let duration: TimeInterval = 60

    static func appending(
        _ point: DiskIOHistoryPoint,
        to history: [DiskIOHistoryPoint]
    ) -> [DiskIOHistoryPoint] {
        let cutoff = point.timestamp.addingTimeInterval(-duration)
        return history.filter {
            $0.timestamp >= cutoff && $0.timestamp <= point.timestamp
        } + [point]
    }
}

struct ApplicationDiskIOActivity: Identifiable, Equatable {
    let id: String
    let name: String
    let bundlePath: String?
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
    let processCount: Int

    var totalBytesPerSecond: Double {
        readBytesPerSecond + writeBytesPerSecond
    }
}

enum DiskIOActivityAggregator {
    static func groups(from processes: [ProcessDiskIORate]) -> [ApplicationDiskIOActivity] {
        Dictionary(grouping: processes, by: \.applicationKey)
            .map { key, samples in
                ApplicationDiskIOActivity(
                    id: key,
                    name: samples.first?.applicationName ?? key,
                    bundlePath: samples.compactMap(\.applicationBundlePath).first,
                    readBytesPerSecond: samples.reduce(0) {
                        $0 + bounded($1.bytesReadPerSecond)
                    },
                    writeBytesPerSecond: samples.reduce(0) {
                        $0 + bounded($1.bytesWrittenPerSecond)
                    },
                    processCount: samples.count
                )
            }
            .filter { $0.totalBytesPerSecond > 0 }
            .sorted {
                if $0.totalBytesPerSecond != $1.totalBytesPerSecond {
                    return $0.totalBytesPerSecond > $1.totalBytesPerSecond
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private static func bounded(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }
}

@MainActor
final class DiskStatusMonitor: ObservableObject {
    static let refreshInterval: TimeInterval = 5
    static let smartRefreshInterval: TimeInterval = 60

    @Published private(set) var snapshot: DiskIOSnapshot?
    @Published private(set) var rates: DiskIORates
    @Published private(set) var history: [DiskIOHistoryPoint]
    @Published private(set) var activities: [ApplicationDiskIOActivity]
    @Published private(set) var isMonitoring = false
    @Published private(set) var isSampling = false
    @Published private(set) var hasMeasuredRates: Bool
    @Published private(set) var errorMessage: String?
    @Published private(set) var smartHealth: SMARTHealthSnapshot?
    @Published private(set) var isSMARTToolInstalled: Bool
    @Published private(set) var isSMARTLoading = false
    @Published private(set) var smartErrorMessage: String?

    private var previousSnapshot: DiskIOSnapshot?
    private var monitorTask: Task<Void, Never>?
    private var smartTask: Task<Void, Never>?
    private var smartExecutableURL: URL?
    private var lastSMARTAttempt: Date?
    private var sessionID = UUID()

    init(
        snapshot: DiskIOSnapshot? = nil,
        rates: DiskIORates = .zero,
        history: [DiskIOHistoryPoint] = [],
        isMonitoring: Bool = false,
        smartHealth: SMARTHealthSnapshot? = nil,
        isSMARTToolInstalled: Bool? = nil,
        smartErrorMessage: String? = nil
    ) {
        self.snapshot = snapshot
        self.rates = rates
        self.history = history
        self.isMonitoring = isMonitoring
        self.smartHealth = smartHealth
        self.isSMARTToolInstalled = isSMARTToolInstalled ?? (smartHealth != nil)
        self.smartErrorMessage = smartErrorMessage
        hasMeasuredRates = rates.interval > 0
        activities = DiskIOActivityAggregator.groups(from: rates.processes)
    }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        isSampling = false
        errorMessage = nil
        previousSnapshot = nil
        rates = .zero
        activities = []
        history = []
        hasMeasuredRates = false
        smartExecutableURL = SMARTHealthProbe.executableURL()
        isSMARTToolInstalled = smartExecutableURL != nil
        isSMARTLoading = false
        smartErrorMessage = nil
        lastSMARTAttempt = nil
        if !isSMARTToolInstalled { smartHealth = nil }

        let activeSessionID = UUID()
        sessionID = activeSessionID
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.capture(sessionID: activeSessionID)
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000)
                    )
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        sessionID = UUID()
        isMonitoring = false
        isSampling = false
        previousSnapshot = nil
        monitorTask?.cancel()
        monitorTask = nil
        smartTask?.cancel()
        smartTask = nil
        isSMARTLoading = false
    }

    func restart() {
        stop()
        start()
    }

    @discardableResult
    func recheckSMARTInstallation() -> Bool {
        let executableURL = SMARTHealthProbe.executableURL()
        smartExecutableURL = executableURL
        isSMARTToolInstalled = executableURL != nil
        smartErrorMessage = nil
        lastSMARTAttempt = nil

        guard executableURL != nil else {
            smartHealth = nil
            return false
        }

        if let snapshot {
            refreshSMARTIfNeeded(
                deviceBSDName: snapshot.volume.physicalBSDName,
                sessionID: sessionID
            )
        }
        return true
    }

    private func capture(sessionID activeSessionID: UUID) async {
        guard isMonitoring, activeSessionID == sessionID else { return }
        isSampling = true
        let probeTask = Task.detached(priority: .utility) {
            try DiskStatusProbe.capture()
        }

        do {
            let nextSnapshot = try await withTaskCancellationHandler {
                try await probeTask.value
            } onCancel: {
                probeTask.cancel()
            }
            guard isMonitoring, activeSessionID == sessionID, !Task.isCancelled else { return }
            apply(nextSnapshot)
            refreshSMARTIfNeeded(
                deviceBSDName: nextSnapshot.volume.physicalBSDName,
                sessionID: activeSessionID
            )
            errorMessage = nil
        } catch is CancellationError {
            // Expected when leaving the live disk-status screen.
        } catch {
            guard isMonitoring, activeSessionID == sessionID else { return }
            errorMessage = Self.localizedErrorMessage(error)
        }

        if activeSessionID == sessionID {
            isSampling = false
        }
    }

    private func apply(_ nextSnapshot: DiskIOSnapshot) {
        let nextRates: DiskIORates
        if let previousSnapshot {
            nextRates = DiskIODeltaCalculator.rates(
                previous: previousSnapshot,
                current: nextSnapshot
            )
            hasMeasuredRates = nextRates.interval > 0
        } else {
            nextRates = .zero
            hasMeasuredRates = false
        }

        snapshot = nextSnapshot
        previousSnapshot = nextSnapshot
        rates = nextRates
        if hasMeasuredRates {
            activities = DiskIOActivityAggregator.groups(from: nextRates.processes)
            history = DiskIOHistoryWindow.appending(
                DiskIOHistoryPoint(
                    timestamp: nextSnapshot.capturedAt,
                    readBytesPerSecond: nextRates.deviceReadBytesPerSecond,
                    writeBytesPerSecond: nextRates.deviceWriteBytesPerSecond
                ),
                to: history
            )
        } else {
            activities = []
            history = []
        }
    }

    deinit {
        monitorTask?.cancel()
        smartTask?.cancel()
    }

    private func refreshSMARTIfNeeded(
        deviceBSDName: String,
        sessionID activeSessionID: UUID
    ) {
        guard isMonitoring,
              activeSessionID == sessionID,
              let smartExecutableURL,
              smartTask == nil else { return }

        let now = Date()
        if let lastSMARTAttempt,
           now.timeIntervalSince(lastSMARTAttempt) < Self.smartRefreshInterval {
            return
        }

        lastSMARTAttempt = now
        isSMARTLoading = true
        smartErrorMessage = nil
        smartTask = Task { [weak self] in
            let probeTask = Task.detached(priority: .utility) {
                try SMARTHealthProbe.capture(
                    deviceBSDName: deviceBSDName,
                    executableURL: smartExecutableURL
                )
            }

            do {
                let health = try await withTaskCancellationHandler {
                    try await probeTask.value
                } onCancel: {
                    probeTask.cancel()
                }
                guard let self,
                      self.isMonitoring,
                      activeSessionID == self.sessionID,
                      !Task.isCancelled else { return }
                self.smartHealth = health
                self.smartErrorMessage = nil
            } catch is CancellationError {
                // Expected when leaving the disk-status screen.
            } catch {
                guard let self,
                      self.isMonitoring,
                      activeSessionID == self.sessionID else { return }
                self.smartErrorMessage = Self.localizedSMARTError(error)
            }

            guard let self, activeSessionID == self.sessionID else { return }
            self.isSMARTLoading = false
            self.smartTask = nil
        }
    }

    private static func localizedErrorMessage(_ error: Error) -> String {
        guard let probeError = error as? DiskStatusProbeError else {
            return error.localizedDescription
        }
        switch probeError {
        case let .volumeMetadataUnavailable(path):
            return L10n.text("disk_status.error.volume_metadata", path)
        case let .volumeDeviceUnavailable(path):
            return L10n.text("disk_status.error.volume_device", path)
        case let .deviceStatisticsUnavailable(device):
            return L10n.text("disk_status.error.device_statistics", device)
        case let .ioKit(code):
            return L10n.text("disk_status.error.iokit", Int(code).formatted())
        }
    }

    private static func localizedSMARTError(_ error: Error) -> String {
        guard let probeError = error as? SMARTHealthProbeError else {
            return error.localizedDescription
        }
        switch probeError {
        case .notInstalled:
            return L10n.text("smart.error.not_installed")
        case let .invalidDeviceName(device):
            return L10n.text("smart.error.invalid_device", device)
        case let .launchFailed(message):
            return L10n.text("smart.error.launch", message)
        case .timedOut:
            return L10n.text("smart.error.timeout")
        case .invalidJSON:
            return L10n.text("smart.error.invalid_json")
        case let .dataUnavailable(exitStatus, message):
            if let message {
                return L10n.text(
                    "smart.error.unavailable_with_detail",
                    Int(exitStatus).formatted(),
                    message
                )
            }
            return L10n.text(
                "smart.error.unavailable",
                Int(exitStatus).formatted()
            )
        }
    }
}
