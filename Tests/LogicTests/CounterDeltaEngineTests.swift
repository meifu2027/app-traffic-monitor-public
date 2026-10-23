import XCTest
@testable import StatsCore

final class CounterDeltaEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstSnapshotOnlyEstablishesBaseline() {
        let engine = CounterDeltaEngine()
        let result = engine.process(uploadTotal: 1000, downloadTotal: 5000,
                                    samples: [CounterSample(id: "a", upload: 100, download: 500, startedAt: t0.addingTimeInterval(-60))],
                                    at: t0)
        XCTAssertTrue(result.increments.isEmpty)
        XCTAssertFalse(result.kernelRestarted)
    }

    func testGrowthProducesDeltas() {
        let engine = CounterDeltaEngine()
        _ = engine.process(uploadTotal: 1000, downloadTotal: 5000,
                           samples: [CounterSample(id: "a", upload: 100, download: 500)], at: t0)
        let result = engine.process(uploadTotal: 1200, downloadTotal: 6500,
                                    samples: [CounterSample(id: "a", upload: 260, download: 1900)],
                                    at: t0.addingTimeInterval(1))
        XCTAssertEqual(result.increments, [CounterIncrement(id: "a", uploadDelta: 160, downloadDelta: 1400)])
    }

    func testDuplicateSnapshotProducesNothing() {
        let engine = CounterDeltaEngine()
        _ = engine.process(uploadTotal: 1000, downloadTotal: 5000,
                           samples: [CounterSample(id: "a", upload: 100, download: 500)], at: t0)
        let result = engine.process(uploadTotal: 1000, downloadTotal: 5000,
                                    samples: [CounterSample(id: "a", upload: 100, download: 500)],
                                    at: t0.addingTimeInterval(1))
        XCTAssertTrue(result.increments.isEmpty)
    }

    func testSingleConnectionRegressionRebaselinesWithoutEntry() {
        let engine = CounterDeltaEngine()
        _ = engine.process(uploadTotal: 1000, downloadTotal: 5000,
                           samples: [CounterSample(id: "a", upload: 100, download: 500)], at: t0)
        // 回退：upload 100 -> 40
        var result = engine.process(uploadTotal: 1000, downloadTotal: 5600,
                                    samples: [CounterSample(id: "a", upload: 40, download: 1100)],
                                    at: t0.addingTimeInterval(1))
        XCTAssertTrue(result.increments.isEmpty)
        XCTAssertEqual(engine.regressionCount, 1)
        // 回退后重新增长从新基线起算
        result = engine.process(uploadTotal: 1000, downloadTotal: 6000,
                                samples: [CounterSample(id: "a", upload: 90, download: 1500)],
                                at: t0.addingTimeInterval(2))
        XCTAssertEqual(result.increments, [CounterIncrement(id: "a", uploadDelta: 50, downloadDelta: 400)])
    }

    func testGlobalTotalRegressionMeansKernelRestart() {
        let engine = CounterDeltaEngine()
        _ = engine.process(uploadTotal: 10_000, downloadTotal: 50_000,
                           samples: [CounterSample(id: "a", upload: 100, download: 500)], at: t0)
        // 内核重启：downloadTotal 回退，连接计数从更小值重新累计
        let result = engine.process(uploadTotal: 300, downloadTotal: 200,
                                    samples: [CounterSample(id: "a", upload: 20, download: 90)],
                                    at: t0.addingTimeInterval(1))
        XCTAssertTrue(result.kernelRestarted)
        XCTAssertTrue(result.increments.isEmpty)
        XCTAssertEqual(engine.restartCount, 1)
        // 重启后首个快照仍是基线；随后正常作差
        let r2 = engine.process(uploadTotal: 400, downloadTotal: 350,
                                samples: [CounterSample(id: "a", upload: 20, download: 90)],
                                at: t0.addingTimeInterval(2))
        XCTAssertTrue(r2.increments.isEmpty)
        let r3 = engine.process(uploadTotal: 500, downloadTotal: 600,
                                samples: [CounterSample(id: "a", upload: 80, download: 250)],
                                at: t0.addingTimeInterval(3))
        XCTAssertEqual(r3.increments, [CounterIncrement(id: "a", uploadDelta: 60, downloadDelta: 160)])
    }

    func testNewConnectionStartedInSessionCountsFromZero() {
        let engine = CounterDeltaEngine()
        _ = engine.process(uploadTotal: 1000, downloadTotal: 5000,
                           samples: [CounterSample(id: "a", upload: 100, download: 500)], at: t0)
        // 新连接 b：建立时间在观测期内（t0+1s），首段从零计
        let result = engine.process(uploadTotal: 1500, downloadTotal: 6000,
                                    samples: [
                                        CounterSample(id: "a", upload: 100, download: 500),
                                        CounterSample(id: "b", upload: 30, download: 200, startedAt: t0.addingTimeInterval(1)),
                                    ],
                                    at: t0.addingTimeInterval(2))
        XCTAssertEqual(result.increments, [CounterIncrement(id: "b", uploadDelta: 30, downloadDelta: 200)])
    }

    func testNewConnectionWithUnknownStartOnlyBuildsBaseline() {
        let engine = CounterDeltaEngine()
        _ = engine.process(uploadTotal: 1000, downloadTotal: 5000,
                           samples: [CounterSample(id: "a", upload: 100, download: 500)], at: t0)
        // 无建立时间的新连接：只建基线，不把存量记入当前区间
        var result = engine.process(uploadTotal: 2000, downloadTotal: 7000,
                                    samples: [
                                        CounterSample(id: "a", upload: 100, download: 500),
                                        CounterSample(id: "c", upload: 700, download: 1500, startedAt: nil),
                                    ],
                                    at: t0.addingTimeInterval(1))
        XCTAssertTrue(result.increments.isEmpty)
        // 后续增长正常入账
        result = engine.process(uploadTotal: 2100, downloadTotal: 7300,
                                samples: [
                                    CounterSample(id: "a", upload: 100, download: 500),
                                    CounterSample(id: "c", upload: 750, download: 1800, startedAt: nil),
                                ],
                                at: t0.addingTimeInterval(2))
        XCTAssertEqual(result.increments, [CounterIncrement(id: "c", uploadDelta: 50, downloadDelta: 300)])
    }

    func testDisappearedConnectionKeepsLastAccountedState() {
        let engine = CounterDeltaEngine()
        _ = engine.process(uploadTotal: 1000, downloadTotal: 5000,
                           samples: [CounterSample(id: "a", upload: 100, download: 500)], at: t0)
        _ = engine.process(uploadTotal: 1100, downloadTotal: 5500,
                           samples: [CounterSample(id: "a", upload: 150, download: 900)],
                           at: t0.addingTimeInterval(1))
        // a 消失：不产生任何补造增量；同 ID 若以旧计数重现按回退/基线处理
        let result = engine.process(uploadTotal: 1100, downloadTotal: 5500,
                                    samples: [],
                                    at: t0.addingTimeInterval(2))
        XCTAssertTrue(result.increments.isEmpty)
    }
}
