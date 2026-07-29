import Foundation

final class AdapterRegistry {
    private let codex: CodexAdapter
    private let chromeElectron: ChromeElectronAdapter
    private let terminal: TerminalAdapter
    private let native: NativeAdapter

    init(
        codex: CodexAdapter = CodexAdapter(),
        chromeElectron: ChromeElectronAdapter? = nil,
        terminal: TerminalAdapter = TerminalAdapter(),
        native: NativeAdapter = NativeAdapter()
    ) {
        #if DEBUG
        let forceUntrusted = ProcessInfo.processInfo.environment[
            "NODAYSTYPST_FORCE_CHROME_GEOMETRY_UNTRUSTED"
        ] == "1"
        #else
        let forceUntrusted = false
        #endif
        self.codex = codex
        self.chromeElectron = chromeElectron ?? ChromeElectronAdapter(
            forceUntrustedGeometryForDebug: forceUntrusted
        )
        self.terminal = terminal
        self.native = native
    }

    func adapter(for app: RunningAppInfo, role: String?) -> any FieldAdapter {
        let ordered: [any FieldAdapter] = [codex, chromeElectron, terminal, native]
        return ordered.first(where: { $0.canHandle(app: app, role: role) }) ?? native
    }
}
