import Foundation

public struct SMARTHealthSnapshot: Sendable, Equatable {
    public let capturedAt: Date
    public let deviceBSDName: String
    public let executablePath: String
    public let exitStatus: Int32
    public let overallPassed: Bool?
    public let criticalWarning: UInt64?
    public let temperatureCelsius: Int?
    public let availableSparePercent: Int?
    public let availableSpareThresholdPercent: Int?
    public let percentageUsed: Int?
    public let dataUnitsRead: UInt64?
    public let dataUnitsWritten: UInt64?
    public let hostReadCommands: UInt64?
    public let hostWriteCommands: UInt64?
    public let controllerBusyTimeMinutes: UInt64?
    public let powerCycles: UInt64?
    public let powerOnHours: UInt64?
    public let unsafeShutdowns: UInt64?
    public let mediaAndDataIntegrityErrors: UInt64?
    public let errorInformationLogEntries: UInt64?

    public init(
        capturedAt: Date,
        deviceBSDName: String,
        executablePath: String,
        exitStatus: Int32 = 0,
        overallPassed: Bool? = nil,
        criticalWarning: UInt64? = nil,
        temperatureCelsius: Int? = nil,
        availableSparePercent: Int? = nil,
        availableSpareThresholdPercent: Int? = nil,
        percentageUsed: Int? = nil,
        dataUnitsRead: UInt64? = nil,
        dataUnitsWritten: UInt64? = nil,
        hostReadCommands: UInt64? = nil,
        hostWriteCommands: UInt64? = nil,
        controllerBusyTimeMinutes: UInt64? = nil,
        powerCycles: UInt64? = nil,
        powerOnHours: UInt64? = nil,
        unsafeShutdowns: UInt64? = nil,
        mediaAndDataIntegrityErrors: UInt64? = nil,
        errorInformationLogEntries: UInt64? = nil
    ) {
        self.capturedAt = capturedAt
        self.deviceBSDName = deviceBSDName
        self.executablePath = executablePath
        self.exitStatus = exitStatus
        self.overallPassed = overallPassed
        self.criticalWarning = criticalWarning
        self.temperatureCelsius = temperatureCelsius
        self.availableSparePercent = availableSparePercent
        self.availableSpareThresholdPercent = availableSpareThresholdPercent
        self.percentageUsed = percentageUsed
        self.dataUnitsRead = dataUnitsRead
        self.dataUnitsWritten = dataUnitsWritten
        self.hostReadCommands = hostReadCommands
        self.hostWriteCommands = hostWriteCommands
        self.controllerBusyTimeMinutes = controllerBusyTimeMinutes
        self.powerCycles = powerCycles
        self.powerOnHours = powerOnHours
        self.unsafeShutdowns = unsafeShutdowns
        self.mediaAndDataIntegrityErrors = mediaAndDataIntegrityErrors
        self.errorInformationLogEntries = errorInformationLogEntries
    }

    public var dataBytesRead: UInt64? {
        Self.bytes(forDataUnits: dataUnitsRead)
    }

    public var dataBytesWritten: UInt64? {
        Self.bytes(forDataUnits: dataUnitsWritten)
    }

    /// A user-facing endurance percentage derived from NVMe `percentage_used`.
    /// The source counter may exceed 100, so the displayed remainder is clamped.
    public var estimatedRemainingLifePercent: Int? {
        guard let percentageUsed else { return nil }
        if percentageUsed <= 0 { return 100 }
        if percentageUsed >= 100 { return 0 }
        return 100 - percentageUsed
    }

    private static func bytes(forDataUnits units: UInt64?) -> UInt64? {
        guard let units else { return nil }
        let (bytes, overflow) = units.multipliedReportingOverflow(by: 512_000)
        return overflow ? nil : bytes
    }
}

public enum SMARTHealthProbeError: Error, Sendable, Equatable {
    case notInstalled
    case invalidDeviceName(String)
    case launchFailed(String)
    case timedOut
    case invalidJSON
    case dataUnavailable(exitStatus: Int32, message: String?)
}

public enum SMARTHealthProbe {
    private static let executableCandidates = [
        "/opt/homebrew/bin/smartctl",
        "/opt/homebrew/sbin/smartctl",
        "/usr/local/bin/smartctl",
        "/usr/local/sbin/smartctl",
        "/opt/local/bin/smartctl",
        "/opt/local/sbin/smartctl"
    ]

    public static func executableURL(
        fileManager: FileManager = .default
    ) -> URL? {
        executableCandidates.lazy
            .map { URL(fileURLWithPath: $0) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    public static func capture(
        deviceBSDName: String,
        executableURL requestedExecutableURL: URL? = nil,
        timeout: TimeInterval = 8
    ) throws -> SMARTHealthSnapshot {
        guard deviceBSDName.range(
            of: #"^disk[0-9]+$"#,
            options: .regularExpression
        ) != nil else {
            throw SMARTHealthProbeError.invalidDeviceName(deviceBSDName)
        }
        guard let executableURL = requestedExecutableURL ?? executableURL() else {
            throw SMARTHealthProbeError.notInstalled
        }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = [
            "--json",
            "--health",
            "--attributes",
            "/dev/\(deviceBSDName)"
        ]
        process.standardOutput = standardOutput
        process.standardError = standardError

        let completion = DispatchGroup()
        completion.enter()
        process.terminationHandler = { _ in completion.leave() }

        do {
            try process.run()
        } catch {
            throw SMARTHealthProbeError.launchFailed(error.localizedDescription)
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        while completion.wait(timeout: .now() + 0.05) == .timedOut {
            do {
                try Task.checkCancellation()
            } catch {
                terminate(process, completion: completion)
                throw error
            }
            if ProcessInfo.processInfo.systemUptime - startedAt >= timeout {
                terminate(process, completion: completion)
                throw SMARTHealthProbeError.timedOut
            }
        }

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let diagnosticData = standardError.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = String(data: diagnosticData, encoding: .utf8)

        return try decode(
            output,
            capturedAt: Date(),
            deviceBSDName: deviceBSDName,
            executablePath: executableURL.path,
            processExitStatus: process.terminationStatus,
            diagnosticMessage: diagnostic
        )
    }

    public static func decode(
        _ data: Data,
        capturedAt: Date,
        deviceBSDName: String,
        executablePath: String,
        processExitStatus: Int32,
        diagnosticMessage: String? = nil
    ) throws -> SMARTHealthSnapshot {
        let raw: RawSMARTDocument
        do {
            raw = try JSONDecoder().decode(RawSMARTDocument.self, from: data)
        } catch {
            throw SMARTHealthProbeError.invalidJSON
        }

        let exitStatus = raw.smartctl?.exitStatus ?? processExitStatus
        guard raw.smartStatus?.passed != nil
                || raw.temperature?.current != nil
                || raw.nvmeHealth != nil else {
            let reportedMessage = raw.smartctl?.messages?
                .first(where: { $0.severity == "error" })?.string
                ?? raw.smartctl?.messages?.first?.string
                ?? diagnosticMessage
            throw SMARTHealthProbeError.dataUnavailable(
                exitStatus: exitStatus,
                message: boundedMessage(reportedMessage)
            )
        }

        let health = raw.nvmeHealth
        return SMARTHealthSnapshot(
            capturedAt: capturedAt,
            deviceBSDName: deviceBSDName,
            executablePath: executablePath,
            exitStatus: exitStatus,
            overallPassed: raw.smartStatus?.passed,
            criticalWarning: health?.criticalWarning,
            temperatureCelsius: health?.temperature ?? raw.temperature?.current,
            availableSparePercent: health?.availableSpare,
            availableSpareThresholdPercent: health?.availableSpareThreshold,
            percentageUsed: health?.percentageUsed,
            dataUnitsRead: health?.dataUnitsRead,
            dataUnitsWritten: health?.dataUnitsWritten,
            hostReadCommands: health?.hostReads,
            hostWriteCommands: health?.hostWrites,
            controllerBusyTimeMinutes: health?.controllerBusyTime,
            powerCycles: health?.powerCycles,
            powerOnHours: health?.powerOnHours,
            unsafeShutdowns: health?.unsafeShutdowns,
            mediaAndDataIntegrityErrors: health?.mediaErrors,
            errorInformationLogEntries: health?.errorLogEntries
        )
    }

    private static func boundedMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(300))
    }

    private static func terminate(
        _ process: Process,
        completion: DispatchGroup
    ) {
        if process.isRunning { process.terminate() }
        _ = completion.wait(timeout: .now() + 1)
    }
}

private struct RawSMARTDocument: Decodable {
    let smartctl: RawSMARTCTL?
    let smartStatus: RawSMARTStatus?
    let temperature: RawSMARTTemperature?
    let nvmeHealth: RawNVMeHealth?

    enum CodingKeys: String, CodingKey {
        case smartctl
        case smartStatus = "smart_status"
        case temperature
        case nvmeHealth = "nvme_smart_health_information_log"
    }
}

private struct RawSMARTCTL: Decodable {
    let exitStatus: Int32?
    let messages: [RawSMARTMessage]?

    enum CodingKeys: String, CodingKey {
        case exitStatus = "exit_status"
        case messages
    }
}

private struct RawSMARTMessage: Decodable {
    let string: String
    let severity: String?
}

private struct RawSMARTStatus: Decodable {
    let passed: Bool?
}

private struct RawSMARTTemperature: Decodable {
    let current: Int?
}

private struct RawNVMeHealth: Decodable {
    let criticalWarning: UInt64?
    let temperature: Int?
    let availableSpare: Int?
    let availableSpareThreshold: Int?
    let percentageUsed: Int?
    let dataUnitsRead: UInt64?
    let dataUnitsWritten: UInt64?
    let hostReads: UInt64?
    let hostWrites: UInt64?
    let controllerBusyTime: UInt64?
    let powerCycles: UInt64?
    let powerOnHours: UInt64?
    let unsafeShutdowns: UInt64?
    let mediaErrors: UInt64?
    let errorLogEntries: UInt64?

    enum CodingKeys: String, CodingKey {
        case criticalWarning = "critical_warning"
        case temperature
        case availableSpare = "available_spare"
        case availableSpareThreshold = "available_spare_threshold"
        case percentageUsed = "percentage_used"
        case dataUnitsRead = "data_units_read"
        case dataUnitsWritten = "data_units_written"
        case hostReads = "host_reads"
        case hostWrites = "host_writes"
        case controllerBusyTime = "controller_busy_time"
        case powerCycles = "power_cycles"
        case powerOnHours = "power_on_hours"
        case unsafeShutdowns = "unsafe_shutdowns"
        case mediaErrors = "media_errors"
        case errorLogEntries = "num_err_log_entries"
    }
}
