import SwiftUI

/// How a status shows that it changed (owner approval, 17 November 2026: a status that only changed its words
/// could be missed). Two kinds, not one per state: an ordinary change crossfades its words and gives its icon one
/// short bounce; a change to a state that needs the owner (a draft ready, a question from Dot) also gives the whole
/// pill one soft pulse. With Reduce Motion on, only the crossfade remains.
struct StatusChange:ViewModifier {
    /// Changes whenever the status does; the first value shown is not animated.
    let key:String
    let needsOwner:Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse=false
    func body(content:Content) -> some View {
        content
            .contentTransition(.opacity)
            .animation(.easeInOut(duration:0.3),value:key)
            .scaleEffect(pulse ? 1.1 : 1)
            .brightness(pulse ? 0.06 : 0)
            .onChange(of:key) { _,_ in
                guard needsOwner,!reduceMotion else { return }
                withAnimation(.easeOut(duration:0.16)) { pulse=true } completion: {
                    withAnimation(.spring(duration:0.45,bounce:0.35)) { pulse=false }
                }
            }
    }
}

extension View {
    func statusChange(_ key:String,needsOwner:Bool=false) -> some View { modifier(StatusChange(key:key,needsOwner:needsOwner)) }
}

/// The status icon, which bounces once when the status changes, unless Reduce Motion is on.
struct StatusSymbol:View {
    let name:String
    let key:String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        Image(systemName:name).contentTransition(.symbolEffect(.replace)).symbolEffect(.bounce,options:.nonRepeating,value:reduceMotion ? "" : key)
    }
}
