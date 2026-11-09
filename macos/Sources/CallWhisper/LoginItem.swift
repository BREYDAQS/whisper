import ServiceManagement

/// Start przy logowaniu przez `SMAppService` — systemowy login item, widoczny
/// w Ustawieniach systemowych → Ogólne → Rzeczy otwierane podczas logowania.
///
/// Rejestrowana jest paczka spod jej obecnej ścieżki (`macos/build`), tej
/// samej, którą przebudowuje `Updater`, więc wpis przeżywa aktualizacje.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// `call-whisper --login-item on|off` — dla `make install`.
func runLoginItem(_ value: String) -> Int32 {
    do {
        try LoginItem.set(value == "on")
        print("login item: \(LoginItem.isEnabled ? "włączony" : "wyłączony")"
              + (LoginItem.status == .requiresApproval ? " (zatwierdź w Ustawieniach systemowych → Ogólne → Rzeczy otwierane podczas logowania)" : ""))
        return 0
    } catch {
        FileHandle.standardError.write(Data("login item: \(error.localizedDescription)\n".utf8))
        return 1
    }
}
