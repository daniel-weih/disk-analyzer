import Foundation

/// Installation is finished before this starts. A missing launch callback must
/// never keep the installer alive; late or duplicate callbacks are ignored.
final class InstallerLaunchHandoff {
    enum Outcome {
        case opened
        case failed(Error)
        case timedOut
    }

    private let timeout: TimeInterval
    private var started = false
    private var completed = false
    private var deadline: DispatchWorkItem?
    private var onOpened: (() -> Void)?
    private var completion: ((Outcome) -> Void)?

    init(timeout: TimeInterval = 8) {
        self.timeout = timeout
    }

    func start(open: (@escaping (Error?) -> Void) -> Void,
               onOpened: @escaping () -> Void = {},
               completion: @escaping (Outcome) -> Void) {
        precondition(Thread.isMainThread)
        guard !started else { return }
        started = true
        self.onOpened = onOpened
        self.completion = completion
        let deadline = DispatchWorkItem { [weak self] in self?.finish(.timedOut) }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
        open { [weak self] error in
            DispatchQueue.main.async {
                self?.finish(error.map(Outcome.failed) ?? .opened)
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !completed else { return }
        completed = true
        deadline?.cancel()
        deadline = nil
        let onOpened = self.onOpened
        self.onOpened = nil
        let completion = self.completion
        self.completion = nil
        if case .opened = outcome { onOpened?() }
        completion?(outcome)
    }
}
