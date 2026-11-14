import Foundation
import Darwin
import Security

/// launchd supervises this process; exec preserves its PID and signal ownership.
@main struct RuntimeMain {
    /// The runtime folder and the Keychain item; a test of setup names others (see ConnectionSetup).
    static let directory=option("--runtime-dir").map{ URL(fileURLWithPath:$0,isDirectory:true) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mail Dot/Runtime")
    static let keyService=option("--key-service") ?? "org.jgkarlin.MailBridge.tunnel-key"
    static let statusFile=directory.appendingPathComponent("runtime-status.json")
    static func option(_ name:String) -> String? {
        guard let index=CommandLine.arguments.firstIndex(of:name),CommandLine.arguments.indices.contains(index+1) else { return nil }
        let value=CommandLine.arguments[index+1]
        return value.hasPrefix("-") ? nil : value
    }

    static func main() {
        // Setup asks whether this helper can read the key Mail Dot saved; the answer names no part of the key.
        if CommandLine.arguments.contains("--check-key") { print("KEY_READABLE: \(keychainKey() == nil ? 0 : 1)"); exit(0) }
        guard let data=try? Data(contentsOf:directory.appendingPathComponent("configuration.json")),
              let config=try? JSONDecoder().decode(Configuration.self,from:data),
              config.profilePath.hasPrefix("/"),
              let clientPath=tunnelClient(named:config.clientPath) else { stop("configuration") }
        // The key: a file, for installations set up by hand, or the Keychain item Mail Dot's setup saved.
        let keyArgument:String
        if let credential=config.credentialPath {
            guard credential.hasPrefix("/") else { stop("configuration") }
            keyArgument="file:"+credential
        } else {
            guard let key=keychainKey() else { stop("key") }
            setenv("MAILDOT_TUNNEL_KEY",key,1)
            keyArgument="env:MAILDOT_TUNNEL_KEY"
        }
        // The files that name the key, and the key file if there is one, must be the owner's alone.
        for path in [directory.appendingPathComponent("configuration.json").path,config.profilePath]+(config.credentialPath.map{[$0]} ?? []) {
            var info=stat()
            guard lstat(path,&info) == 0,(info.st_mode & S_IFMT) == S_IFREG,info.st_uid == getuid(),(info.st_mode & 0o077) == 0 else { stop("permissions") }
        }
        // The private profile names the Mail Dot agent by absolute path. If the app was moved, that path no
        // longer leads to a program, and the tunnel could not start its agent. Only that certain case stops here.
        if let data=try? Data(contentsOf:URL(fileURLWithPath:config.profilePath)),
           let profile=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
           let commands=(profile["mcp"] as? [String:Any])?["commands"] as? [[String:Any]],
           let command=commands.first?["command"] as? String {
            // The program is the first word of the command; a test of setup adds arguments after it.
            let trimmed=command.trimmingCharacters(in:.whitespaces)
            let agent=trimmed.hasPrefix("\"") ? String(trimmed.dropFirst().prefix{ $0 != "\"" }) : String(trimmed.prefix{ $0 != " " })
            if agent.hasPrefix("/"),!FileManager.default.isExecutableFile(atPath:agent) { stop("moved") }
        }
        unlink(statusFile.path)
        let args=[clientPath,"run","--profile-file",config.profilePath,"--control-plane.api-key",keyArgument,"--mcp.stdio-failure-policy","restart","--health.listen-addr","127.0.0.1:0","--health.url-file",directory.appendingPathComponent("health.url").path]
        let pointers=args.map { strdup($0) }
        var terminated=pointers+[nil]
        terminated.withUnsafeMutableBufferPointer { _ = execv(clientPath,$0.baseAddress!) }
        pointers.forEach { free($0) }
        stop("launch")
    }

    /// Records why the connection cannot start, for the Connection page to show, then waits before exiting.
    /// launchd restarts this helper whenever it exits; the wait turns a relaunch every minute into one
    /// every three, short enough that a corrected configuration takes effect promptly. Configuration contents and credential material are never written or logged.
    static func stop(_ problem:String) -> Never {
        let body="{\"problem\":\"\(problem)\",\"at\":\(Date().timeIntervalSince1970)}"
        if let fd=Optional(open(statusFile.path,O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC|O_NOFOLLOW,0o600)),fd >= 0 {
            _ = body.withCString { write(fd,$0,strlen($0)) }
            close(fd)
        }
        fputs("Mail Dot background connection could not start (\(problem)). Check its local runtime configuration.\n",stderr)
        sleep(120)
        exit(78)
    }
    /// The tunnel client that travels inside Mail Dot (beside this helper) when it is there; otherwise the one the
    /// configuration names, as builds without the embedded client have it.
    static func tunnelClient(named configured:String?) -> String? {
        if let here=Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("tunnel-client").path,
           FileManager.default.isExecutableFile(atPath:here) { return here }
        guard let configured,configured.hasPrefix("/"),FileManager.default.isExecutableFile(atPath:configured) else { return nil }
        return configured
    }
    /// The key Mail Dot's setup saved in the login keychain, whose access list names this helper.
    static func keychainKey() -> String? {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:keyService,
                                kSecAttrAccount as String:"OpenAI tunnel key",kSecReturnData as String:true]
        var result:CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess,let data=result as? Data,
              let key=String(data:data,encoding:.utf8),!key.isEmpty else { return nil }
        return key
    }
    struct Configuration:Decodable { let clientPath:String?; let profilePath:String; let credentialPath:String? }
}
