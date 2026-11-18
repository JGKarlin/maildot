import Foundation

/// Which of Mail's windows holds the message Mail Dot was asked to read.
///
/// Mail gives an extension no handle on its compose window, so Mail Dot finds it among Mail's windows. Until 18
/// November 2026 it took the one window titled with the message's subject and refused when there was none or more
/// than one. A reply to "Re: Congratulations!" reopened from Drafts could not be read at all (owner's report): Mail
/// can have a second window with the same title, such as the message being answered open in a window of its own, or
/// the same subject in another draft, and the owner was told to close windows. The choice below needs no closing:
/// the window bound to this message before, if it is still there; then the title; then, among several or none, the
/// windows that are messages being written (they have a Send button), and among those the one Mail has in front,
/// which is where the owner opened the Mail Dot panel.
enum ComposeWindowChoice {
    struct Candidate {
        let title: String?
        /// Mail's main window.
        let isMain: Bool
        /// The window this message was bound to earlier.
        let isBound: Bool
    }
    /// The index of the window to read, or nil when none can be told. `isCompose` says whether the window at an
    /// index is a message being written; it is asked only where the title does not settle it.
    static func choose(_ candidates: [Candidate], subject: String, isCompose: (Int) -> Bool) -> Int? {
        if let bound = candidates.firstIndex(where: \.isBound) { return bound }
        // A new message without a subject has no title of its own: the window Mail has in front.
        if subject.isEmpty { return candidates.firstIndex(where: \.isMain) }
        let titled = candidates.indices.filter { candidates[$0].title == subject }
        if titled.count == 1 { return titled[0] }
        // Several with this title, or none (Mail titles some windows otherwise): only messages being written count.
        let written = (titled.isEmpty ? Array(candidates.indices) : titled).filter(isCompose)
        if written.count == 1 { return written[0] }
        return written.first { candidates[$0].isMain }
    }
}
