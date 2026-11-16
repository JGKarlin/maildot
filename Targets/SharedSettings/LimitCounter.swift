import SwiftUI
import BridgeCore

/// "2,140 of 5,000" under a box once the text nears its limit, so a button never greys out without a reason (owner's OK,
/// 16 November 2026). In red past the limit.
struct LimitCounter:ViewModifier {
    let count:Int
    let limit:Int
    let from:Int
    func body(content:Content) -> some View {
        VStack(alignment:.trailing,spacing:2) {
            content
            if count >= from {
                Text("\(count) of \(limit)").font(.caption2).monospacedDigit()
                    .foregroundStyle(count > limit ? MailDotStyle.dangerText : MailDotStyle.supporting)
                    .accessibilityLabel(Text("\(count) of \(limit)"))
            }
        }
    }
}

extension View {
    /// For words to Dot about a reply: shown from 1,500 characters.
    func guidanceCounter(_ text:String) -> some View { modifier(LimitCounter(count:text.count,limit:ReplyOwnerRequest.textLimit,from:1500)) }
    /// For a drafting rule or note: shown from 450 characters.
    func ruleCounter(_ text:String,limit:Int) -> some View { modifier(LimitCounter(count:text.count,limit:limit,from:limit*3/4)) }
}
