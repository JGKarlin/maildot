import AppKit
import AVFoundation
import CoreAudio
import BridgeCore

/// A microphone made of Mail Dot's own sound. The owner's idea (11 November 2026): the voice in a call with
/// Dot answers what it hears, so the request is spoken into the call rather than typed beside it. To do that
/// without the owner hearing it, macOS taps this app's audio output, mutes it on the speakers, and presents
/// it as the input of a device that ChatGPT can use as its microphone. No audio driver is installed; the
/// device exists only while this object is open.
@available(macOS 14.2,*)
@MainActor public final class DotVoiceLine {
    public struct Failure:Error,CustomStringConvertible { public let description:String }
    public static let deviceName="Mail Dot Voice"

    private var tap=AudioObjectID(kAudioObjectUnknown)
    private var device=AudioObjectID(kAudioObjectUnknown)
    private var player:AVAudioPlayer?
    public private(set) var isOpen=false
    public init() {}

    private static let system=AudioObjectID(kAudioObjectSystemObject)
    private static func address(_ selector:AudioObjectPropertySelector,_ scope:AudioObjectPropertyScope=kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector:selector,mScope:scope,mElement:kAudioObjectPropertyElementMain)
    }
    static func number(_ object:AudioObjectID,_ selector:AudioObjectPropertySelector,_ scope:AudioObjectPropertyScope=kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address=address(selector,scope),value:UInt32=0,size=UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object,&address,0,nil,&size,&value) == noErr ? value : nil
    }
    static func text(_ object:AudioObjectID,_ selector:AudioObjectPropertySelector) -> String? {
        var address=address(selector),value:Unmanaged<CFString>?,size=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object,&address,0,nil,&size,&value) == noErr,let value else { return nil }
        return value.takeRetainedValue() as String
    }
    @discardableResult public static func set(_ object:AudioObjectID,_ selector:AudioObjectPropertySelector,_ value:UInt32,_ scope:AudioObjectPropertyScope=kAudioObjectPropertyScopeGlobal) -> OSStatus {
        var address=address(selector,scope),value=value
        return AudioObjectSetPropertyData(object,&address,0,nil,UInt32(MemoryLayout<UInt32>.size),&value)
    }
    public static var defaultInput:AudioObjectID { number(system,kAudioHardwarePropertyDefaultInputDevice) ?? 0 }
    public static var defaultOutput:AudioObjectID { number(system,kAudioHardwarePropertyDefaultOutputDevice) ?? 0 }
    /// Whether any app is recording from or playing to the device now.
    public static func inUse(_ device:AudioObjectID) -> Bool { number(device,kAudioDevicePropertyDeviceIsRunningSomewhere) == 1 }
    public static func name(_ device:AudioObjectID) -> String { text(device,kAudioObjectPropertyName) ?? "?" }

    /// Creates the tap and the device. macOS does not allow such a device to be the default microphone, so
    /// ChatGPT uses it because the owner chose it once in ChatGPT's own settings: ChatGPT switches to its
    /// chosen microphone when that appears during a call and back to the default when it goes (read from
    /// ChatGPT's code, 11 November 2026). Mail Dot's own sound is silent on the speakers until `close()`.
    public func open() throws {
        guard !isOpen else { return }
        Self.removeStale()
        var pid=ProcessInfo.processInfo.processIdentifier
        var process=AudioObjectID(kAudioObjectUnknown),size=UInt32(MemoryLayout<AudioObjectID>.size)
        var translate=Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        guard AudioObjectGetPropertyData(Self.system,&translate,UInt32(MemoryLayout<pid_t>.size),&pid,&size,&process) == noErr,process != kAudioObjectUnknown else {
            throw Failure(description:"macOS did not identify Mail Dot as an audio source.")
        }
        let description=CATapDescription(stereoMixdownOfProcesses:[process])
        description.uuid=UUID()
        description.name=Self.deviceName
        description.muteBehavior = .muted
        description.isPrivate=false
        var status=AudioHardwareCreateProcessTap(description,&tap)
        guard status == noErr else { throw Failure(description:"macOS refused the audio tap (\(status)).") }
        guard let output=Self.text(Self.defaultOutput,kAudioDevicePropertyDeviceUID) else { close(); throw Failure(description:"No output device to keep time with.") }
        let aggregate:[String:Any]=[
            kAudioAggregateDeviceNameKey:Self.deviceName,
            // A fixed identifier, so that ChatGPT, which remembers its chosen microphone by identifier,
            // recognises the device each time it is created.
            kAudioAggregateDeviceUIDKey:Self.uid,
            kAudioAggregateDeviceMainSubDeviceKey:output,
            kAudioAggregateDeviceIsPrivateKey:false,
            kAudioAggregateDeviceIsStackedKey:false,
            kAudioAggregateDeviceTapAutoStartKey:true,
            kAudioAggregateDeviceSubDeviceListKey:[[kAudioSubDeviceUIDKey:output]],
            kAudioAggregateDeviceTapListKey:[[kAudioSubTapDriftCompensationKey:true,kAudioSubTapUIDKey:description.uuid.uuidString]]
        ]
        status=AudioHardwareCreateAggregateDevice(aggregate as CFDictionary,&device)
        guard status == noErr else { close(); throw Failure(description:"macOS refused the voice device (\(status)).") }
        isOpen=true
    }
    /// Development measure: listens on the voice device for `seconds` and returns the loudest sample seen,
    /// to show whether this app's sound is arriving on it.
    public func peak(for seconds:Double) async -> Float { await Self.measure(device,seconds:seconds) }
    /// Off the main actor: the system calls the block on its own audio thread.
    private nonisolated static func measure(_ device:AudioObjectID,seconds:Double) async -> Float {
        final class Meter:@unchecked Sendable { var peak:Float=0 }
        let meter=Meter()
        var proc:AudioDeviceIOProcID?
        let status=AudioDeviceCreateIOProcIDWithBlock(&proc,device,nil) { _,input,_,_,_ in
            let buffers=UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:input))
            for buffer in buffers {
                guard let data=buffer.mData else { continue }
                let samples=data.assumingMemoryBound(to:Float32.self)
                for index in 0..<Int(buffer.mDataByteSize)/MemoryLayout<Float32>.size { meter.peak=max(meter.peak,abs(samples[index])) }
            }
        }
        guard status == noErr,let proc else { return -1 }
        AudioDeviceStart(device,proc)
        try? await Task.sleep(for:.seconds(seconds))
        AudioDeviceStop(device,proc)
        AudioDeviceDestroyIOProcID(device,proc)
        return meter.peak
    }
    /// Removes voice devices left by a run that ended without closing: unlike the tap, the device outlives
    /// the app that made it (observed 11 November 2026, after a crash).
    public nonisolated static func removeStale() {
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var size:UInt32=0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size) == noErr else { return }
        var ids=[AudioObjectID](repeating:0,count:Int(size)/MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&ids) == noErr else { return }
        for id in ids {
            var uidAddress=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyDeviceUID,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            var value:Unmanaged<CFString>?,valueSize=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id,&uidAddress,0,nil,&valueSize,&value) == noErr,let uid=value?.takeRetainedValue() as String?,uid.hasPrefix(uidPrefix) else { continue }
            AudioHardwareDestroyAggregateDevice(id)
        }
    }
    public nonisolated static let uid="org.jgkarlin.MailBridge.voice"
    public nonisolated static let uidPrefix="org.jgkarlin.MailBridge.voice"
    public var canBeDefaultMicrophone:UInt32? { Self.number(device,kAudioDevicePropertyDeviceCanBeDefaultDevice,kAudioDevicePropertyScopeInput) }
    public var deviceID:AudioObjectID { device }
    public func close() {
        player?.stop(); player=nil
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device); device=AudioObjectID(kAudioObjectUnknown) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap=AudioObjectID(kAudioObjectUnknown) }
        isOpen=false
    }

    /// Speaks `text` into the line: synthesized to a file by the system's `say`, then played by this app,
    /// so the sound is this app's own and is the sound the tap carries. Returns when it has finished.
    public func speak(_ text:String,rate:Int=185) async throws {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent("maildot-voice-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at:file) }
        let say=Process()
        say.executableURL=URL(fileURLWithPath:"/usr/bin/say")
        say.arguments=["-r","\(rate)","-o",file.path,text]
        try say.run()
        while say.isRunning { try await Task.sleep(for:.milliseconds(50)) }
        guard say.terminationStatus == 0 else { throw Failure(description:"The Mac could not synthesize the request.") }
        let player=try AVAudioPlayer(contentsOf:file)
        self.player=player
        guard player.play() else { throw Failure(description:"The Mac could not play the request.") }
        while player.isPlaying { try await Task.sleep(for:.milliseconds(50)) }
    }
}

/// The Mac's output device, silenced and put back. Used so the owner does not hear Dot's greeting or any
/// preliminaries of a call opened from Mail, only Dot's answer.
public enum MacSpeakers {
    public struct State:Sendable {
        public let device:AudioObjectID; public var muted:UInt32?; public var volume:Float32?
        public init(device:AudioObjectID,muted:UInt32?,volume:Float32?) { self.device=device; self.muted=muted; self.volume=volume }
    }
    private static func address(_ selector:AudioObjectPropertySelector,_ scope:AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector:selector,mScope:scope,mElement:kAudioObjectPropertyElementMain)
    }
    private static func number(_ object:AudioObjectID,_ selector:AudioObjectPropertySelector,_ scope:AudioObjectPropertyScope) -> UInt32? {
        var address=address(selector,scope),value:UInt32=0,size=UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object,&address,0,nil,&size,&value) == noErr ? value : nil
    }
    private static func set(_ object:AudioObjectID,_ selector:AudioObjectPropertySelector,_ value:UInt32,_ scope:AudioObjectPropertyScope) -> OSStatus {
        var address=address(selector,scope),value=value
        return AudioObjectSetPropertyData(object,&address,0,nil,UInt32(MemoryLayout<UInt32>.size),&value)
    }
    /// Silences the default output device, returning what is needed to put it back exactly as it was.
    public static func silence() -> State {
        let output=number(AudioObjectID(kAudioObjectSystemObject),kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal) ?? 0
        var state=State(device:output,muted:number(output,kAudioDevicePropertyMute,kAudioDevicePropertyScopeOutput),volume:nil)
        if state.muted != nil,set(output,kAudioDevicePropertyMute,1,kAudioDevicePropertyScopeOutput) == noErr { return state }
        // A device without a mute switch is silenced by its volume.
        state.muted=nil
        var volumeAddress=address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,kAudioDevicePropertyScopeOutput),volume:Float32=0,size=UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(output,&volumeAddress,0,nil,&size,&volume) == noErr {
            state.volume=volume
            var zero:Float32=0
            AudioObjectSetPropertyData(output,&volumeAddress,0,nil,size,&zero)
        }
        return state
    }
    public static func restore(_ state:State) {
        if let volume=state.volume {
            var volumeAddress=address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,kAudioDevicePropertyScopeOutput),value=volume
            AudioObjectSetPropertyData(state.device,&volumeAddress,0,nil,UInt32(MemoryLayout<Float32>.size),&value)
        } else if let muted=state.muted { _ = set(state.device,kAudioDevicePropertyMute,muted,kAudioDevicePropertyScopeOutput) }
    }
    /// How the device is silenced, for the log: by its mute switch, by its volume, or not at all.
    public static func method(_ state:State) -> String { state.volume != nil ? "volume" : state.muted != nil ? "mute" : "none" }
}
