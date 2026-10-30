import MMClient
import Testing

// Exit tests run their body in a child process, which iOS, tvOS, watchOS and
// visionOS do not allow; every test here is one.
#if !os(iOS) && !os(tvOS) && !os(watchOS) && !os(visionOS)
@Suite("Declarative client builder")
struct ClientBuilderTests {
    @Test("missing Configuration is programmer error — the endpoint is not defaultable")
    func missingConfiguration() async throws {
        await #expect(processExitsWith: .failure) {
            _ = MMClient {
                Log(label: "test.client")
            }
        }
    }

    @Test("duplicate parts are programmer error")
    func duplicateConfiguration() async throws {
        await #expect(processExitsWith: .failure) {
            _ = MMClient {
                Configuration(endpoint: .unix(path: "/tmp/a.sock"))
                Configuration(endpoint: .unix(path: "/tmp/b.sock"))
            }
        }
    }

    @Test("a schema in both Schema and a prebuilt Configuration is declared twice")
    func schemaDeclaredTwice() async throws {
        await #expect(processExitsWith: .failure) {
            _ = MMClient {
                Configuration(
                    MMClientConfiguration(schema: .partial([])),
                    endpoint: .unix(path: "/tmp/c.sock")
                )
                Schema(.partial([]))
            }
        }
    }
}
#endif
