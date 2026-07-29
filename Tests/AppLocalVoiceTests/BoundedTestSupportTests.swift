import XCTest

final class BoundedTestSupportTests: XCTestCase {
    func testTimeoutReturnsWithoutWaitingForANonCooperativeOperation() async throws {
        let gate = NonCooperativeGate()
        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await withBoundedTimeout(.milliseconds(1)) {
                await gate.wait()
            }
            XCTFail("non-cooperative operation unexpectedly completed")
        } catch let error as BoundedTestError {
            guard case .timedOut = error else { return XCTFail("unexpected timeout error") }
        }
        await gate.release()
        XCTAssertLessThan(clock.now - started, .seconds(1))
    }
}

private actor NonCooperativeGate {
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}
