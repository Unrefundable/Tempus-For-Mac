import CoreAudio
import Foundation
import Network
import Observation

/// Whether the Mac is on a personal hotspot or in Low Data Mode, the Mac's version of upstream's
/// mobile-data settings.
@MainActor
@Observable
public final class NetworkMonitor {
    public private(set) var isConstrained = false
    /// Called on the main actor after each change of network path.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private let monitor = NWPathMonitor()

    public init() {
        // Updates arrive on the main queue, in order (separate Tasks could land out of order).
        monitor.pathUpdateHandler = { [weak self] path in
            let isConstrained = path.isExpensive || path.isConstrained
            MainActor.assumeIsolated {
                self?.isConstrained = isConstrained
                self?.onChange?()
            }
        }
        monitor.start(queue: .main)
    }

    deinit {
        monitor.cancel()
    }
}

/// Reports when the output in use goes away, so playback pauses as it does in Music: headphones
/// pulled from the jack, or a Bluetooth or USB device disconnecting. Choosing another output by
/// hand doesn't count, because the old one is still there.
///
/// Create one for the life of the app: its Core Audio listeners only hold it weakly and are not
/// removed when it goes away.
@MainActor
public final class OutputDeviceMonitor {
    public var onOutputLost: (@MainActor () -> Void)?

    /// Core Audio's data source code for the built-in headphone jack ('hdpn').
    private static let headphonesDataSource: UInt32 = 0x6864_706E
    private var device: AudioDeviceID
    private var dataSource: UInt32?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var dataSourceListener: AudioObjectPropertyListenerBlock?

    public init() {
        device = Self.defaultOutputDevice()
        dataSource = Self.dataSource(of: device)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultDeviceChanged() }
        }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let system = AudioObjectID(kAudioObjectSystemObject)
        if AudioObjectAddPropertyListenerBlock(system, &address, .main, listener) == noErr {
            defaultDeviceListener = listener
        }
        watchDataSource()
    }

    private func defaultDeviceChanged() {
        // With no device at launch there was nothing to lose.
        let wasLost = device != AudioDeviceID(kAudioObjectUnknown) && !Self.isAlive(device)
        unwatchDataSource()
        device = Self.defaultOutputDevice()
        dataSource = Self.dataSource(of: device)
        watchDataSource()
        if wasLost {
            onOutputLost?()
        }
    }

    private func dataSourceChanged() {
        let previous = dataSource
        dataSource = Self.dataSource(of: device)
        if previous == Self.headphonesDataSource, dataSource != Self.headphonesDataSource {
            onOutputLost?()
        }
    }

    private func watchDataSource() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.dataSourceChanged() }
        }
        var address = Self.address(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        if AudioObjectAddPropertyListenerBlock(device, &address, .main, listener) == noErr {
            dataSourceListener = listener
        }
    }

    private func unwatchDataSource() {
        guard let dataSourceListener else { return }
        var address = Self.address(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        AudioObjectRemovePropertyListenerBlock(device, &address, .main, dataSourceListener)
        self.dataSourceListener = nil
    }

    // MARK: Core Audio queries

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func value<T: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        of object: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) -> T? {
        var address = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func defaultOutputDevice() -> AudioDeviceID {
        value(
            kAudioHardwarePropertyDefaultOutputDevice,
            of: AudioObjectID(kAudioObjectSystemObject),
            initial: AudioDeviceID(kAudioObjectUnknown)
        ) ?? AudioDeviceID(kAudioObjectUnknown)
    }

    private static func dataSource(of device: AudioDeviceID) -> UInt32? {
        value(kAudioDevicePropertyDataSource, of: device, scope: kAudioDevicePropertyScopeOutput, initial: UInt32(0))
    }

    private static func isAlive(_ device: AudioDeviceID) -> Bool {
        value(kAudioDevicePropertyDeviceIsAlive, of: device, initial: UInt32(0)).map { $0 != 0 } ?? false
    }
}
