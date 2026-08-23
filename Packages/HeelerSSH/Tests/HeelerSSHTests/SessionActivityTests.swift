import Testing

@testable import HeelerSSH

@Test("an invalidation generation rejects a watch armed before it")
func invalidationGenerationRejectsAWatchArmedBeforeIt() {
    let activity = SessionActivity()
    let watch = activity.watch()
    activity.releaseAllWaiters()

    let waiter = DispatchWaiter()
    #expect(watch.register(waiter) == false)

    let fresh = activity.watch()
    #expect(fresh.register(waiter))
    fresh.unregister(waiter)
}

@Test("a transport-send owner error with outbound pending invalidates")
func transportSendOwnerErrorWithOutboundPendingInvalidates() {
    #expect(
        SessionDriver.transportSendOwnerDisposition(
            result: -37,
            isCurrentOwner: true,
            hasOutbound: true) == .invalidate)
    #expect(
        SessionDriver.transportSendOwnerDisposition(
            result: -37,
            isCurrentOwner: true,
            hasOutbound: false) == .clear)
    #expect(
        SessionDriver.transportSendOwnerDisposition(
            result: -37,
            isCurrentOwner: false,
            hasOutbound: true) == .unchanged)
}
