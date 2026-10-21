import XCTest
@testable import TaskProcessor

private enum TestWorkerError: Error {
    case expected
}

private actor CallCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private actor CallNumbers {
    private var calls: [String: Int] = [:]

    func next(for id: String) -> Int {
        calls[id, default: 0] += 1
        return calls[id, default: 0]
    }
}

private actor Probe {
    private(set) var startedIDs: [String] = []
    private(set) var activeCount = 0
    private(set) var maximumActiveCount = 0

    func start(_ id: String) {
        startedIDs.append(id)
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
    }

    func finish() {
        activeCount -= 1
    }
}

private actor TestGate {
    private var releasedIDs: Set<String> = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var waitingObservers: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var passedIDs: Set<String> = []
    private var passedObservers: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var anyWaitingObservers: [([String], CheckedContinuation<String, Never>)] = []

    func wait(for id: String) async {
        if releasedIDs.remove(id) != nil {
            markPassed(id)
            return
        }

        await withCheckedContinuation { continuation in
            waiters[id] = continuation
            let observers = waitingObservers.removeValue(forKey: id) ?? []
            for observer in observers {
                observer.resume()
            }
            let anyObservers = anyWaitingObservers.filter { $0.0.contains(id) }
            anyWaitingObservers.removeAll { $0.0.contains(id) }
            for (_, observer) in anyObservers {
                observer.resume(returning: id)
            }
        }
        markPassed(id)
    }

    func waitUntilAnyWaiting(for ids: [String]) async -> String {
        if let id = ids.first(where: { waiters[$0] != nil }) {
            return id
        }

        return await withCheckedContinuation { continuation in
            anyWaitingObservers.append((ids, continuation))
        }
    }

    func waitUntilWaiting(for id: String) async {
        if waiters[id] != nil {
            return
        }

        await withCheckedContinuation { continuation in
            waitingObservers[id, default: []].append(continuation)
        }
    }

    func waitUntilPassed(_ id: String) async {
        if passedIDs.contains(id) {
            return
        }

        await withCheckedContinuation { continuation in
            passedObservers[id, default: []].append(continuation)
        }
    }

    func release(_ id: String) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume()
        } else {
            releasedIDs.insert(id)
        }
    }

    private func markPassed(_ id: String) {
        passedIDs.insert(id)
        let observers = passedObservers.removeValue(forKey: id) ?? []
        for observer in observers {
            observer.resume()
        }
    }
}

@MainActor
final class TaskProcessorStudentTests: XCTestCase {
    func testNegativeMaximumConcurrencyIsRejected() {
        XCTAssertThrowsError(try TaskProcessor(maximumConcurrency: -3)) { error in
            XCTAssertEqual(
                error as? TaskProcessorError,
                .nonPositiveMaximumConcurrency
            )
        }
    }

    func testDuplicateIDThrowsBeforeAnyWorkerStarts() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let counter = CallCounter()
        let jobs = [
            Job(id: "a", input: 1),
            Job(id: "b", input: 2),
            Job(id: "a", input: 3)
        ]

        do {
            _ = try await processor.process(jobs) { job in
                await counter.increment()
                return job.input
            }
            XCTFail("Expected a duplicate ID error")
        } catch {
            XCTAssertEqual(error as? TaskProcessorError, .duplicateID("a"))
        }

        let calls = await counter.count
        XCTAssertEqual(calls, 0)
    }

    func testFirstRepeatedIDIsReported() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let jobs = ["a", "b", "b", "a"].map { Job(id: $0, input: 0) }

        do {
            _ = try await processor.process(jobs) { job in
                job.input
            }
            XCTFail("Expected a duplicate ID error")
        } catch {
            XCTAssertEqual(error as? TaskProcessorError, .duplicateID("b"))
        }
    }

    func testActiveWorkersNeverExceedLimit() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let gate = TestGate()
        let probe = Probe()
        let jobs = (0..<5).map { Job(id: "\($0)", input: $0) }

        let processing = Task {
            try await processor.process(jobs) { job in
                await probe.start(job.id)
                await gate.wait(for: job.id)
                await probe.finish()
                return job.input
            }
        }

        await gate.waitUntilWaiting(for: "0")
        await gate.waitUntilWaiting(for: "1")
        let startedBeforeRelease = await probe.startedIDs
        XCTAssertEqual(Set(startedBeforeRelease), ["0", "1"])

        await gate.release("0")
        await gate.waitUntilWaiting(for: "2")
        let startedAfterFirstRelease = await probe.startedIDs
        XCTAssertEqual(Set(startedAfterFirstRelease), ["0", "1", "2"])
        XCTAssertEqual(startedAfterFirstRelease.count, 3)

        await gate.release("1")
        await gate.waitUntilWaiting(for: "3")
        await gate.release("2")
        await gate.waitUntilWaiting(for: "4")
        await gate.release("3")
        await gate.release("4")

        let results = try await processing.value
        XCTAssertEqual(results.map(\.id), ["0", "1", "2", "3", "4"])
        let maximumActive = await probe.maximumActiveCount
        XCTAssertEqual(maximumActive, 2)
    }

    func testResultsKeepInputOrderWhenJobsFinishInReverseOrder() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 3)
        let gate = TestGate()
        let jobs = [
            Job(id: "a", input: 1),
            Job(id: "b", input: 2),
            Job(id: "c", input: 3)
        ]

        let processing = Task {
            try await processor.process(jobs) { job in
                await gate.wait(for: job.id)
                return job.input * 100
            }
        }

        await gate.waitUntilWaiting(for: "a")
        await gate.waitUntilWaiting(for: "b")
        await gate.waitUntilWaiting(for: "c")
        await gate.release("c")
        await gate.waitUntilPassed("c")
        await gate.release("b")
        await gate.waitUntilPassed("b")
        await gate.release("a")

        let results = try await processing.value
        XCTAssertEqual(
            results,
            [
                JobResult(id: "a", outcome: .succeeded(100)),
                JobResult(id: "b", outcome: .succeeded(200)),
                JobResult(id: "c", outcome: .succeeded(300))
            ]
        )
    }

    func testMixedOutcomesAreMappedAndProcessingContinues() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let jobs = [
            Job(id: "ok", input: 5),
            Job(id: "error", input: 0),
            Job(id: "cancel", input: 0),
            Job(id: "last", input: 7)
        ]

        let results = try await processor.process(jobs) { job in
            switch job.id {
            case "error":
                throw TestWorkerError.expected
            case "cancel":
                throw CancellationError()
            default:
                return job.input * 2
            }
        }

        XCTAssertEqual(
            results,
            [
                JobResult(id: "ok", outcome: .succeeded(10)),
                JobResult(id: "error", outcome: .failed),
                JobResult(id: "cancel", outcome: .cancelled),
                JobResult(id: "last", outcome: .succeeded(14))
            ]
        )
    }

    func testCallerCancellationStopsQueuedJobs() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let gate = TestGate()
        let probe = Probe()
        let jobs = [
            Job(id: "a", input: 1),
            Job(id: "b", input: 2),
            Job(id: "c", input: 3)
        ]

        let processing = Task {
            try await processor.process(jobs) { job in
                await probe.start(job.id)
                if job.id == "b" {
                    await gate.wait(for: job.id)
                    try Task.checkCancellation()
                }
                return job.input
            }
        }

        await gate.waitUntilWaiting(for: "b")
        processing.cancel()
        await gate.release("b")

        let results = try await processing.value
        XCTAssertEqual(
            results,
            [
                JobResult(id: "a", outcome: .succeeded(1)),
                JobResult(id: "b", outcome: .cancelled),
                JobResult(id: "c", outcome: .cancelled)
            ]
        )
        let started = await probe.startedIDs
        XCTAssertEqual(started, ["a", "b"])
    }

    func testCancellationBeforeSchedulingStartsNoWorker() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let gate = TestGate()
        let counter = CallCounter()
        let jobs = [
            Job(id: "x", input: 1),
            Job(id: "y", input: 2)
        ]

        let processing = Task {
            await gate.wait(for: "start")
            return try await processor.process(jobs) { job in
                await counter.increment()
                return job.input
            }
        }

        processing.cancel()
        await gate.release("start")

        let results = try await processing.value
        XCTAssertEqual(
            results,
            [
                JobResult(id: "x", outcome: .cancelled),
                JobResult(id: "y", outcome: .cancelled)
            ]
        )
        let calls = await counter.count
        XCTAssertEqual(calls, 0)
    }

    func testLimitLargerThanJobCountRunsAllJobs() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 10)
        let jobs = [
            Job(id: "one", input: 1),
            Job(id: "two", input: 2),
            Job(id: "three", input: 3)
        ]

        let results = try await processor.process(jobs) { job in
            job.input + 1
        }

        XCTAssertEqual(
            results,
            [
                JobResult(id: "one", outcome: .succeeded(2)),
                JobResult(id: "two", outcome: .succeeded(3)),
                JobResult(id: "three", outcome: .succeeded(4))
            ]
        )
    }

    // MARK: - Retry policy (bonus)

    func testRetryPolicyRejectsNonPositiveAttempts() {
        for attempts in [0, -2] {
            XCTAssertThrowsError(try RetryPolicy(maximumAttempts: attempts)) { error in
                XCTAssertEqual(
                    error as? RetryPolicyError,
                    .nonPositiveMaximumAttempts
                )
            }
        }
    }

    func testRetryRecoversBeforeLimitWithExactAttemptNumbers() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let policy = try RetryPolicy(maximumAttempts: 5)
        let probe = Probe()
        let job = Job(id: "flaky", input: 4)

        let results = try await processor.process([job], retryPolicy: policy) { job, attempt in
            await probe.start("\(job.id)#\(attempt)")
            await probe.finish()
            if attempt < 3 {
                throw TestWorkerError.expected
            }
            return job.input * attempt
        }

        XCTAssertEqual(results, [JobResult(id: "flaky", outcome: .succeeded(12))])
        let attempts = await probe.startedIDs
        XCTAssertEqual(attempts, ["flaky#1", "flaky#2", "flaky#3"])
    }

    func testRetryFailsAfterFinalAttempt() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let policy = try RetryPolicy(maximumAttempts: 3)
        let probe = Probe()
        let job = Job(id: "broken", input: 0)

        let results = try await processor.process([job], retryPolicy: policy) { job, attempt in
            await probe.start("\(job.id)#\(attempt)")
            await probe.finish()
            throw TestWorkerError.expected
        }

        XCTAssertEqual(results, [JobResult(id: "broken", outcome: .failed)])
        let attempts = await probe.startedIDs
        XCTAssertEqual(attempts, ["broken#1", "broken#2", "broken#3"])
    }

    func testCancellationErrorIsNotRetried() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let policy = try RetryPolicy(maximumAttempts: 4)
        let probe = Probe()
        let jobs = [
            Job(id: "stop", input: 0),
            Job(id: "next", input: 6)
        ]

        let results = try await processor.process(jobs, retryPolicy: policy) { job, attempt in
            await probe.start("\(job.id)#\(attempt)")
            await probe.finish()
            if job.id == "stop" {
                throw CancellationError()
            }
            return job.input
        }

        XCTAssertEqual(
            results,
            [
                JobResult(id: "stop", outcome: .cancelled),
                JobResult(id: "next", outcome: .succeeded(6))
            ]
        )
        let attempts = await probe.startedIDs
        XCTAssertEqual(attempts, ["stop#1", "next#1"])
    }

    func testRetriesStayInsideOneConcurrencySlot() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let policy = try RetryPolicy(maximumAttempts: 3)
        let probe = Probe()
        let jobs = [
            Job(id: "a", input: 1),
            Job(id: "b", input: 2)
        ]

        let results = try await processor.process(jobs, retryPolicy: policy) { job, attempt in
            await probe.start("\(job.id)#\(attempt)")
            await probe.finish()
            if job.id == "a" && attempt < 3 {
                throw TestWorkerError.expected
            }
            return job.input
        }

        XCTAssertEqual(
            results,
            [
                JobResult(id: "a", outcome: .succeeded(1)),
                JobResult(id: "b", outcome: .succeeded(2))
            ]
        )
        let attempts = await probe.startedIDs
        XCTAssertEqual(attempts, ["a#1", "a#2", "a#3", "b#1"])
        let maximumActive = await probe.maximumActiveCount
        XCTAssertEqual(maximumActive, 1)
    }

    func testRetryResultsKeepInputOrder() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let policy = try RetryPolicy(maximumAttempts: 2)
        let gate = TestGate()
        let calls = CallNumbers()
        let jobs = [
            Job(id: "a", input: 1),
            Job(id: "b", input: 2)
        ]

        let processing = Task {
            try await processor.process(jobs, retryPolicy: policy) { job, _ in
                let call = await calls.next(for: job.id)
                if call == 1 {
                    await gate.wait(for: job.id)
                }
                if job.id == "a" && call == 1 {
                    throw TestWorkerError.expected
                }
                return job.input * 10
            }
        }

        await gate.waitUntilWaiting(for: "a")
        await gate.waitUntilWaiting(for: "b")
        await gate.release("b")
        await gate.waitUntilPassed("b")
        await gate.release("a")

        let results = try await processing.value
        XCTAssertEqual(
            results,
            [
                JobResult(id: "a", outcome: .succeeded(10)),
                JobResult(id: "b", outcome: .succeeded(20))
            ]
        )
    }

    func testRetryCallerCancellationStopsQueuedJobs() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let policy = try RetryPolicy(maximumAttempts: 3)
        let gate = TestGate()
        let probe = Probe()
        let calls = CallNumbers()
        let jobs = [
            Job(id: "a", input: 1),
            Job(id: "b", input: 2),
            Job(id: "c", input: 3)
        ]

        let processing = Task {
            try await processor.process(jobs, retryPolicy: policy) { job, attempt in
                await probe.start("\(job.id)#\(attempt)")
                let call = await calls.next(for: job.id)
                if job.id == "b" {
                    if call == 1 {
                        await gate.wait(for: job.id)
                    }
                    try Task.checkCancellation()
                }
                return job.input
            }
        }

        await gate.waitUntilWaiting(for: "b")
        processing.cancel()
        await gate.release("b")

        let results = try await processing.value
        XCTAssertEqual(
            results,
            [
                JobResult(id: "a", outcome: .succeeded(1)),
                JobResult(id: "b", outcome: .cancelled),
                JobResult(id: "c", outcome: .cancelled)
            ]
        )
        let attempts = await probe.startedIDs
        XCTAssertEqual(attempts, ["a#1", "b#1"])
    }

    func testRetryKeepsSlotSoQueuedJobWaits() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let policy = try RetryPolicy(maximumAttempts: 2)
        let gate = TestGate()
        let probe = Probe()
        let jobs = [
            Job(id: "a", input: 1),
            Job(id: "b", input: 2),
            Job(id: "c", input: 3)
        ]

        let processing = Task {
            try await processor.process(jobs, retryPolicy: policy) { job, attempt in
                await probe.start("\(job.id)#\(attempt)")
                if job.id == "a" && attempt == 1 {
                    await probe.finish()
                    throw TestWorkerError.expected
                }
                await gate.wait(for: job.id)
                await probe.finish()
                return job.input
            }
        }

        await gate.waitUntilWaiting(for: "b")
        let firstWaiting = await gate.waitUntilAnyWaiting(for: ["a", "c"])
        XCTAssertEqual(firstWaiting, "a", "Job c started while job a was retrying")
        let startedWhileRetrying = await probe.startedIDs
        XCTAssertEqual(Set(startedWhileRetrying), ["a#1", "a#2", "b#1"])
        XCTAssertEqual(startedWhileRetrying.count, 3)

        await gate.release("b")
        await gate.waitUntilWaiting(for: "c")
        await gate.release("c")
        await gate.waitUntilPassed("c")
        await gate.release("a")

        let results = try await processing.value
        XCTAssertEqual(
            results,
            [
                JobResult(id: "a", outcome: .succeeded(1)),
                JobResult(id: "b", outcome: .succeeded(2)),
                JobResult(id: "c", outcome: .succeeded(3))
            ]
        )
        let maximumActive = await probe.maximumActiveCount
        XCTAssertEqual(maximumActive, 2)
    }
}
