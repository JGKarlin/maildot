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
    public var fingerprint:String {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        return SHA256.hash(data:(try? encoder.encode(self)) ?? Data()).map { String(format:"%02x",$0) }.joined()
    }
    public func validate() throws {
        guard id >= 0,id <= Int32.max,!mailboxID.isEmpty,mailboxID.utf8.count <= 128,
              headerID.utf8.count <= 2048,subject.utf8.count <= 4096,sender.utf8.count <= 2048,
              receivedAt.timeIntervalSince1970.isFinite,size >= 0,attachmentCount >= 0,attachmentCount <= 1000,
              [to,cc,bcc].allSatisfy({ $0.count <= 100 && $0.allSatisfy { $0.utf8.count <= 2048 } }) else { throw BridgeFailure("Mail returned invalid or oversized message metadata.") }
    }
}

public struct NativeMailBody:Encodable,Sendable {
    public let message:NativeMailMessage
    public let text:String
    public let contentIsUntrusted=true
    public let format="plain_text_from_mail"
    public let attachmentContentsIncluded=false
    public let serverFreshnessVerified=false
    public init(message:NativeMailMessage,text:String,expectedFingerprint:String) throws {
        try message.validate()
        guard message.fingerprint == expectedFingerprint else { throw BridgeFailure("The selected message changed. List it again before reading.") }
        guard message.size <= 65_536,text.utf8.count <= 65_536 else { throw BridgeFailure("This message exceeds the read-only prototype's 64 KiB limit.") }
        self.message=message; self.text=text
    }
}
