import Foundation

/// The names ChatGPT gives the controls Mail Dot uses, in every language ChatGPT is shown in.
///
/// Mail Dot finds the Start call control, the call's own controls and Send by their names. Those names are
/// translated: with ChatGPT in Japanese, Mail Dot found neither the message field nor Start call, so setup and calls
/// worked in English only (owner's test, 18 November 2026). ChatGPT carries its translations in its own files, one
/// table per language, each name under a key that is the same in every language. Mail Dot reads those tables from the
/// ChatGPT app on this Mac, as it reads Mail's own name for its Extensions tab, and accepts a control named in any of
/// them. The English names are always accepted, so nothing changes where the tables cannot be read.
public struct ChatGPTLabels: Codable, Equatable, Sendable {
    public var start: Set<String>
    public var hangUp: Set<String>
    /// Names shown only while a call is being placed or is open, Hang up apart.
    public var otherDuringCall: Set<String>
    public var send: Set<String>

    public init(start: Set<String>, hangUp: Set<String>, otherDuringCall: Set<String>, send: Set<String>) {
        self.start = start; self.hangUp = hangUp; self.otherDuringCall = otherDuringCall; self.send = send
    }
    public static let english = ChatGPTLabels(start: [DotCallControl.start], hangUp: ["Hang up"],
                                              otherDuringCall: ["Calling…", "Call in progress", "Mute microphone", "Unmute microphone"], send: ["Send"])
    public var duringCall: Set<String> { hangUp.union(otherDuringCall) }
    public var all: Set<String> { duringCall.union(start) }

    /// The key every translation table holds; a file without it is not one of ChatGPT's tables.
    public static let marker = "restricted.orbit.voiceCall.start"
    static let startKeys = [marker]
    static let hangUpKeys = ["restricted.orbit.voiceCall.hangUp"]
    static let duringCallKeys = ["restricted.orbit.voiceCall.calling", "restricted.orbit.voiceCall.sidebarActive",
                                 "restricted.orbit.voiceCall.muteMic", "restricted.orbit.voiceCall.unmuteMic"]
    static let sendKeys = ["chatgptConversations.composer.send.ariaLabel", "composer.submitButtonTooltip.send"]

    /// The names in ChatGPT's translation tables, added to the English ones. A table is the text of one of
    /// ChatGPT's files: a list of "key":"name" pairs. Only the names under Mail Dot's few keys are taken.
    public static func reading(tables: [Data]) -> ChatGPTLabels {
        var labels = english
        for table in tables { labels.add(table: table) }
        return labels.settled()
    }
    /// Takes the names from one table; a file that is not one of ChatGPT's tables adds nothing.
    public mutating func add(table: Data) {
        guard table.range(of: Data("\"\(Self.marker)\":\"".utf8)) != nil else { return }
        for key in Self.startKeys { if let name = Self.name(for: key, in: table) { start.insert(name) } }
        for key in Self.hangUpKeys { if let name = Self.name(for: key, in: table) { hangUp.insert(name) } }
        for key in Self.duringCallKeys { if let name = Self.name(for: key, in: table) { otherDuringCall.insert(name) } }
        for key in Self.sendKeys { if let name = Self.name(for: key, in: table) { send.insert(name) } }
    }
    /// A name that starts a call in one language must never count as "in a call" in another: a second press could
    /// hang up, so such a name is dropped from the start names.
    public func settled() -> ChatGPTLabels {
        var labels = self
        labels.start.subtract(labels.duringCall)
        labels.start.insert(DotCallControl.start)
        return labels
    }
    /// The name under one key: the text between the quotation marks after it. A name with an escape, a
    /// placeholder or an unlikely length is left out; a control's name is a few plain words.
    static func name(for key: String, in table: Data) -> String? {
        guard let found = table.range(of: Data("\"\(key)\":\"".utf8)) else { return nil }
        let rest = table[found.upperBound...]
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")), end - rest.startIndex <= 240,
              let name = String(data: rest[rest.startIndex..<end], encoding: .utf8) else { return nil }
        guard !name.isEmpty, name.count <= 60, !name.contains("\\"), !name.contains("{"), !name.contains("<") else { return nil }
        return name
    }
}

/// The ChatGPT desktop app's own call control for a dot, as its interface labels it. Mail Dot starts a
/// call by pressing "Start call" through Accessibility; these labels are how it knows what it is looking at.
/// (Build 62 pressed the app's Option-V shortcut instead; on the owner's Mac that started nothing.)
public enum DotCallControl {
    public static let start="Start call"
    /// Labels the control, or its neighbours, carry only while a call is being placed or is open.
    public static var duringCall:Set<String> { ChatGPTLabels.english.duringCall }
    public static var all:Set<String> { ChatGPTLabels.english.all }

    public enum State:Equatable,Sendable { case inCall,canStart,absent }
    /// What the labels on screen mean. A call that is open wins: pressing anything then could end it.
    public static func state(labels:[String],known:ChatGPTLabels = .english) -> State {
        if labels.contains(where:known.duringCall.contains) { return .inCall }
        return labels.contains(where:known.start.contains) ? .canStart : .absent
    }
}
