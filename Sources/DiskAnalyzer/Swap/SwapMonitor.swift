import Foundation
import SwapAnalysisCore

enum AutoRefreshInterval: Int, CaseIterable, Identifiable {
    case off = 0
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case oneMinute = 60

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: return L10n.text("swap.refresh.off")
        case .fifteenSeconds: return L10n.text("swap.refresh.15_seconds")
        case .thirtySeconds: return L10n.text("swap.refresh.30_seconds")
        case .oneMinute: return L10n.text("swap.refresh.one_minute")
        }
    }
}

struct SwapHistoryPoint: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let usedBytes: UInt64
}

@MainActor
final class SwapMonitor: ObservableObject {
    @Published private(set) var snapshot: SwapSnapshot = .empty
    @Published private(set) var history: [SwapHistoryPoint] = []
    @Published private(set) var swapInRateBytes: Double = 0
    @Published private(set) var swapOutRateBytes: Double = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published var selectedGroupID: String?
    @Published var autoRefresh: AutoRefreshInterval = .thirtySeconds {
        didSet { restartAutoRefresh() }
    }

    private var autoRefreshTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var isActive = false

    init(
        snapshot: SwapSnapshot = .empty,
        history: [SwapHistoryPoint] = []
    ) {
        self.snapshot = snapshot
        self.history = history
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        if snapshot == .empty {
            refresh()
        }
        restartAutoRefresh()
    }

    func stop() {
        isActive = false
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil

        let probeTask = Task.detached(priority: .userInitiated) {
            try SystemProbe.capture()
        }
        refreshTask = Task { [weak self] in
            do {
                let nextSnapshot = try await withTaskCancellationHandler {
                    try await probeTask.value
                } onCancel: {
                    probeTask.cancel()
                }
                guard !Task.isCancelled else { return }
                self?.apply(nextSnapshot)
            } catch is CancellationError {
                // Expected when leaving the swap-analysis screen.
            } catch {
                self?.errorMessage = Self.localizedErrorMessage(error)
            }
            self?.isRefreshing = false
            self?.refreshTask = nil
        }
    }

    private func apply(_ nextSnapshot: SwapSnapshot) {
        updateRates(previous: snapshot, current: nextSnapshot)
        snapshot = nextSnapshot

        history.append(SwapHistoryPoint(
            timestamp: nextSnapshot.capturedAt,
            usedBytes: nextSnapshot.system.swapUsedBytes
        ))
        if history.count > 60 {
            history.removeFirst(history.count - 60)
        }

        if let selectedGroupID,
           nextSnapshot.groups.contains(where: { $0.id == selectedGroupID }) {
            return
        }
        selectedGroupID = nextSnapshot.groups.first(where: {
            $0.compressorBackedBytes > 0
        })?.id ?? nextSnapshot.groups.first?.id
    }

    private func updateRates(previous: SwapSnapshot, current: SwapSnapshot) {
        guard previous != .empty else {
            swapInRateBytes = 0
            swapOutRateBytes = 0
            return
        }

        let interval = current.capturedAt.timeIntervalSince(previous.capturedAt)
        guard interval > 0 else { return }
        let pageSize = Double(current.system.kernelPageSize)

        if current.system.swapInsPages >= previous.system.swapInsPages {
            swapInRateBytes = Double(
                current.system.swapInsPages - previous.system.swapInsPages
            ) * pageSize / interval
        } else {
            swapInRateBytes = 0
        }

        if current.system.swapOutsPages >= previous.system.swapOutsPages {
            swapOutRateBytes = Double(
                current.system.swapOutsPages - previous.system.swapOutsPages
            ) * pageSize / interval
        } else {
            swapOutRateBytes = 0
        }
    }

    private func restartAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        guard isActive, autoRefresh.rawValue > 0 else { return }
        let nanoseconds = UInt64(autoRefresh.rawValue) * 1_000_000_000

        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    deinit {
        autoRefreshTask?.cancel()
        refreshTask?.cancel()
    }

    private static func localizedErrorMessage(_ error: Error) -> String {
        if case let ProbeError.systemCall(name, code) = error {
            return L10n.text("swap.error.system_call", name, Int(code).formatted())
        }
        return error.localizedDescription
    }
}
