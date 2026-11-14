import SwiftUI

/// Shared colours. The brand blue belongs to the icon. Controls use the system accent colour, as Apple's
/// guidance asks (owner request, 13 November 2026): it has its own light and dark shades, keeps the
/// contrast macOS designs for, and follows the accent colour the owner chose in System Settings. The fixed
/// #0077C8 used before was too dark against dark backgrounds.
enum MailDotStyle {
    /// #00B1FF, the Mail Dot blue, for the logo only.
    static let brand=Color(red:0,green:177.0/255.0,blue:1)
    static let tint=Color.accentColor
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
            }.foregroundStyle(.tertiary)
            if let page=Self.projectPage {
                // Shown as its address without the scheme or a closing slash: jgkarlin.github.io/maildot.
                Link(page.absoluteString.replacingOccurrences(of:"https://",with:"").trimmingCharacters(in:CharacterSet(charactersIn:"/")),destination:page).foregroundStyle(MailDotStyle.tint)
            }
            Link("Leave a Tip…",destination:Self.tipJar).foregroundStyle(MailDotStyle.tint)
        }
        .font(.caption).padding(.top,8)
    }
}
