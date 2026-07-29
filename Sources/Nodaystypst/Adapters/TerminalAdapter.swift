final class TerminalAdapter: FieldAdapter {
    func canHandle(app: RunningAppInfo, role: String?) -> Bool {
        app.bundleID == "com.mitchellh.ghostty"
    }
}
