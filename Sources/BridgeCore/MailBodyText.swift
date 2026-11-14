import Foundation

/// The readable text of a raw RFC 822 message, enough to tell whether it names the owner (owner request, 13 November
/// 2026: a Cc message that addresses him by name goes to Dot like one sent to him). It follows the MIME
/// structure to the text parts, undoes base64 and quoted-printable, and converts the declared charset
/// (UTF-8, ISO-2022-JP, Shift_JIS and the rest Core Foundation knows). Quoted lines of earlier mail are left
/// out. Nothing here leaves the Mac.
public enum MailBodyText {
    /// At most this much raw message is read.
    static let rawLimit=1_048_576

    public static func text(rawMessage data:Data) -> String {
        part(Data(data.prefix(rawLimit)),depth:0)
    }

    /// Whether the message's own text (not quoted earlier mail) contains one of the owner's names.
    public static func mentions(_ names:[String],inRawMessage data:Data) -> Bool {
        let wanted=names.map{$0.trimmingCharacters(in:.whitespaces).lowercased()}.filter{$0.count >= 2}
        guard !wanted.isEmpty else { return false }
        let own=text(rawMessage:data).split(whereSeparator:\.isNewline)
            .filter{ !$0.trimmingCharacters(in:.whitespaces).hasPrefix(">") }
            .prefix(200).joined(separator:"\n").lowercased()
        return wanted.contains{ own.contains($0) }
    }

    private static func part(_ data:Data,depth:Int) -> String {
        guard depth < 6 else { return "" }
        let (headers,body)=split(data)
        let type=(headers["content-type"] ?? "text/plain").lowercased()
        if type.hasPrefix("multipart/"),let boundary=parameter("boundary",in:headers["content-type"] ?? "") {
            let parts=sections(body,boundary:boundary)
            // A plain text part is preferred; otherwise HTML with its tags removed.
            let texts=parts.map{ ($0,(split($0).0["content-type"] ?? "text/plain").lowercased()) }
            if let plain=texts.first(where:{ $0.1.hasPrefix("text/plain") || $0.1.hasPrefix("multipart/") }) { return part(plain.0,depth:depth+1) }
            if let html=texts.first(where:{ $0.1.hasPrefix("text/html") }) { return part(html.0,depth:depth+1) }
            return ""
        }
        guard type.hasPrefix("text/") else { return "" }
        let decoded=transferDecoded(body,encoding:(headers["content-transfer-encoding"] ?? "").lowercased())
        var text=string(decoded,charset:parameter("charset",in:headers["content-type"] ?? "") ?? "utf-8")
        if type.hasPrefix("text/html") {
            text=text.replacingOccurrences(of:"<br[^>]*>",with:"\n",options:.regularExpression)
                .replacingOccurrences(of:"</p>",with:"\n").replacingOccurrences(of:"<[^>]+>",with:" ",options:.regularExpression)
        }
        return text
    }

    /// Headers (lowercased names, unfolded) and the body after the first empty line.
    private static func split(_ data:Data) -> ([String:String],Data) {
        let crlf=Data("\r\n\r\n".utf8),lf=Data("\n\n".utf8)
        let cut=data.range(of:crlf) ?? data.range(of:lf)
        let head=cut.map{ data[data.startIndex..<$0.lowerBound] } ?? data
        let body=cut.map{ data[$0.upperBound...] } ?? Data()
        var headers:[String:String]=[:],current:String?
        let text=String(decoding:head,as:UTF8.self)
        for line in text.split(omittingEmptySubsequences:false,whereSeparator:\.isNewline) {
            if line.first == " " || line.first == "\t" { if let current { headers[current,default:""] += " "+line.trimmingCharacters(in:.whitespaces) }; continue }
            guard let colon=line.firstIndex(of:":") else { continue }
            let key=line[..<colon].lowercased().trimmingCharacters(in:.whitespaces)
            headers[key]=String(line[line.index(after:colon)...]).trimmingCharacters(in:.whitespaces)
            current=key
        }
        return (headers,Data(body))
    }

    private static func parameter(_ name:String,in value:String) -> String? {
        for piece in value.split(separator:";").dropFirst() {
            let pair=piece.split(separator:"=",maxSplits:1).map{ $0.trimmingCharacters(in:.whitespaces) }
            if pair.count == 2,pair[0].lowercased() == name { return pair[1].trimmingCharacters(in:CharacterSet(charactersIn:"\"")) }
        }
        return nil
    }

    private static func sections(_ body:Data,boundary:String) -> [Data] {
        let marker=Data(("--"+boundary).utf8)
        var parts:[Data]=[],rest=body[body.startIndex...]
        guard var start=rest.range(of:marker) else { return [] }
        while true {
            rest=rest[start.upperBound...]
            if rest.starts(with:Data("--".utf8)) { break }
            guard let next=rest.range(of:marker) else { parts.append(Data(rest)); break }
            parts.append(Data(rest[rest.startIndex..<next.lowerBound]))
            start=next
            if parts.count > 20 { break }
        }
        // Each part begins after the line break that ends the boundary line.
        return parts.map { part in
            var value=part
            while let first=value.first,first == 13 || first == 10 { value=value.dropFirst() }
            return Data(value)
        }
    }

    private static func transferDecoded(_ body:Data,encoding:String) -> Data {
        switch encoding {
        case "base64":
            let compact=String(decoding:body,as:UTF8.self).filter{ !$0.isWhitespace }
            return Data(base64Encoded:compact,options:.ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            var out=Data(),bytes=Array(body),index=0
            while index < bytes.count {
                let byte=bytes[index]
                if byte == UInt8(ascii:"="),index+1 < bytes.count {
                    if bytes[index+1] == 13 || bytes[index+1] == 10 {
                        index += bytes[index+1] == 13 && index+2 < bytes.count && bytes[index+2] == 10 ? 3 : 2; continue
                    }
                    if index+2 < bytes.count,let value=UInt8(String(decoding:bytes[(index+1)...(index+2)],as:UTF8.self),radix:16) {
                        out.append(value); index += 3; continue
                    }
                }
                out.append(byte); index += 1
            }
            return out
        default: return body
        }
    }

    private static func string(_ data:Data,charset:String) -> String {
        let encoding=CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        if encoding != kCFStringEncodingInvalidId,
           let value=String(data:data,encoding:String.Encoding(rawValue:CFStringConvertEncodingToNSStringEncoding(encoding))) { return value }
        return String(decoding:data,as:UTF8.self)
    }
}
