import Foundation

/// The ChatGPT desktop app's own call control for a dot, as its interface labels it. Mail Dot starts a
/// call by pressing "Start call" through Accessibility; these labels are how it knows what it is looking at.
/// (Build 62 pressed the app's Option-V shortcut instead; on the owner's Mac that started nothing.)
public enum DotCallControl {
    public static let start="Start call"
    /// Labels the control, or its neighbours, carry only while a call is being placed or is open.
    public static let duringCall:Set<String>=["Hang up","Calling…","Call in progress","Mute microphone","Unmute microphone"]
    public static var all:Set<String> { duringCall.union([start]) }

    public enum State:Equatable,Sendable { case inCall,canStart,absent }
    /// What the labels on screen mean. A call that is open wins: pressing anything then could end it.
    public static func state(labels:[String]) -> State {
        if labels.contains(where:duringCall.contains) { return .inCall }
        return labels.contains(start) ? .canStart : .absent
    }
}
