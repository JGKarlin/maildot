import SwiftUI
import AppKit

/// Shared colours. The brand blue belongs to the icon. Controls use the system accent colour, as Apple's
/// guidance asks (owner request, 13 November 2026): it has its own light and dark shades, keeps the
/// contrast macOS designs for, and follows the accent colour the owner chose in System Settings. The fixed
/// #0077C8 used before was too dark against dark backgrounds.
enum MailDotStyle {
    /// #00B1FF, the Mail Dot blue, for the logo only.
    static let brand=Color(red:0,green:177.0/255.0,blue:1)
    static let tint=Color.accentColor
    // Text colours that read at 4.5:1 or better on Mail Dot's window, its cards and its grey headers, in light and in
    // dark (owner's approval of the contrast fix, 15 November 2026). macOS's own secondary grey reaches only 3.9:1 on
    // white, and its green, orange and red 2.2 to 3.6:1, so text uses these; icons keep the system colours.
    /// Supporting text: captions, footnotes, the version line. The system's secondary grey in dark, a darker grey in light.
    static let supporting=adaptive(light:0x636366,dark:0xA1A1A6)
    static let warningText=adaptive(light:0xA84B00,dark:0xFF9F0A)
    static let dangerText=adaptive(light:0xC0261F,dark:0xFF6961)
    static let successText=adaptive(light:0x1E7B34,dark:0x32D74B)
    /// Links and accent-coloured words.
    static let linkText=adaptive(light:0x005BC1,dark:0x5EA8FF)
    private static func adaptive(light:UInt32,dark:UInt32) -> Color {
        func color(_ hex:UInt32) -> NSColor { NSColor(srgbRed:CGFloat((hex >> 16) & 0xFF)/255,green:CGFloat((hex >> 8) & 0xFF)/255,blue:CGFloat(hex & 0xFF)/255,alpha:1) }
        return Color(nsColor:NSColor(name:nil) { appearance in
            appearance.bestMatch(from:[.aqua,.darkAqua,.accessibilityHighContrastAqua,.accessibilityHighContrastDarkAqua]).map{ [.darkAqua,.accessibilityHighContrastDarkAqua].contains($0) } == true ? color(dark) : color(light)
        })
    }
}

/// The version and build that is running, shown in the panels inside Mail so the owner can tell which build they have.
enum MailDotVersion {
    static var text:String {
        let info=Bundle.main.infoDictionary
        return "Mail Dot \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

/// The footer of Settings (owner request, 14 November 2026): the version, the copyright and developer line the app
/// carries, and the project's page. Settings is the one place inside Mail where these reach the owner.
struct MailDotCredits:View {
    /// The project's page on GitHub (live from 15 November 2026).
    static let projectPage:URL?=URL(string:"https://jgkarlin.github.io/maildot/")
    /// The owner's tip jar (owner request, 14 November 2026). Mail Dot has no menu bar, so it sits here.
    static let tipJar=URL(string:"https://donate.stripe.com/6oU4gA7Qm7Gl3103T333W00")!
    var body:some View {
        VStack(alignment:.leading,spacing:2) {
            Group {
                Text(MailDotVersion.text)
                if let copyright=Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String { Text(copyright) }
            }.foregroundStyle(MailDotStyle.supporting)
            if let page=Self.projectPage {
                // Shown as its address without the scheme or a closing slash: jgkarlin.github.io/maildot.
                Link(page.absoluteString.replacingOccurrences(of:"https://",with:"").trimmingCharacters(in:CharacterSet(charactersIn:"/")),destination:page).foregroundStyle(MailDotStyle.linkText)
            }
            Link(destination:Self.tipJar) { Label("Leave a Tip…",systemImage:"cup.and.saucer") }.foregroundStyle(MailDotStyle.linkText)
        }
        .font(.caption).padding(.top,8)
    }
}

/// The bar above Mail Dot Settings (owner's approval, 15 November 2026): at its left a chevron with the name of the
/// view it returns to, in place of the Done at the right, and the title in the middle. Pressing it does what Done did.
struct MailDotSettingsBar:View {
    /// The view Settings was opened from, as its own bar names it.
    let returnsTo:Text
    let back:() -> Void
    var body:some View {
        ZStack {
            Text("Mail Dot Settings").font(.headline)
            HStack(spacing:0) {
                Button(action:back) {
                    HStack(spacing:3) {
                        Image(systemName:"chevron.left").font(.body.weight(.semibold))
                        returnsTo
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.borderless).foregroundStyle(MailDotStyle.linkText).keyboardShortcut(.cancelAction)
                Spacer(minLength:0)
            }
        }
    }
}
