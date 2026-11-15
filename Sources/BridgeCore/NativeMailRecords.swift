import Foundation
import CryptoKit

public struct NativeMailMessage:Codable,Equatable,Identifiable,Sendable {
    public var id:Int
    public var mailboxID:String
    public var headerID:String
    public var subject:String
    public var sender:String
    public var receivedAt:Date
    public var isRead:Bool
    public var size:Int
    public var to:[String]
    public var cc:[String]
    public var bcc:[String]
    public var attachmentCount:Int
    public init(id:Int,mailboxID:String,headerID:String,subject:String,sender:String,receivedAt:Date,isRead:Bool,size:Int,to:[String],cc:[String],bcc:[String],attachmentCount:Int) {
        self.id=id; self.mailboxID=mailboxID; self.headerID=headerID; self.subject=subject; self.sender=sender
        self.receivedAt=receivedAt; self.isRead=isRead; self.size=size; self.to=to; self.cc=cc; self.bcc=bcc; self.attachmentCount=attachmentCount
    }
    /// What identifies the message as listed. The read flag is left out (Ask Dot review, 15 November 2026): a message
    /// the owner opened between Dot's listing and Dot's reading was refused as changed.
    public var fingerprint:String {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        var identity=self; identity.isRead=false
        return SHA256.hash(data:(try? encoder.encode(identity)) ?? Data()).map { String(format:"%02x",$0) }.joined()
    }
    public func validate() throws {
        guard id >= 0,id <= Int32.max,!mailboxID.isEmpty,mailboxID.utf8.count <= 128,
              headerID.utf8.count <= 2048,subject.utf8.count <= 4096,sender.utf8.count <= 2048,
              receivedAt.timeIntervalSince1970.isFinite,size >= 0,attachmentCount >= 0,attachmentCount <= 1000,
              [to,cc,bcc].allSatisfy({ $0.count <= 100 && $0.allSatisfy { $0.utf8.count <= 2048 } }) else { throw BridgeFailure("Mail returned invalid or oversized message metadata.") }
    }
}

public struct NativeMailBody:Encodable,Sendable {
    /// The most text one read returns, in UTF-8 bytes: the one unit the limit is counted in.
    public static let textLimit=65_536
    public let message:NativeMailMessage
    public let text:String
    /// The text was longer than the limit and only its beginning is here.
    public let textTruncated:Bool
    public let contentIsUntrusted=true
    public let format="plain_text_from_mail"
    public let attachmentContentsIncluded=false
    public let serverFreshnessVerified=false
    public init(message:NativeMailMessage,text:String,expectedFingerprint:String) throws {
        try message.validate()
        guard message.fingerprint == expectedFingerprint else { throw BridgeFailure("The selected message changed. List it again before reading.") }
        // The raw size of a message says nothing about its text: mail with an attachment or rich HTML is far larger
        // than what is read, and refusing by it kept Dot from a quarter of a year's mail (Ask Dot review, 15
        // November 2026). Text over the limit is cut at the limit and marked, not refused.
        let cut=Self.cut(text)
        self.message=message; self.text=cut; self.textTruncated=cut.utf8.count < text.utf8.count
    }
    /// The beginning of the text that fits the limit, ending on a whole character.
    public static func cut(_ text:String,limit:Int=textLimit) -> String {
        guard text.utf8.count > limit else { return text }
        var end=text.utf8.index(text.utf8.startIndex,offsetBy:limit)
        while end > text.utf8.startIndex,String.Index(end,within:text) == nil { end=text.utf8.index(before:end) }
        return String(text[..<(String.Index(end,within:text) ?? text.startIndex)])
    }
}
