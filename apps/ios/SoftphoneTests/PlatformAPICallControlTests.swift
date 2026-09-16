import Foundation
import Testing
@testable import SoftphoneKit

/// Hold and recording go through the control plane with the device bearer (contract §10.6, §12.8).
@MainActor
struct PlatformAPICallControlTests {
    private func api() -> PlatformAPI {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return PlatformAPI(baseURL: URL(string: "https://api.test")!, bearer: "dvt_x", session: URLSession(configuration: cfg))
    }

    @Test func holdUnholdAndRecordUseTheCallEndpoints() async throws {
        StubProtocol.requests = []
        StubProtocol.responder = { _ in (200, Data(#"{"status":"ok"}"#.utf8)) }
        let a = api()
        try await a.hold(callID: "c1")
        try await a.unhold(callID: "c1")
        try await a.record(callID: "c1", action: "start")
        let paths = StubProtocol.requests.map { ($0.httpMethod ?? "") + " " + ($0.url?.path ?? "") }
        #expect(paths == ["POST /v1/calls/c1/hold", "POST /v1/calls/c1/unhold", "POST /v1/calls/c1/record"])
        #expect(StubProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer dvt_x" })
        let body = StubProtocol.requests[2].httpBody ?? StubProtocol.requests[2].httpBodyStream.map { s -> Data in
            s.open(); defer { s.close() }
            var d = Data(); var buf = [UInt8](repeating: 0, count: 256)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n > 0 { d.append(buf, count: n) } else { break } }
            return d
        } ?? Data()
        #expect(String(data: body, encoding: .utf8) == #"{"action":"start"}"#)
    }

    @Test func licenseRefusalIsReadable() async {
        StubProtocol.responder = { _ in (402, Data(#"{"error":{"code":"feature_not_licensed","message":"seat lacks recording"}}"#.utf8)) }
        do {
            try await api().record(callID: "c1", action: "start")
            #expect(Bool(false), "expected a failure")
        } catch let f as PlatformAPI.Failure {
            #expect(f.status == 402)
            #expect(f.userMessage == "Recording is not included in your seat.")
        } catch {
            #expect(Bool(false), "unexpected \(error)")
        }
    }
}
