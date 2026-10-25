// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import Foundation
import TaoolCore
import Testing
@testable import TaoolExperiments

/// A store as a fresh install has it, keeping its state at `url`.
func store(keptAt url: URL = FileManager.default.temporaryDirectory.appending(path: "taoolkit-\(UUID())/experiments.json")) -> ExperimentStore {
    ExperimentStore(file: StateFile(url: url))
}

struct ExperimentStoreTests {
    private let variants = ["control", "freeTrial"]

    @Test func bucketing_isStableAndEven() {
        let installs = (0..<10_000).map { _ in UUID().uuidString }
        let first = installs.map { ExperimentStore.bucket(experiment: "paywall", person: $0, variants: variants) }
        #expect(first == installs.map { ExperimentStore.bucket(experiment: "paywall", person: $0, variants: variants) })
        let share = Double(first.filter { $0 == "control" }.count) / Double(installs.count)
        #expect(abs(share - 0.5) < 0.03)

        // Another experiment splits the same installs independently.
        let other = installs.map { ExperimentStore.bucket(experiment: "onboarding", person: $0, variants: variants) }
        let same = Double(zip(first, other).filter { $0 == $1 }.count) / Double(installs.count)
        #expect(abs(same - 0.5) < 0.03)
    }

    @Test func variant_isKept_andCountedOnce() {
        let store = store()
        let name = store.variant(experiment: "paywall", variants: variants)
        #expect(store.variant(experiment: "paywall", variants: variants) == name)
        #expect(store.nextBatch().exposures.map(\.variant) == [name])
        #expect(store.nextBatch().exposures.first?.variants == variants)
    }

    @Test func variant_survivesARelaunch() {
        let url = FileManager.default.temporaryDirectory.appending(path: "taoolkit-\(UUID())/experiments.json")
        let first = store(keptAt: url)
        let name = first.variant(experiment: "paywall", variants: variants)
        let relaunched = store(keptAt: url)
        #expect(relaunched.person == first.person, "the same install")
        #expect(relaunched.variant(experiment: "paywall", variants: variants) == name)
        #expect(relaunched.nextBatch().exposures.count == 1, "still unsent, and not counted twice")
    }

    @Test func aNewBuildsVariants_keepTheInstallsOwn() {
        let store = store()
        let name = store.variant(experiment: "paywall", variants: variants)
        #expect(store.variant(experiment: "paywall", variants: variants + ["video"]) == name)
    }

    @Test func winner_showsForEveryone_withoutCounting() {
        let store = store()
        store.setWinners(["paywall": "freeTrial"], fetchedAt: .now)
        #expect(store.variant(experiment: "paywall", variants: variants) == "freeTrial")
        #expect(store.nextBatch().isEmpty)

        // A winner the code no longer has is ignored.
        store.setWinners(["paywall": "gold"], fetchedAt: .now)
        store.showWaiting()
        #expect(variants.contains(store.variant(experiment: "paywall", variants: variants)))
    }

    @Test func winner_ofAShownExperiment_waitsForTheForeground_orTheNextLaunch() {
        let url = FileManager.default.temporaryDirectory.appending(path: "taoolkit-\(UUID())/experiments.json")
        let device = store(keptAt: url)
        let shown = device.variant(experiment: "paywall", variants: variants)
        let other = variants.first { $0 != shown }!
        device.setWinners(["paywall": other], fetchedAt: .now)
        #expect(device.variant(experiment: "paywall", variants: variants) == shown, "not mid-screen")
        #expect(store(keptAt: url).variant(experiment: "paywall", variants: variants) == other, "a launch")
        device.showWaiting()
        #expect(device.variant(experiment: "paywall", variants: variants) == other)

        // Run again: back to the user's own, from the next foreground too.
        device.setWinners([:], fetchedAt: .now)
        #expect(device.variant(experiment: "paywall", variants: variants) == other)
        device.showWaiting()
        #expect(device.variant(experiment: "paywall", variants: variants) == shown)
    }

    @Test func forced_showsWithoutCounting() {
        let store = store()
        store.force(experiment: "paywall", variant: "freeTrial")
        #expect(store.variant(experiment: "paywall", variants: variants) == "freeTrial")
        #expect(store.nextBatch().isEmpty)
    }

    @Test func purchases_countOnlyAfterAnExposure_once() {
        let store = store()
        let now = Date()
        #expect(!store.addTransaction(id: 1, purchase: 1, jws: "a", startedAt: now), "nothing shown yet")

        _ = store.variant(experiment: "paywall", variants: variants, now: now)
        #expect(!store.addTransaction(id: 2, purchase: 2, jws: "b", startedAt: now.addingTimeInterval(-3600)), "bought before it was shown")
        #expect(store.addTransaction(id: 3, purchase: 3, jws: "c", startedAt: now.addingTimeInterval(-60)), "within the clock's slack")
        #expect(store.addTransaction(id: 4, purchase: 4, jws: "d", startedAt: now.addingTimeInterval(60)))
        #expect(!store.addTransaction(id: 4, purchase: 4, jws: "d", startedAt: now.addingTimeInterval(60)))

        let batch = store.nextBatch()
        #expect(batch.transactions.map(\.id) == [3, 4])
        store.remove(batch)
        #expect(store.nextBatch().isEmpty)
        #expect(!store.addTransaction(id: 3, purchase: 3, jws: "c", startedAt: now), "already sent")
    }

    @Test func aSubscription_sendsItsStart_andOneRenewal() {
        let store = store()
        let now = Date()
        _ = store.variant(experiment: "paywall", variants: variants, now: now)
        // A trial, then monthly renewals: the first renewal shows it became paid, the rest say nothing new.
        #expect(store.addTransaction(id: 10, purchase: 10, jws: "trial", startedAt: now))
        #expect(store.addTransaction(id: 11, purchase: 10, jws: "renewal-1", startedAt: now))
        #expect(!store.addTransaction(id: 12, purchase: 10, jws: "renewal-2", startedAt: now))
        #expect(store.nextBatch().transactions.map(\.jws) == ["trial", "renewal-1"])
    }

    @Test func goals_countOnlyAfterAnExposure_oncePerExposure() {
        let store = store()
        let now = Date()
        #expect(!store.addGoal("feature-used", now: now), "nothing shown yet")

        _ = store.variant(experiment: "onboarding", variants: variants, now: now)
        #expect(store.addGoal("feature-used", now: now.addingTimeInterval(1)))
        #expect(!store.addGoal("feature-used", now: now.addingTimeInterval(2)), "already sent since the last exposure")
        #expect(store.addGoal("signed-up", now: now.addingTimeInterval(3)))

        // A new experiment shown: the goal counts for it too, so it goes again.
        _ = store.variant(experiment: "paywall", variants: variants, now: now.addingTimeInterval(4))
        #expect(store.addGoal("feature-used", now: now.addingTimeInterval(5)))
        #expect(store.nextBatch().goals.map(\.name) == ["feature-used", "signed-up", "feature-used"])
    }

    @Test func moreThanTenVariants_areNotCounted() {
        let store = store()
        let eleven = (1...11).map { "v\($0)" }
        #expect(eleven.contains(store.variant(experiment: "price", variants: eleven)), "still shown")
        #expect(store.nextBatch().isEmpty, "taool counts ten at most")
    }

    @Test func aKeyIsTheTypesNameWithTheTypesItsIn() {
        #expect(PaywallButton.key == "PaywallButton")
        #expect(PaywallView.Variant.key == "PaywallView.Variant" && OnboardingView.Variant.key == "OnboardingView.Variant")
    }

    @Test func badNames_areNotCounted() {
        let store = store()
        #expect(store.variant(experiment: "paywall button", variants: variants) != "")
        #expect(store.nextBatch().isEmpty, "a key taool would refuse")
        _ = store.variant(experiment: "paywall", variants: variants)
        #expect(!store.addGoal("feature used"))
        #expect(store.nextBatch().exposures.map(\.experiment) == ["paywall"])
    }

    @Test func person_isTheInstallUntilStoreKitSays_thenApplesId() {
        let store = store()
        let install = store.person.id
        #expect(UUID(uuidString: install) != nil)
        #expect(store.nextBatch().previousPersonId == nil, "nothing reported yet")

        // Reported as the install, then StoreKit answered: the install's activity moves to the user.
        _ = store.variant(experiment: "paywall", variants: variants)
        store.remove(store.nextBatch())
        store.setAppTransactionId("705000000000001")
        #expect(store.person == .init(id: "705000000000001", isUser: false))
        let batch = store.nextBatch()
        #expect(batch.previousPersonId == install)
        store.remove(batch)
        #expect(store.nextBatch().isEmpty, "merged once")
    }

    @Test func aUser_isHashed_mergesOnSignIn_neverOnSignOut() {
        let store = store()
        store.setAppTransactionId("705000000000001")
        _ = store.variant(experiment: "onboarding", variants: variants)
        store.remove(store.nextBatch())

        store.setUser(" ada@example.com ")
        let person = store.person
        #expect(person.isUser && person.id == Hash.sha256("ada@example.com"), "trimmed, as the other products take it")
        #expect(!person.id.contains("@"))
        var batch = store.nextBatch()
        #expect(batch.previousPersonId == "705000000000001", "signed in: Apple's ID moves onto the user")
        store.remove(batch)

        store.setUser(nil)
        #expect(store.person.id == "705000000000001")
        batch = store.nextBatch()
        #expect(batch.previousPersonId == nil, "signing out merges no one")
        #expect(batch.isEmpty)
    }

    @Test func samePerson_sameVariant_onEveryDevice() {
        let iPhone = store(), iPad = store()
        iPhone.setUser("user-42")
        iPad.setUser("user-42")
        for i in 0..<20 {
            #expect(iPhone.variant(experiment: "e\(i)", variants: variants) == iPad.variant(experiment: "e\(i)", variants: variants))
        }
    }

    @Test func adopted_variant_waitsForTheForeground_orTheNextLaunch() {
        let url = FileManager.default.temporaryDirectory.appending(path: "taoolkit-\(UUID())/experiments.json")
        let device = store(keptAt: url)
        let first = device.variant(experiment: "paywall", variants: variants)
        let other = variants.first { $0 != first }!
        device.adopt(["paywall": other, "onboarding": "short"])
        #expect(device.variant(experiment: "onboarding", variants: ["long", "short"]) == "short", "never shown here: at once")
        #expect(device.variant(experiment: "paywall", variants: variants) == first, "shown: not mid-screen")
        #expect(store(keptAt: url).variant(experiment: "paywall", variants: variants) == other, "a launch")

        device.showWaiting()
        #expect(device.variant(experiment: "paywall", variants: variants) == other)
        device.adopt(["paywall": first])
        device.adopt(["paywall": other])
        device.showWaiting()
        #expect(device.variant(experiment: "paywall", variants: variants) == other, "the latest answer, the one shown")
    }

    @Test func batches_areCapped() {
        let store = store()
        for i in 0..<60 { _ = store.variant(experiment: "e\(i)", variants: variants) }
        let batch = store.nextBatch()
        #expect(batch.exposures.count == ExperimentStore.maxExposures)
        store.remove(batch)
        #expect(store.nextBatch().exposures.count == 60 - ExperimentStore.maxExposures)
    }
}

private enum PaywallButton: String, TaoolExperiment { case control, freeTrial }
private enum PaywallView { enum Variant: String, TaoolExperiment { case control, video } }
private enum OnboardingView { enum Variant: String, TaoolExperiment { case control, short } }
