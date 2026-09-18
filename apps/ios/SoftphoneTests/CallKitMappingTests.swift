import CallKit
import Testing
import linphonesw
@testable import SoftphoneKit

/// The pure parts of the CallKit bridge (docs/07): handle types and the end-reason mapping. The provider itself
/// is real-device evidence only (S14).
struct CallKitMappingTests {
    @Test func phoneNumbersAreHandlesCallKitCanFormat() {
        #expect(CallKitBridge.handleType(for: "+32473981616") == .phoneNumber)
        #expect(CallKitBridge.handleType(for: "0473981616") == .phoneNumber)
        #expect(CallKitBridge.handleType(for: "1002") == .phoneNumber)
    }

    @Test func anythingElseIsGeneric() {
        #expect(CallKitBridge.handleType(for: "*98") == .generic)
        #expect(CallKitBridge.handleType(for: "sales") == .generic)
        #expect(CallKitBridge.handleType(for: "") == .generic)
        #expect(CallKitBridge.handleType(for: "+") == .generic)
    }

    @Test func endedReasonsMapOneToOne() {
        #expect(CallKitBridge.endedReason(.remoteEnded) == .remoteEnded)
        #expect(CallKitBridge.endedReason(.unanswered) == .unanswered)
        #expect(CallKitBridge.endedReason(.answeredElsewhere) == .answeredElsewhere)
        #expect(CallKitBridge.endedReason(.declinedElsewhere) == .declinedElsewhere)
        #expect(CallKitBridge.endedReason(.failed) == .failed)
    }

    @Test func theOtherDeviceOfTheUserIsReportedAsElsewhere() {
        #expect(CallEngine.endCause(status: .AcceptedElsewhere, direction: .Incoming, protocolCode: 0, hungUpLocally: false) == .answeredElsewhere)
        #expect(CallEngine.endCause(status: .DeclinedElsewhere, direction: .Incoming, protocolCode: 0, hungUpLocally: false) == .declinedElsewhere)
        #expect(CallEngine.endCause(status: .Missed, direction: .Incoming, protocolCode: 0, hungUpLocally: false) == .unanswered)
    }

    @Test func networkRefusalsOfAnOutgoingCallAreFailures() {
        #expect(CallEngine.endCause(status: .Aborted, direction: .Outgoing, protocolCode: 404, hungUpLocally: false) == .failed)
        #expect(CallEngine.endCause(status: .Aborted, direction: .Outgoing, protocolCode: 403, hungUpLocally: false) == .failed)
        // busy and decline are answers from the far end, not failures
        #expect(CallEngine.endCause(status: .Aborted, direction: .Outgoing, protocolCode: 486, hungUpLocally: false) == .remoteEnded)
        #expect(CallEngine.endCause(status: .Declined, direction: .Outgoing, protocolCode: 603, hungUpLocally: false) == .remoteEnded)
        #expect(CallEngine.endCause(status: .Success, direction: .Outgoing, protocolCode: 0, hungUpLocally: false) == .remoteEnded)
        #expect(CallEngine.endCause(status: .Success, direction: .Incoming, protocolCode: 0, hungUpLocally: true) == .remoteEnded)
    }
}
