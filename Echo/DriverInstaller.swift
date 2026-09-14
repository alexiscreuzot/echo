import Foundation

enum DriverInstaller {
    static let installPath = "/Library/Audio/Plug-Ins/HAL/Echo.driver"

    static var bundledURL: URL? {
        Bundle.main.builtInPlugInsURL?.appendingPathComponent("Echo.driver")
    }

    static func needsInstall() -> Bool {
        guard let bundledURL, FileManager.default.fileExists(atPath: bundledURL.path) else {
            return false
        }
        if !FileManager.default.fileExists(atPath: installPath) {
            return true
        }
        return version(of: bundledURL) > version(of: URL(fileURLWithPath: installPath))
    }

    static func ensureInstalled() async throws {
        guard needsInstall() else { return }
        guard let bundledURL else { throw EchoError.deviceMissing }

        try await Task.detached {
            try install(from: bundledURL)
        }.value

        try await waitForDevice()
    }

    private static func install(from source: URL) throws {
        let dest = installPath
        let shell = [
            "rm -rf \(shQuote(dest))",
            "cp -R \(shQuote(source.path)) \(shQuote(dest))",
            "chown -R root:wheel \(shQuote(dest))",
            "killall coreaudiod",
        ].joined(separator: " && ")

        let appleScript = "do shell script \(appleQuote(shell)) with administrator privileges"
        guard let script = NSAppleScript(source: appleScript) else {
            throw EchoError.driverInstallFailed("Could not prepare the install script.")
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 {
                throw EchoError.driverInstallCancelled
            }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Install failed."
            throw EchoError.driverInstallFailed(message)
        }
    }

    private static func waitForDevice() async throws {
        for _ in 0..<50 {
            if EchoDevice.objectID() != nil { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw EchoError.deviceMissing
    }

    private static func version(of driver: URL) -> Int {
        let plist = driver.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              let raw = info["CFBundleVersion"] as? String,
              let value = Int(raw)
        else { return 0 }
        return value
    }

    private static func shQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func appleQuote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
