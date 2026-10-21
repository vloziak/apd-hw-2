public struct Job: Sendable, Equatable {
    public let id: String
    public let input: Int

    public init(id: String, input: Int) {
        self.id = id
        self.input = input
    }
}

public enum JobOutcome: Sendable, Equatable {
    case succeeded(Int)
    case failed
    case cancelled
}

public struct JobResult: Sendable, Equatable {
    public let id: String
    public let outcome: JobOutcome

    public init(id: String, outcome: JobOutcome) {
        self.id = id
        self.outcome = outcome
    }
}

public enum TaskProcessorError: Error, Equatable {
    case nonPositiveMaximumConcurrency
    case duplicateID(String)
}

public struct RetryPolicy: Sendable, Equatable {
    public let maximumAttempts: Int

    public init(maximumAttempts: Int) throws {
        guard maximumAttempts > 0 else {
            throw RetryPolicyError.nonPositiveMaximumAttempts
        }
        self.maximumAttempts = maximumAttempts
    }
}

public enum RetryPolicyError: Error, Equatable {
    case nonPositiveMaximumAttempts
}

public actor TaskProcessor {
    private let maximumConcurrency: Int

    public init(maximumConcurrency: Int) throws {
        guard maximumConcurrency > 0 else {
            throw TaskProcessorError.nonPositiveMaximumConcurrency
        }
        self.maximumConcurrency = maximumConcurrency
    }

    public func process(
        _ jobs: [Job],
        worker: @escaping @Sendable (Job) async throws -> Int
    ) async throws -> [JobResult] {
        try await runJobs(jobs) { job in
            await Self.outcome(of: job, worker: worker)
        }
    }

    private func runJobs(
        _ jobs: [Job],
        runJob: @escaping @Sendable (Job) async -> JobOutcome
    ) async throws -> [JobResult] {
        try Self.checkForDuplicateIDs(in: jobs)

        if jobs.isEmpty {
            return []
        }

        let limit = maximumConcurrency

        let outcomes = await withTaskGroup(
            of: (Int, JobOutcome).self,
            returning: [JobOutcome?].self
        ) { group in
            var outcomes = [JobOutcome?](repeating: nil, count: jobs.count)
            var nextIndex = 0

            while nextIndex < jobs.count && nextIndex < limit {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                Self.startJob(at: nextIndex, of: jobs, in: &group, runJob: runJob)
                nextIndex += 1
            }

            for await (index, outcome) in group {
                outcomes[index] = outcome

                if nextIndex < jobs.count {
                    if Task.isCancelled {
                        group.cancelAll()
                        continue
                    }
                    Self.startJob(at: nextIndex, of: jobs, in: &group, runJob: runJob)
                    nextIndex += 1
                }
            }

            return outcomes
        }

        return jobs.indices.map { index in
            JobResult(id: jobs[index].id, outcome: outcomes[index] ?? .cancelled)
        }
    }

    private static func startJob(
        at index: Int,
        of jobs: [Job],
        in group: inout TaskGroup<(Int, JobOutcome)>,
        runJob: @escaping @Sendable (Job) async -> JobOutcome
    ) {
        let job = jobs[index]
        group.addTask {
            (index, await runJob(job))
        }
    }

    private static func outcome(
        of job: Job,
        worker: @Sendable (Job) async throws -> Int
    ) async -> JobOutcome {
        do {
            return .succeeded(try await worker(job))
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed
        }
    }

    private static func outcomeWithRetries(
        of job: Job,
        maximumAttempts: Int,
        worker: @Sendable (Job, Int) async throws -> Int
    ) async -> JobOutcome {
        for attempt in 1...maximumAttempts {
            do {
                return .succeeded(try await worker(job, attempt))
            } catch is CancellationError {
                return .cancelled
            } catch {
                if Task.isCancelled {
                    return .failed
                }
            }
        }
        return .failed
    }

    private static func checkForDuplicateIDs(in jobs: [Job]) throws {
        var seenIDs: Set<String> = []
        for job in jobs {
            if seenIDs.contains(job.id) {
                throw TaskProcessorError.duplicateID(job.id)
            }
            seenIDs.insert(job.id)
        }
    }
}

public extension TaskProcessor {
    func process(
        _ jobs: [Job],
        retryPolicy: RetryPolicy,
        worker: @escaping @Sendable (Job, Int) async throws -> Int
    ) async throws -> [JobResult] {
        let maximumAttempts = retryPolicy.maximumAttempts
        return try await runJobs(jobs) { job in
            await Self.outcomeWithRetries(
                of: job,
                maximumAttempts: maximumAttempts,
                worker: worker
            )
        }
    }
}
