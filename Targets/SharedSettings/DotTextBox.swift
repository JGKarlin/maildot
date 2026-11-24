import SwiftUI
import AppKit
import BridgeCore

/// The one box for writing to Dot, the same on every Mail Dot panel inside Mail (owner decision, 20 November 2026:
/// the boxes had three layouts and three names for sending). The text box, at least four lines tall so that its top
/// meets Dictate, with Dictate, Call Dot and Tell Dot stacked to its right; Tell Dot is the filled button.
struct DotTextBox:View {
    let placeholder:LocalizedStringKey
    @Binding var text:String
    var focus:FocusState<Bool>.Binding
    /// The box's height in lines: it starts at the lower bound and grows to the upper.
    var lines:ClosedRange<Int>=4...8
    /// False while there is nothing to tell Dot about yet, such as a revision before Dot's draft: the box, Dictate and
    /// Tell Dot are greyed. Call Dot stays available.
    var enabled=true
    /// Whether what is typed may be sent: not empty, and within the limit of what it is sent as.
    var canTell:Bool?
    /// Shows the character count as the text nears the limit of an instruction to Dot.
    var counted=true
    var callHelp:LocalizedStringKey="Talk this reply over with Dot on a voice call"
    let call:() -> Void
    let tell:() -> Void
    /// Called when macOS dictation is not available, with the words to show the owner.
    var dictationUnavailable:(String) -> Void = { _ in }

    private var sendable:Bool {
        enabled && (canTell ?? (!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && text.count <= ReplyOwnerRequest.textLimit))
    }
    var body:some View {
        HStack(alignment:.top,spacing:8) {
            field
                .lineLimit(lines).textFieldStyle(.roundedBorder).focused(focus).disabled(!enabled)
                .onSubmit { if sendable { tell() } }
                // Return sends; Shift-Return starts a new line where the cursor is (owner request, 24 November 2026). While
                // an input method is composing, as in Japanese, the key is left to it, so confirming a conversion never
                // sends and never adds a line.
                .onKeyPress(.return,phases:.down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    if let editor=NSApp.keyWindow?.firstResponder as? NSTextView,editor.hasMarkedText() { return .ignored }
                    NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),to:nil,from:nil)
                    return .handled
                }
            VStack(alignment:.trailing,spacing:8) {
                Button { dictate() } label: { Label("Dictate",systemImage:"mic") }
                    .help("Start Dictation (same as your dictation shortcut). macOS types what you say into the box; this is not a call with Dot.")
                    .disabled(!enabled)
                Button("Call Dot",systemImage:"phone",action:call).help(callHelp)
                Button("Tell Dot",systemImage:"text.bubble",action:tell).buttonStyle(.borderedProminent).disabled(!sendable)
            }.fixedSize()
        }
    }
    @ViewBuilder private var field:some View {
        if counted { TextField(placeholder,text:$text,axis:.vertical).guidanceCounter(text) }
        else { TextField(placeholder,text:$text,axis:.vertical) }
    }
    /// Starts macOS's own dictation in the box: the system listens and types the words in. Mail Dot does not hear the
    /// microphone itself, and nothing goes to Dot until Tell Dot.
    private func dictate() {
        focus.wrappedValue=true
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {
            if !NSApp.sendAction(Selector(("startDictation:")),to:nil,from:nil) {
                dictationUnavailable(String(localized:"Dictation is not available. Turn it on in System Settings, Keyboard, Dictation."))
            }
        }
    }
}
