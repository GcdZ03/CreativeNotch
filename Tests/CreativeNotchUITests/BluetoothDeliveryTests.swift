import Foundation
import Testing
@testable import CreativeNotchUI

/// Where IOBluetooth's callbacks land, and how they reach the main actor.
///
/// On macOS 26 a connect notification is delivered on IOBluetooth's own
/// coordinator queue, not the run loop the registration was made on. The
/// callbacks used to `MainActor.assumeIsolated` there, which traps — the
/// app quit the moment AirPods connected (2026-10-25). They hop instead.
struct BluetoothDeliveryTests {

    /// Called from a background queue, the way IOBluetooth calls it, the
    /// work still runs — on the main thread — and nothing traps.
    @Test func aCallbackFromABackgroundQueueRunsOnTheMainThread() async {
        let ranOnMain = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                IOBluetoothSource.deliverOnMain {
                    done.resume(returning: Thread.isMainThread)
                }
            }
        }
        #expect(ranOnMain)
    }

    /// A connect then a disconnect from the same queue arrive in that order.
    @Test func callbacksKeepTheirOrder() async {
        let order = await withCheckedContinuation { (done: CheckedContinuation<[String], Never>) in
            let queue = DispatchQueue(label: "test.iobluetooth.coordinator")
            queue.async {
                nonisolated(unsafe) var seen: [String] = []
                IOBluetoothSource.deliverOnMain { seen.append("connect") }
                IOBluetoothSource.deliverOnMain {
                    seen.append("disconnect")
                    done.resume(returning: seen)
                }
            }
        }
        #expect(order == ["connect", "disconnect"])
    }

    /// The callbacks must not assume the main actor on their own again.
    @Test func theCallbacksDoNotAssumeTheMainActor() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/CreativeNotchUI/Bluetooth/BluetoothSource.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "final class IOBluetoothSource"))
        let end = try #require(source.range(of: "final class SystemBluetoothAccess"))
        let body = source[start.upperBound..<end.lowerBound]
        let assumes = body.components(separatedBy: "MainActor.assumeIsolated").count - 1
        #expect(assumes == 1, "only deliverOnMain, after its hop to the main queue, may assume isolation")
    }
}
