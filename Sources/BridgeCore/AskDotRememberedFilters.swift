import Foundation

extension AskDot {
    /// Ask Dot's filters as the owner last left them. The background app keeps them between openings of the bar and
    /// across restarts of Mail and of Mail Dot (owner request, 24 November 2026), and Reset clears them.
    public struct RememberedFilters:Codable,Sendable,Equatable {
        /// The rows of the account menu chosen; empty for all accounts.
        public var accounts:[String]=[]
        public var period:Period = .anyTime
        public var customFrom:Date?
        public var customTo:Date?
        public var direction:Direction = .both
        public var person=""
        public var attachmentsOnly=false
        public init() {}

        public static let key="AskDotFilters"
        /// Whether these narrow the search at all; filters that do not are not kept.
        public var isEmpty:Bool { accounts.isEmpty && period == .anyTime && direction == .both && person.trimmingCharacters(in:.whitespaces).isEmpty && !attachmentsOnly }

        /// The filters last kept, or none. Filters that cannot be read, as after a change to their form, are none.
        public static func load(from defaults:UserDefaults = .standard) -> RememberedFilters? {
            guard let data=defaults.data(forKey:key),let value=try? JSONDecoder().decode(RememberedFilters.self,from:data),!value.isEmpty else { return nil }
            return value
        }
        /// Keeps these filters, or forgets the kept ones when these narrow nothing, as after Reset.
        public func save(to defaults:UserDefaults = .standard) {
            if isEmpty { defaults.removeObject(forKey:Self.key); return }
            if let data=try? JSONEncoder().encode(self) { defaults.set(data,forKey:Self.key) }
        }
    }
}
