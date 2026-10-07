// Services and Shortcuts (PRD SC8, PT7, T10): Nib's work on text in any app, without going to
// Nib. Services › Append to Nib Scratch puts the selection at the end of the scratch file, cleaned
// as Paste Clean cleans it (Append Clipboard to Scratch's way, SC6); Services › Clean Text puts
// the selection back as its cleaned plain text (PT7). For Shortcuts, three App Intents: Append to
// Scratch, Get Scratch (the text as it is in Nib, typing not yet saved included) and Clean Text.
// Launched for one of them, Nib waits up to 15 s for the scratch file to open, as `nib -a` does.
// A test run's Nib offers no Services (its own would answer the user's).

import AppIntents
import AppKit
import NibText

/// `NSApp.servicesProvider`: the messages Support/Info.plist's NSServices name.
@MainActor
final class ServiceProvider: NSObject {
    static let shared = ServiceProvider()

    /// Services › Append to Nib Scratch.
    @objc func appendToScratch(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            error.pointee = "There's no text to append." as NSString
            return
        }
        if Documents.scratch.ready {
            let appended = Clipboard.append(text, action: "Append to Nib Scratch", from: "THE SELECTION")
            if case .lines = appended { Self.confirm(appended) } else { error.pointee = Spoken.sentence(appended.hud) as NSString }
        } else {
            Task { Self.confirm(await Self.appendWhenOpen(text, action: "Append to Nib Scratch", from: "THE SELECTION")) }   // just launched for it
        }
    }

    /// Said where it can be seen: with the scratch window behind, the Toast, as Append Clipboard
    /// to Scratch shows it (it confirmed nothing: the QA review's F63).
    static func confirm(_ appended: Clipboard.Appended) {
        if !NSApp.isActive || AppDelegate.scratchWindow?.isKeyWindow != true { Toast.show(appended.hud) }
    }

    /// Services › Clean Text: the selection replaced by its cleaned plain text.
    @objc func cleanText(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string) else {
            error.pointee = "There's no text to clean." as NSString
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(CleanTextIntent.clean(text), forType: .string)
    }

    /// Once the scratch file is open (up to 15 s), the text appended to it.
    static func appendWhenOpen(_ text: String, action: String, from source: String) async -> Clipboard.Appended {
        let document = Documents.scratch
        for _ in 0..<150 where !document.ready && document.locked == nil { try? await Task.sleep(for: .milliseconds(100)) }
        return Clipboard.append(text, action: action, from: source)
    }
}

/// Shortcuts › Nib › Append to Scratch.
struct AppendToScratchIntent: AppIntent {
    static let title: LocalizedStringResource = "Append to Scratch"
    static let description = IntentDescription("Adds text to the end of Nib's scratch file, after a blank line, cleaned as Paste Clean cleans it.")

    @Parameter(title: "Text")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Append \(\.$text) to the scratch file")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let appended = await ServiceProvider.appendWhenOpen(text, action: "Append to Scratch", from: "THE TEXT")
        guard case .lines = appended else { throw NibIntentError.message(Spoken.sentence(appended.hud)) }
        return .result()
    }
}

/// Shortcuts › Nib › Get Scratch.
struct GetScratchIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Scratch"
    static let description = IntentDescription("Gets the scratch file's text as it is in Nib, including typing not yet saved.")   // a sentence (F75)

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await Self.text())
    }

    @MainActor
    static func text() async throws -> String {
        let document = Documents.scratch
        for _ in 0..<150 where !document.ready && document.locked == nil { try? await Task.sleep(for: .milliseconds(100)) }
        // Why, as the strip says it (F75: it failed saying only that it wasn't open).
        guard document.ready else { throw NibIntentError.message("The scratch file isn't open in Nib: \(SyncState.midSentence(document.locked.map(Spoken.sentence) ?? document.state.spoken)).") }
        return document.editor.textView.string
    }
}

/// Shortcuts › Nib › Clean Text.
struct CleanTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean Text"
    static let description = IntentDescription("Makes text plain, as Paste Clean does: removes invisible characters, makes unusual spaces plain and trims trailing whitespace.")

    @Parameter(title: "Text")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Clean \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: Self.clean(text))
    }

    @MainActor
    static func clean(_ text: String) -> String { PasteCleaner.clean(text, options: Clipboard.options).text }
}

enum NibIntentError: Error, CustomLocalizedStringResourceConvertible {
    case message(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .message(let text): "\(text)"
        }
    }
}
