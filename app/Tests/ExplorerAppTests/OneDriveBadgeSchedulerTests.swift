import ExplorerCore
import Foundation
import Testing
@testable import ExplorerApp

struct OneDriveBadgeSchedulerTests {
    private let firstOwner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondOwner = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func demand(_ number: Int, owner: UUID? = nil,
                        priority: OneDriveBadgeDemand.Priority = .firstObservation,
                        rate: OneDriveBadgeDemand.RateClass = .ordinary,
                        eligible: TimeInterval = 0, requested: TimeInterval = 0,
                        generation: UInt64 = 0, sequence: UInt64? = nil) throws -> OneDriveBadgeDemand {
        let folder = URL(fileURLWithPath: "/synthetic/status-scheduler", isDirectory: true)
        let name = "file-\(number)"
        let item = FileItem(url: folder.appendingPathComponent(name), name: name, isDirectory: false,
            isSymbolicLink: false, size: 200, modifiedAt: nil, kind: "Text",
            identity: .init(device: 1, inode: UInt64(number + 10), birthSeconds: 1, birthNanoseconds: 1),
            availability: .availableLocally, isRegularFile: true,
            statusVersion: .init(size: 200, modificationSeconds: 1, modificationNanoseconds: 2))
        let entry = TransferEntry(source: .init(directoryURL: folder,
            directoryIdentity: .init(device: 1, inode: 1, birthSeconds: 1, birthNanoseconds: 1)), item: item)
        let key = try #require(OneDriveStatusKey(entry))
        return .init(token: .init(key: key, generation: generation, startSequence: sequence ?? UInt64(number)),
            owner: owner ?? firstOwner, priority: priority, rateClass: rate,
            eligibleAt: eligible, requestedAt: requested)
    }

    @Test func prioritiesAndSingleInFlightAdmission() throws {
        var scheduler = OneDriveBadgeScheduler()
        let ordinary = try demand(1)
        let selected = try demand(2, priority: .selected)
        let action = try demand(3, priority: .postAction, rate: .postAction)
        let routine = try demand(4, priority: .routine, rate: .routine)
        scheduler.update([ordinary, routine, selected, action], now: 0)
        for expected in [action, selected, ordinary, routine] {
            let admittedCandidate = scheduler.next(now: 0)
            let admitted = try #require(admittedCandidate)
            #expect(admitted.token == expected.token)
            #expect(scheduler.inFlight == admitted.token)
            #expect(scheduler.next(now: 10) == nil)
            #expect(scheduler.nextWakeup(now: 10) == nil)
            scheduler.completed(admitted.token, disposition: .finished, now: 10)
        }
        #expect(scheduler.next(now: 10) == nil)
        #expect(scheduler.nextWakeup(now: 1_000) == nil)
    }

    @Test func globalBucketHasFractionalRefillAndNoFixedWindowReset() throws {
        var scheduler = OneDriveBadgeScheduler(capacity: 4, interval: 60)
        scheduler.update(try (0..<8).map { try demand($0, priority: .selected) }, now: 0)
        for _ in 0..<4 {
            let admittedCandidate = scheduler.next(now: 0)
            let admitted = try #require(admittedCandidate)
            scheduler.completed(admitted.token, disposition: .finished, now: 0)
        }
        #expect(scheduler.next(now: 7.5) == nil)
        #expect(scheduler.nextWakeup(now: 7.5) == 15)
        let fifthCandidate = scheduler.next(now: 15)
        let fifth = try #require(fifthCandidate)
        scheduler.completed(fifth.token, disposition: .finished, now: 15)
        #expect(scheduler.next(now: 22.5) == nil)
        #expect(scheduler.nextWakeup(now: 22.5) == 30)
        #expect(scheduler.next(now: 30) != nil)
    }

    @Test func lastFourTokensRemainAvailableForSelection() throws {
        var scheduler = OneDriveBadgeScheduler()
        let ordinary = try (0..<34).map { try demand($0) }
        scheduler.update(ordinary, now: 0)
        for _ in 0..<28 {
            let admittedCandidate = scheduler.next(now: 0)
            let admitted = try #require(admittedCandidate)
            scheduler.completed(admitted.token, disposition: .finished, now: 0)
        }
        #expect(scheduler.next(now: 0) == nil)
        let selected = try (100..<105).map { try demand($0, priority: .selected) }
        scheduler.update(Array(ordinary.dropFirst(28)) + selected, now: 0)
        for expected in selected.prefix(4) {
            let admittedCandidate = scheduler.next(now: 0)
            let admitted = try #require(admittedCandidate)
            #expect(admitted.token == expected.token)
            scheduler.completed(admitted.token, disposition: .finished, now: 0)
        }
        #expect(scheduler.next(now: 0) == nil)
        #expect(scheduler.nextWakeup(now: 0) == 1.875)
        #expect(scheduler.next(now: 1.875)?.token == selected.last?.token)
    }

    @Test func ordinaryAdmissionRequiresMoreThanReservedTokens() throws {
        var scheduler = OneDriveBadgeScheduler()
        scheduler.update(try (0..<35).map { try demand($0) }, now: 0)
        for _ in 0..<28 {
            let admittedCandidate = scheduler.next(now: 0)
            let admitted = try #require(admittedCandidate)
            scheduler.completed(admitted.token, disposition: .finished, now: 0)
        }
        #expect(scheduler.next(now: 0) == nil)
        let wakeupCandidate = scheduler.nextWakeup(now: 0)
        let wakeup = try #require(wakeupCandidate)
        #expect(wakeup > 0 && wakeup < 1.875)
        #expect(scheduler.next(now: wakeup) != nil)
    }

    @Test func routineBucketIsSharedAndSelectionCannotBypassIt() throws {
        var scheduler = OneDriveBadgeScheduler()
        let rows = try (0..<4).map {
            try demand($0, owner: $0.isMultiple(of: 2) ? firstOwner : secondOwner,
                       priority: .selected, rate: .routine)
        }
        scheduler.update(rows, now: 0)
        for _ in 0..<2 {
            let admittedCandidate = scheduler.next(now: 0)
            let admitted = try #require(admittedCandidate)
            #expect(admitted.rateClass == .routine)
            scheduler.completed(admitted.token, disposition: .finished, now: 0)
        }
        #expect(scheduler.next(now: 0) == nil)
        #expect(scheduler.nextWakeup(now: 0) == 7.5)
        scheduler.isActive = false
        #expect(scheduler.next(now: 100) == nil)
        #expect(scheduler.nextWakeup(now: 100) == nil)
        scheduler.isActive = true
        #expect(scheduler.next(now: 100) != nil)
    }

    @Test func inactiveAppStillAllowsActualSelectedDemand() throws {
        var scheduler = OneDriveBadgeScheduler()
        scheduler.isActive = false
        let routine = try demand(1, priority: .selected, rate: .routine)
        let selected = try demand(2, priority: .selected)
        scheduler.update([routine, selected], now: 0)
        #expect(scheduler.next(now: 0)?.token == selected.token)
    }

    @Test func selectedRoutineCanUseReserveButStillConsumesRoutineBudget() throws {
        var scheduler = OneDriveBadgeScheduler()
        scheduler.update(try (0..<28).map { try demand($0) }, now: 0)
        for _ in 0..<28 {
            let admittedCandidate = scheduler.next(now: 0)
            let admitted = try #require(admittedCandidate)
            scheduler.completed(admitted.token, disposition: .finished, now: 0)
        }
        scheduler.update(try (30..<33).map { try demand($0, priority: .selected, rate: .routine) }, now: 0)
        for _ in 0..<2 {
            let admittedCandidate = scheduler.next(now: 0)
            let admitted = try #require(admittedCandidate)
            #expect(admitted.priority == .selected && admitted.rateClass == .routine)
            scheduler.completed(admitted.token, disposition: .finished, now: 0)
        }
        #expect(scheduler.next(now: 0) == nil)
        #expect(scheduler.nextWakeup(now: 0) == 7.5)
    }

    @Test func duplicateOwnersPromoteWithoutRepeatingOrEscapingRoutineRate() throws {
        var scheduler = OneDriveBadgeScheduler()
        let original = try demand(1, priority: .routine, rate: .routine, sequence: 1)
        let promoted = try demand(1, owner: secondOwner, priority: .selected, sequence: 2)
        scheduler.update([original, promoted, original], now: 0)
        let admittedCandidate = scheduler.next(now: 0)
        let admitted = try #require(admittedCandidate)
        #expect(admitted.token == original.token)
        #expect(admitted.priority == .selected && admitted.rateClass == .routine)
        scheduler.completed(admitted.token, disposition: .finished, now: 0)
        #expect(scheduler.next(now: 0) == nil)
        #expect(scheduler.nextWakeup(now: 500) == nil)
    }

    @Test func equalPriorityWindowsTakeTurns() throws {
        var scheduler = OneDriveBadgeScheduler()
        let a1 = try demand(1), a2 = try demand(2), a3 = try demand(3)
        let b1 = try demand(4, owner: secondOwner), b2 = try demand(5, owner: secondOwner)
        scheduler.update([a1, a2, a3, b1, b2], now: 0)
        var owners: [UUID] = []
        for _ in 0..<5 {
            let admittedCandidate = scheduler.next(now: 0)
            let admitted = try #require(admittedCandidate)
            owners.append(admitted.owner)
            scheduler.completed(admitted.token, disposition: .finished, now: 0)
        }
        #expect(owners == [firstOwner, secondOwner, firstOwner, secondOwner, firstOwner])
    }

    @Test func replacingQueuedHintWithSelectionRetainsRoutineCharge() throws {
        var scheduler = OneDriveBadgeScheduler()
        let routine = try (0..<3).map { try demand($0, priority: .routine, rate: .routine) }
        scheduler.update(routine, now: 0)
        for _ in 0..<2 {
            let admittedCandidate = scheduler.next(now: 0)
            let admitted = try #require(admittedCandidate)
            scheduler.completed(admitted.token, disposition: .finished, now: 0)
        }
        scheduler.update([try demand(2, priority: .selected)], now: 0)
        #expect(scheduler.next(now: 0) == nil)
        #expect(scheduler.nextWakeup(now: 0) == 7.5)
        let promotedCandidate = scheduler.next(now: 7.5)
        let promoted = try #require(promotedCandidate)
        #expect(promoted.priority == .selected && promoted.rateClass == .routine)
    }

    @Test func futurePeriodicDemandDoesNotRestrictNewSelectedTrigger() throws {
        var scheduler = OneDriveBadgeScheduler()
        let periodic = try demand(1, priority: .routine, rate: .routine, eligible: 300)
        scheduler.update([periodic], now: 0)
        let selected = try demand(1, priority: .selected, eligible: 15)
        scheduler.update([selected], now: 15)
        scheduler.isActive = false
        let admittedCandidate = scheduler.next(now: 15)
        let admitted = try #require(admittedCandidate)
        #expect(admitted.priority == .selected && admitted.rateClass == .ordinary)
    }

    @Test func anotherOwnersFuturePeriodicDemandDoesNotDowngradeSelection() throws {
        var scheduler = OneDriveBadgeScheduler()
        let periodic = try demand(1, priority: .routine, rate: .routine, eligible: 300)
        let selected = try demand(1, owner: secondOwner, priority: .selected, eligible: 15)
        scheduler.update([periodic, selected], now: 15)
        scheduler.isActive = false
        #expect(scheduler.next(now: 15)?.rateClass == .ordinary)
    }

    @Test func oldestRoutineGetsEighthOpportunityDespiteSelectedDemand() throws {
        var scheduler = OneDriveBadgeScheduler()
        let selected = try (0..<12).map { try demand($0, priority: .selected) }
        let newer = try demand(50, priority: .routine, rate: .routine, requested: 1)
        let oldest = try demand(51, owner: secondOwner, priority: .routine, rate: .routine)
        scheduler.update(selected + [newer, oldest], now: 10)
        for _ in 0..<7 {
            let admittedCandidate = scheduler.next(now: 10)
            let admitted = try #require(admittedCandidate)
            #expect(admitted.priority == .selected)
            scheduler.completed(admitted.token, disposition: .finished, now: 10)
        }
        let eighthCandidate = scheduler.next(now: 10)
        let eighth = try #require(eighthCandidate)
        #expect(eighth.token == oldest.token)
        scheduler.completed(eighth.token, disposition: .finished, now: 10)
        #expect(scheduler.next(now: 10)?.priority == .selected)
    }

    @Test func exhaustedRoutineBudgetDoesNotBlockUsefulForegroundWork() throws {
        var scheduler = OneDriveBadgeScheduler()
        let routine = try (0..<3).map { try demand($0, priority: .routine, rate: .routine) }
        scheduler.update(routine, now: 0)
        for _ in 0..<2 {
            let admittedCandidate = scheduler.next(now: 0)
            let admitted = try #require(admittedCandidate)
            scheduler.completed(admitted.token, disposition: .finished, now: 0)
        }
        let selected = try (10..<20).map { try demand($0, priority: .selected) }
        scheduler.update([routine[2]] + selected, now: 0)
        for _ in 0..<8 {
            let admittedCandidate = scheduler.next(now: 0)
            let admitted = try #require(admittedCandidate)
            #expect(admitted.priority == .selected)
            scheduler.completed(admitted.token, disposition: .finished, now: 0)
        }
        #expect(scheduler.next(now: 7.5)?.token == routine[2].token)
    }

    @Test func postActionLimitIsSharedAcrossOwnersAndRollsAtSixtySeconds() throws {
        var scheduler = OneDriveBadgeScheduler()
        scheduler.update(try (0..<10).map {
            try demand($0, owner: $0.isMultiple(of: 2) ? firstOwner : secondOwner,
                       priority: .postAction, rate: .postAction)
        }, now: 100)
        for _ in 0..<8 {
            let admittedCandidate = scheduler.next(now: 100)
            let admitted = try #require(admittedCandidate)
            scheduler.completed(admitted.token, disposition: .finished, now: 100)
        }
        #expect(scheduler.next(now: 159.999) == nil)
        #expect(scheduler.nextWakeup(now: 159.999) == 160)
        #expect(scheduler.next(now: 160) != nil)
    }

    @Test func busyRefundsRoutineAdmissionExactlyOnce() throws {
        var scheduler = OneDriveBadgeScheduler()
        scheduler.update(try (0..<4).map { try demand($0, priority: .routine, rate: .routine) }, now: 0)
        let refusedCandidate = scheduler.next(now: 0)
        let refused = try #require(refusedCandidate)
        scheduler.completed(refused.token, disposition: .busy, now: 0)
        scheduler.completed(refused.token, disposition: .busy, now: 0)
        for _ in 0..<2 {
            let admittedCandidate = scheduler.next(now: 0)
            let admitted = try #require(admittedCandidate)
            scheduler.completed(admitted.token, disposition: .finished, now: 0)
        }
        #expect(scheduler.next(now: 0) == nil)
        #expect(scheduler.nextWakeup(now: 0) == 7.5)
    }

    @Test func busyRefundsPostActionSlotAndGlobalFractionWithoutOverfilling() throws {
        var scheduler = OneDriveBadgeScheduler(capacity: 4, interval: 60)
        scheduler.update(try (0..<10).map { try demand($0, priority: .selected) }, now: 0)
        for _ in 0..<4 {
            let admittedCandidate = scheduler.next(now: 0)
            let admitted = try #require(admittedCandidate)
            scheduler.completed(admitted.token, disposition: .finished, now: 0)
        }
        let refusedCandidate = scheduler.next(now: 15)
        let refused = try #require(refusedCandidate)
        scheduler.completed(refused.token, disposition: .busy, now: 22.5)
        let retriedCandidate = scheduler.next(now: 22.5)
        let retried = try #require(retriedCandidate)
        #expect(retried.token == refused.token)
        scheduler.completed(retried.token, disposition: .finished, now: 22.5)
        #expect(scheduler.nextWakeup(now: 22.5) == 30)

        var actions = OneDriveBadgeScheduler()
        actions.update(try (20..<30).map { try demand($0, priority: .postAction, rate: .postAction) }, now: 0)
        let busyCandidate = actions.next(now: 0)
        let busy = try #require(busyCandidate)
        actions.completed(busy.token, disposition: .busy, now: 0)
        for _ in 0..<8 {
            let admittedCandidate = actions.next(now: 0)
            let admitted = try #require(admittedCandidate)
            actions.completed(admitted.token, disposition: .finished, now: 0)
        }
        #expect(actions.next(now: 0) == nil)
    }

    @Test func busyRefundAfterLongWaitCapsAtCapacity() throws {
        var scheduler = OneDriveBadgeScheduler(capacity: 4, interval: 60)
        scheduler.update(try (0..<8).map { try demand($0, priority: .selected) }, now: 0)
        let refusedCandidate = scheduler.next(now: 0)
        let refused = try #require(refusedCandidate)
        scheduler.completed(refused.token, disposition: .busy, now: 600)
        for _ in 0..<4 {
            let admittedCandidate = scheduler.next(now: 600)
            let admitted = try #require(admittedCandidate)
            scheduler.completed(admitted.token, disposition: .finished, now: 600)
        }
        #expect(scheduler.next(now: 600) == nil)
    }

    @Test func removedDemandRetainsOwnerUntilActualCompletion() throws {
        var scheduler = OneDriveBadgeScheduler()
        let old = try demand(1), replacement = try demand(1, generation: 1, sequence: 2)
        scheduler.update([old], now: 0)
        let admittedCandidate = scheduler.next(now: 0)
        let admitted = try #require(admittedCandidate)
        scheduler.update([replacement], now: 1)
        scheduler.completed(replacement.token, disposition: .finished, now: 1)
        #expect(scheduler.inFlight == old.token && scheduler.next(now: 1) == nil)
        scheduler.completed(admitted.token, disposition: .busy, now: 1)
        #expect(scheduler.next(now: 1)?.token == replacement.token)
    }

    @Test func removedAdmissionCanFinishWithoutRefundOrBlockingItsReplacement() throws {
        var scheduler = OneDriveBadgeScheduler(capacity: 1, interval: 60)
        let old = try demand(1, priority: .selected), replacement = try demand(2, priority: .selected)
        scheduler.update([old], now: 0)
        let admittedValue = scheduler.next(now: 0)
        let admitted = try #require(admittedValue)
        scheduler.update([], now: 0)
        scheduler.completed(admitted.token, disposition: .finished, now: 0)
        #expect(scheduler.inFlight == nil)
        scheduler.update([replacement], now: 0)
        let immediate = scheduler.next(now: 0)
        let wakeup = scheduler.nextWakeup(now: 0)
        let refilled = scheduler.next(now: 60)
        #expect(immediate == nil, "A retired admission consumes its token; it is not a busy refund")
        #expect(wakeup == 60)
        #expect(refilled?.token == replacement.token)
    }

    @Test func removalAndBusyCompletionDoNotResurrectInvisibleWork() throws {
        var scheduler = OneDriveBadgeScheduler()
        scheduler.update([try demand(1)], now: 0)
        let admittedCandidate = scheduler.next(now: 0)
        let admitted = try #require(admittedCandidate)
        scheduler.update([], now: 1)
        #expect(scheduler.nextWakeup(now: 1) == nil)
        scheduler.completed(admitted.token, disposition: .busy, now: 2)
        #expect(scheduler.next(now: 2) == nil)
        #expect(scheduler.nextWakeup(now: 100_000) == nil)
    }

    @Test func timeReversalDoesNotCreateTokensOrMoveRefillOriginBackwards() throws {
        var scheduler = OneDriveBadgeScheduler(capacity: 1, interval: 60)
        scheduler.update([try demand(1, priority: .selected), try demand(2, priority: .selected)], now: 100)
        let admittedCandidate = scheduler.next(now: 100)
        let admitted = try #require(admittedCandidate)
        scheduler.completed(admitted.token, disposition: .finished, now: 100)
        #expect(scheduler.next(now: 130) == nil)
        #expect(scheduler.next(now: 10) == nil)
        #expect(scheduler.nextWakeup(now: 10) == 160)
        #expect(scheduler.next(now: 159.999) == nil)
        #expect(scheduler.next(now: 160) != nil)
    }

    @Test func eligibilityAndRepeatedUpdatesDoNotGeneratePeriodicSelection() throws {
        var scheduler = OneDriveBadgeScheduler()
        let selected = try demand(1, priority: .selected, eligible: 15)
        scheduler.update([selected], now: 0)
        #expect(scheduler.next(now: 14) == nil)
        #expect(scheduler.nextWakeup(now: 14) == 15)
        scheduler.update([selected, selected], now: 14)
        let admittedCandidate = scheduler.next(now: 15)
        let admitted = try #require(admittedCandidate)
        scheduler.completed(admitted.token, disposition: .finished, now: 15)
        #expect(scheduler.next(now: 30) == nil)
        #expect(scheduler.nextWakeup(now: 10_000) == nil)
    }
}
