import Foundation
import Testing
@testable import MacModelBridge

struct LoopbackModelProviderTests {
    @Test func acceptsOnlyLiteralLocalHTTP() throws {
        let local = try LoopbackModelProvider(
            baseURL: #require(URL(string: "http://127.0.0.1:11434/v1")),
            modelName: "gemma3:4b"
        )
        #expect(local.modelID == "local:gemma3:4b")
        for address in [
            "https://127.0.0.1:11434/v1",
            "http://example.com/v1",
            "http://192.168.1.2:11434/v1",
            "http://user:secret@127.0.0.1:11434/v1"
        ] {
            #expect(throws: Error.self) {
                try LoopbackModelProvider(baseURL: #require(URL(string: address)), modelName: "test")
            }
        }
    }
}
