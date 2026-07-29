import AVFAudio

/// The operation that is currently using the process-wide audio session.
///
/// Listening and speaking have different Apple session policies. Keeping the
/// role in the private seam makes it impossible for a future provider to
/// silently configure the session for one operation while another operation is
/// still holding a lease.
enum AudioSessionRole: Sendable, Equatable {
    case listening
    case speaking
}

/// The host application's session state that AppLocalVoice is responsible for
/// putting back when its final lease ends.
///
/// AVAudioSession is process-wide. A package must not assume that it is the
/// only owner of the singleton, and it must not leave the host's category or
/// preferred I/O settings behind after a voice turn.
struct AudioSessionSnapshot: Sendable, Equatable {
    let category: String?
    let mode: String?
    let routeSharingPolicy: UInt
    let categoryOptions: UInt
    let preferredSampleRate: Double
    let preferredIOBufferDuration: Double
    let preferredInputUID: String?

    static let empty = AudioSessionSnapshot(
        category: nil,
        mode: nil,
        routeSharingPolicy: 0,
        categoryOptions: 0,
        preferredSampleRate: 0,
        preferredIOBufferDuration: 0,
        preferredInputUID: nil
    )

    /// The configuration fields AppLocalVoice writes while it owns the shared
    /// session. Preferred I/O values are intentionally excluded: AVFAudio may
    /// normalize them after activation, and a host may also update them while
    /// voice is active. Neither case permits restoring an older value over the
    /// newer process-wide state.
    func hasSameManagedConfiguration(as other: AudioSessionSnapshot) -> Bool {
        category == other.category
            && mode == other.mode
            && routeSharingPolicy == other.routeSharingPolicy
            && categoryOptions == other.categoryOptions
    }

    /// Restores the host configuration while preserving any preferred-I/O
    /// value that changed after AppLocalVoice acquired the session. This is a
    /// three-way merge: `self` is the pre-lease host snapshot, `managed` is the
    /// post-activation package snapshot, and `current` is the release-time
    /// process state.
    func restoringHostConfiguration(
        managed: AudioSessionSnapshot,
        current: AudioSessionSnapshot
    ) -> AudioSessionSnapshot {
        AudioSessionSnapshot(
            category: category,
            mode: mode,
            routeSharingPolicy: routeSharingPolicy,
            categoryOptions: categoryOptions,
            preferredSampleRate: current.preferredSampleRate == managed.preferredSampleRate
                ? preferredSampleRate : current.preferredSampleRate,
            preferredIOBufferDuration: current.preferredIOBufferDuration == managed.preferredIOBufferDuration
                ? preferredIOBufferDuration : current.preferredIOBufferDuration,
            preferredInputUID: current.preferredInputUID == managed.preferredInputUID
                ? preferredInputUID : current.preferredInputUID
        )
    }
}

/// The small system boundary required by the audio-session broker.
///
/// The original `configureForVoice()` requirement remains as a compatibility
/// seam for focused tests and older internal fakes. New code should use the
/// role-aware default implementation below.
protocol AudioSessionDriver: AnyObject, Sendable {
    var isOtherAudioPlaying: Bool { get }

    func configureForVoice() throws
    func configure(for role: AudioSessionRole) throws
    func configure(
        for role: AudioSessionRole,
        externalAudio: ExternalAudioPolicy,
        isOtherAudioPlaying: Bool
    ) throws
    func snapshot() -> AudioSessionSnapshot
    func restore(_ snapshot: AudioSessionSnapshot) throws
    func setActive(_ active: Bool) throws
}

extension AudioSessionDriver {
    func configure(for role: AudioSessionRole) throws {
        _ = role
        try configureForVoice()
    }

    func configure(
        for role: AudioSessionRole,
        externalAudio: ExternalAudioPolicy,
        isOtherAudioPlaying: Bool
    ) throws {
        _ = externalAudio
        _ = isOtherAudioPlaying
        try configure(for: role)
    }

    func snapshot() -> AudioSessionSnapshot {
        .empty
    }

    func restore(_ snapshot: AudioSessionSnapshot) throws {
        _ = snapshot
    }
}

/// Production driver for the process-wide shared audio session.
final class AVAudioSessionDriver: @unchecked Sendable, AudioSessionDriver {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    var isOtherAudioPlaying: Bool {
        session.isOtherAudioPlaying
    }

    func snapshot() -> AudioSessionSnapshot {
        AudioSessionSnapshot(
            category: session.category.rawValue,
            mode: session.mode.rawValue,
            routeSharingPolicy: session.routeSharingPolicy.rawValue,
            categoryOptions: session.categoryOptions.rawValue,
            preferredSampleRate: session.preferredSampleRate,
            preferredIOBufferDuration: session.preferredIOBufferDuration,
            preferredInputUID: session.preferredInput?.uid
        )
    }

    func configureForVoice() throws {
        try configure(for: .speaking)
    }

    func configure(for role: AudioSessionRole) throws {
        try configure(
            for: role,
            externalAudio: .duck,
            isOtherAudioPlaying: session.isOtherAudioPlaying
        )
    }

    func configure(
        for role: AudioSessionRole,
        externalAudio: ExternalAudioPolicy,
        isOtherAudioPlaying: Bool
    ) throws {
        switch role {
        case .listening:
            // Measurement avoids the speech-oriented output processing that
            // is useful for playback but can make a microphone recognizer
            // less predictable. When external audio is already active, use
            // play-and-record only for an explicit coexistence policy; the
            // normal no-host-audio path keeps the prior record-only setup.
            if isOtherAudioPlaying {
                switch externalAudio {
                case .mix:
                    try session.setCategory(
                        .playAndRecord,
                        mode: .measurement,
                        options: [.allowBluetoothHFP, .mixWithOthers]
                    )
                case .duck:
                    try session.setCategory(
                        .playAndRecord,
                        mode: .measurement,
                        options: [.allowBluetoothHFP, .mixWithOthers, .duckOthers]
                    )
                case .interrupt, .reject:
                    // `.reject` is rejected by the broker before this point.
                    try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
                }
            } else {
                try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            }
        case .speaking:
            // voicePrompt is the system mode intended for short spoken
            // prompts. Configure the host-audio behavior instead of always
            // ducking regardless of the lease policy.
            let options: AVAudioSession.CategoryOptions
            switch externalAudio {
            case .mix:
                options = [.mixWithOthers]
            case .duck:
                options = [.mixWithOthers, .duckOthers]
            case .interrupt, .reject:
                // `.reject` is rejected by the broker if other audio is
                // currently playing. With no competing source, plain
                // playback preserves the requested interruption behavior.
                options = []
            }
            try session.setCategory(.playback, mode: .voicePrompt, options: options)
        }
    }

    func restore(_ snapshot: AudioSessionSnapshot) throws {
        guard let category = snapshot.category,
              let mode = snapshot.mode else {
            return
        }

        try session.setCategory(
            AVAudioSession.Category(rawValue: category),
            mode: AVAudioSession.Mode(rawValue: mode),
            policy: AVAudioSession.RouteSharingPolicy(rawValue: snapshot.routeSharingPolicy) ?? .default,
            options: AVAudioSession.CategoryOptions(rawValue: snapshot.categoryOptions)
        )

        if snapshot.preferredSampleRate > 0, snapshot.preferredSampleRate.isFinite {
            try session.setPreferredSampleRate(snapshot.preferredSampleRate)
        }
        if snapshot.preferredIOBufferDuration > 0, snapshot.preferredIOBufferDuration.isFinite {
            try session.setPreferredIOBufferDuration(snapshot.preferredIOBufferDuration)
        }
        let input = snapshot.preferredInputUID.flatMap { preferredInputUID in
            session.availableInputs?.first(where: { $0.uid == preferredInputUID })
        }
        try session.setPreferredInput(input)
    }

    func setActive(_ active: Bool) throws {
        if active {
            try session.setActive(true)
        } else {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// Process-wide serialization for the process-wide AVAudioSession singleton.
///
/// Each `AudioSessionController` is a lightweight handle. All default handles
/// use this broker, so two independent AppLocalVoice facades cannot deactivate
/// or restore the shared session while the other one still owns a lease.
final class AudioSessionBroker: @unchecked Sendable {
    static let shared = AudioSessionBroker(driver: AVAudioSessionDriver())

    private struct Lease: Sendable {
        let role: AudioSessionRole
        let externalAudio: ExternalAudioPolicy
        var count: Int
    }

    // AVAudioSession can synchronously re-enter host code while a transition
    // is in progress. A recursive lock avoids self-deadlock for read-only
    // callbacks; `transitionInFlight` below rejects any nested mutation before
    // it can configure or restore the singleton a second time.
    private let lock = NSRecursiveLock()
    private let driver: any AudioSessionDriver
    private var leases: [UUID: Lease] = [:]
    private var activeRole: AudioSessionRole?
    private var activeExternalAudio: ExternalAudioPolicy?
    private var hostSnapshot: AudioSessionSnapshot?
    /// The exact session state AppLocalVoice last configured and activated.
    /// A different later snapshot means the host took ownership; restoring an
    /// old host snapshot would overwrite that newer configuration.
    private var managedSnapshot: AudioSessionSnapshot?
    /// Exact process state observed immediately after a failed transition.
    /// Reconciliation is permitted only while this proof remains unchanged.
    private var reconciliationObservedSnapshot: AudioSessionSnapshot?
    private var needsReconciliation = false
    private var transitionInFlight = false

    init(driver: any AudioSessionDriver) {
        self.driver = driver
    }

    func enter(
        owner: UUID,
        role: AudioSessionRole,
        lifecyclePolicy: AudioLifecyclePolicy = .init()
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        if var existing = leases[owner] {
            guard existing.role == role, existing.externalAudio == lifecyclePolicy.externalAudio else {
                throw VoiceError.invalidState("The shared audio session is already leased for another voice role.")
            }
            existing.count += 1
            leases[owner] = existing
            return
        }

        let isOtherAudioPlaying = driver.isOtherAudioPlaying
        if lifecyclePolicy.externalAudio == .reject, isOtherAudioPlaying {
            throw VoiceError.audioSessionUnavailable(
                "Another audio source is active and the lifecycle policy rejects external audio."
            )
        }

        if !leases.isEmpty {
            guard activeRole == role,
                  activeExternalAudio == lifecyclePolicy.externalAudio else {
                throw VoiceError.invalidState("The shared audio session is already leased for another voice role.")
            }
            leases[owner] = Lease(role: role, externalAudio: lifecyclePolicy.externalAudio, count: 1)
            return
        }

        guard !transitionInFlight else {
            throw VoiceError.audioSessionUnavailable(
                "The shared audio session is already transitioning; retry after the current transition completes."
            )
        }

        if needsReconciliation {
            transitionInFlight = true
            defer { transitionInFlight = false }
            try reconcile()
        }

        let snapshot = driver.snapshot()
        transitionInFlight = true
        var activationWasAttempted = false
        do {
            try driver.configure(
                for: role,
                externalAudio: lifecyclePolicy.externalAudio,
                isOtherAudioPlaying: isOtherAudioPlaying
            )
            activationWasAttempted = true
            try driver.setActive(true)
        } catch {
            // Configuration and activation are system boundaries. Make a
            // best-effort restoration attempt immediately, while retaining a
            // marker for the next operation if either transition was partial.
            if activationWasAttempted {
                // Do not issue a second system transition here. A failed
                // activation can have partially changed the singleton; leave
                // the exact snapshot pending and make the next operation
                // perform the explicit deactivation/restore reconciliation.
                hostSnapshot = snapshot
                managedSnapshot = nil
                reconciliationObservedSnapshot = driver.snapshot()
                needsReconciliation = true
            } else {
                do {
                    try driver.restore(snapshot)
                    hostSnapshot = nil
                    managedSnapshot = nil
                    reconciliationObservedSnapshot = nil
                    needsReconciliation = false
                } catch {
                    hostSnapshot = snapshot
                    managedSnapshot = nil
                    reconciliationObservedSnapshot = driver.snapshot()
                    needsReconciliation = true
                }
            }
            transitionInFlight = false
            throw error
        }

        hostSnapshot = snapshot
        managedSnapshot = driver.snapshot()
        reconciliationObservedSnapshot = nil
        activeRole = role
        activeExternalAudio = lifecyclePolicy.externalAudio
        leases[owner] = Lease(role: role, externalAudio: lifecyclePolicy.externalAudio, count: 1)
        transitionInFlight = false
    }

    func isOtherAudioPlaying() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return driver.isOtherAudioPlaying
    }

    func exit(owner: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var lease = leases[owner] else {
            // A previous final restore may have failed after the logical lease
            // was closed. An idempotent later exit is the natural reconciliation
            // boundary; do not silently report success while the broker still
            // owns an unresolved host snapshot.
            if needsReconciliation { try reconcile() }
            return
        }

        lease.count -= 1
        if lease.count > 0 {
            leases[owner] = lease
            return
        }
        leases.removeValue(forKey: owner)
        guard leases.isEmpty else { return }

        let snapshot = hostSnapshot ?? .empty
        activeRole = nil
        activeExternalAudio = nil
        guard !transitionInFlight else {
            throw VoiceError.audioSessionUnavailable(
                "The shared audio session is already transitioning; retry after the current transition completes."
            )
        }
        transitionInFlight = true
        var pendingRestorationSnapshot = snapshot

        do {
            let currentSnapshot = driver.snapshot()
            if let managedSnapshot,
               !currentSnapshot.hasSameManagedConfiguration(as: managedSnapshot) {
                // A host-owned change is newer than our configuration. Do not
                // deactivate or restore through it, and never retain an old
                // reconciliation marker that could overwrite it later.
                hostSnapshot = nil
                self.managedSnapshot = nil
                reconciliationObservedSnapshot = nil
                needsReconciliation = false
                transitionInFlight = false
                throw VoiceError.audioSessionUnavailable(
                    "The host changed the audio session while voice was active; AppLocalVoice left that newer configuration untouched."
                )
            }
            let restorationSnapshot = managedSnapshot.map {
                snapshot.restoringHostConfiguration(managed: $0, current: currentSnapshot)
            } ?? snapshot
            pendingRestorationSnapshot = restorationSnapshot
            // The normal library-managed release owns this transition: notify
            // interrupted external audio before restoring the host's
            // configuration. Nested leases never reach this boundary.
            try driver.setActive(false)
            try driver.restore(restorationSnapshot)
            hostSnapshot = nil
            managedSnapshot = nil
            reconciliationObservedSnapshot = nil
            needsReconciliation = false
            transitionInFlight = false
        } catch {
            // The lease is logically closed, but preserve the snapshot and
            // force an explicit retry before a future activation.
            if transitionInFlight {
                hostSnapshot = pendingRestorationSnapshot
                reconciliationObservedSnapshot = driver.snapshot()
                needsReconciliation = true
            }
            transitionInFlight = false
            throw error
        }
    }

    /// Releases every nested lease held by an owner.
    ///
    /// The normal provider path releases one logical lease at a time. This
    /// owner-wide boundary is used by controller deinitialization so dropping
    /// a host object without calling close() cannot strand a process-wide
    /// audio-session lease forever. A failed restore remains marked for the
    /// next explicit reconciliation just like a normal final exit.
    func releaseAll(owner: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        guard leases.removeValue(forKey: owner) != nil else {
            if needsReconciliation { try reconcile() }
            return
        }
        guard leases.isEmpty else { return }

        let snapshot = hostSnapshot ?? .empty
        activeRole = nil
        activeExternalAudio = nil
        guard !transitionInFlight else {
            throw VoiceError.audioSessionUnavailable(
                "The shared audio session is already transitioning; retry after the current transition completes."
            )
        }
        transitionInFlight = true
        var pendingRestorationSnapshot = snapshot
        do {
            let currentSnapshot = driver.snapshot()
            if let managedSnapshot,
               !currentSnapshot.hasSameManagedConfiguration(as: managedSnapshot) {
                hostSnapshot = nil
                self.managedSnapshot = nil
                reconciliationObservedSnapshot = nil
                needsReconciliation = false
                transitionInFlight = false
                throw VoiceError.audioSessionUnavailable(
                    "The host changed the audio session while voice was active; AppLocalVoice left that newer configuration untouched."
                )
            }
            let restorationSnapshot = managedSnapshot.map {
                snapshot.restoringHostConfiguration(managed: $0, current: currentSnapshot)
            } ?? snapshot
            pendingRestorationSnapshot = restorationSnapshot
            try driver.setActive(false)
            try driver.restore(restorationSnapshot)
            hostSnapshot = nil
            managedSnapshot = nil
            reconciliationObservedSnapshot = nil
            needsReconciliation = false
            transitionInFlight = false
        } catch {
            if transitionInFlight {
                hostSnapshot = pendingRestorationSnapshot
                reconciliationObservedSnapshot = driver.snapshot()
                needsReconciliation = true
            }
            transitionInFlight = false
            throw error
        }
    }

    private func reconcile() throws {
        guard needsReconciliation else { return }
        // A pending reconciliation is created only after the logical final
        // lease has already been removed. Never deactivate another owner's
        // live session while repairing a stale snapshot.
        guard leases.isEmpty else {
            throw VoiceError.invalidState("The shared audio session cannot reconcile while another owner is active.")
        }
        let snapshot = hostSnapshot ?? .empty
        guard let observed = reconciliationObservedSnapshot,
              driver.snapshot() == observed else {
            hostSnapshot = nil
            managedSnapshot = nil
            reconciliationObservedSnapshot = nil
            activeRole = nil
            activeExternalAudio = nil
            needsReconciliation = false
            throw VoiceError.audioSessionUnavailable(
                "The host changed the audio session before cleanup could be retried; AppLocalVoice left that newer configuration untouched."
            )
        }
        do {
            try driver.setActive(false)
            try driver.restore(snapshot)
        } catch {
            reconciliationObservedSnapshot = driver.snapshot()
            throw error
        }
        hostSnapshot = nil
        managedSnapshot = nil
        reconciliationObservedSnapshot = nil
        activeRole = nil
        activeExternalAudio = nil
        needsReconciliation = false
    }
}

/// Serialized handle used by the speech input and output providers.
actor AudioSessionController {
    private let broker: AudioSessionBroker
    private let ownerID = UUID()

    /// Default controllers all point at the process-wide broker.
    init() {
        self.broker = .shared
    }

    /// Isolated-driver initializer retained for deterministic seam tests.
    init(driver: any AudioSessionDriver) {
        self.broker = AudioSessionBroker(driver: driver)
    }

    /// Shared-broker initializer lets tests model multiple independent
    /// providers contending for the same process-wide session.
    init(broker: AudioSessionBroker) {
        self.broker = broker
    }

    /// Existing output call sites use speaking as their default role.
    func enter() throws {
        try broker.enter(owner: ownerID, role: .speaking)
    }

    func enter(role: AudioSessionRole) throws {
        try broker.enter(owner: ownerID, role: role)
    }

    func enter(role: AudioSessionRole, lifecyclePolicy: AudioLifecyclePolicy) throws {
        try broker.enter(owner: ownerID, role: role, lifecyclePolicy: lifecyclePolicy)
    }

    func isOtherAudioPlaying() -> Bool {
        broker.isOtherAudioPlaying()
    }

    func exit() throws {
        try broker.exit(owner: ownerID)
    }

    deinit {
        // This is only a last-resort owner boundary. Normal callers should
        // still await AppLocalVoice.close() so they can observe a failed
        // restore and retry it. The broker retains any failed reconciliation
        // marker for the next owner.
        try? broker.releaseAll(owner: ownerID)
    }
}
