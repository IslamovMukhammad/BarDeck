//  Reads temperature and fan speed from the Apple SMC.
//  Reading needs no root (writing would; this never writes).

import Foundation
import IOKit

struct SensorReading {
    var temperature: Double?   // °C
    var fanRPM: Int?
    var fanMinRPM: Int?
    var fanMaxRPM: Int?

    /// How hard the fan works: 0 not spinning, 1 at maximum.
    ///
    /// On an M1 MacBook Pro the fan stops completely when cool (0 rpm) and starts at
    /// ~1200 rpm under load, so it is measured from zero, not from the minimum.
    var fanLoad: Double? {
        guard let rpm = fanRPM, let max = fanMaxRPM, max > 0 else { return nil }
        return Swift.max(0, Swift.min(1, Double(rpm) / Double(max)))
    }
}

/// A minimal SMC client. Keys are four characters ("F0Ac", "Tp01", …).
final class SMCReader {

    private var connection: io_connect_t = 0

    /// The temperature keys that actually answer on this Mac. Most keys in the list don't
    /// exist on every model; after the first read only the working ones are asked, which saves
    /// dozens of IOKit calls per sample.
    private var workingTemperatureKeys: [String]?

    /// On M1 core temperatures live in "Tp_z" keys; "TCMz" is the chip's hottest spot.
    /// Some may be missing depending on the model: whatever exists is read.
    private static let cpuTemperatureKeys = [
        "TCMz",
        "Tp1z", "Tp2z", "Tp3z", "Tp4z", "Tp5z",
        "Tp6z", "Tp7z", "Tp8z", "Tp9z",
        "Te3z", "Tc8z",
    ]

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
            return nil
        }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func read() -> SensorReading {
        SensorReading(
            temperature: cpuTemperature(),
            fanRPM: value(forKey: "F0Ac").map { Int($0.rounded()) },
            fanMinRPM: value(forKey: "F0Mn").map { Int($0.rounded()) },
            fanMaxRPM: value(forKey: "F0Mx").map { Int($0.rounded()) }
        )
    }

    // MARK: - Harorat

    /// The hottest core: the most meaningful number for the user.
    private func cpuTemperature() -> Double? {
        let candidates = workingTemperatureKeys ?? Self.cpuTemperatureKeys

        var working: [String] = []
        var readings: [Double] = []

        for key in candidates {
            // A dead sensor returns 0 or nonsense.
            guard let value = value(forKey: key), value > 5, value < 120 else { continue }
            working.append(key)
            readings.append(value)
        }

        if workingTemperatureKeys == nil, !working.isEmpty {
            workingTemperatureKeys = working
        }

        return readings.max()
    }

    // MARK: - Talking to the SMC

    private struct KeyData {
        var key: UInt32 = 0
        var vers: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0)
        var pLimitData: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var keyInfo: KeyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        /// The SMC expects 32 contiguous bytes. A Swift array won't do: it is stored as a pointer.
        var bytes: SMCBytes = (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    private typealias SMCBytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        /// The C struct is padded to 12 bytes. Swift doesn't pad it, and without the padding
        /// the whole request goes out at the wrong size.
        var pad0: UInt8 = 0
        var pad1: UInt8 = 0
        var pad2: UInt8 = 0
    }

    private static let kSMCHandleYPCEvent: UInt32 = 2
    private static let kSMCReadKey: UInt8 = 5
    private static let kSMCGetKeyInfo: UInt8 = 9

    /// Reads a key and turns it into a number.
    private func value(forKey key: String) -> Double? {
        guard connection != 0, let keyCode = Self.encode(key) else { return nil }

        // Step 1: ask for the key's type and size.
        var input = KeyData()
        input.key = keyCode
        input.data8 = Self.kSMCGetKeyInfo

        guard let info = call(input) else { return nil }

        // Step 2: read the value.
        var readInput = KeyData()
        readInput.key = keyCode
        readInput.keyInfo.dataSize = info.keyInfo.dataSize
        readInput.keyInfo.dataType = info.keyInfo.dataType
        readInput.data8 = Self.kSMCReadKey

        guard let output = call(readInput) else { return nil }

        var buffer = output.bytes
        let bytes = withUnsafeBytes(of: &buffer) { Array($0.prefix(32)) }

        return Self.decode(
            bytes: bytes,
            size: Int(info.keyInfo.dataSize),
            type: info.keyInfo.dataType
        )
    }

    private func call(_ input: KeyData) -> KeyData? {
        var inputStruct = input
        var outputStruct = KeyData()
        var outputSize = MemoryLayout<KeyData>.stride

        let result = withUnsafePointer(to: &inputStruct) { inputPointer in
            withUnsafeMutablePointer(to: &outputStruct) { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    Self.kSMCHandleYPCEvent,
                    inputPointer,
                    MemoryLayout<KeyData>.stride,
                    outputPointer,
                    &outputSize
                )
            }
        }

        guard result == kIOReturnSuccess, outputStruct.result == 0 else { return nil }
        return outputStruct
    }

    // MARK: - Encoding and decoding

    /// "F0Ac" → 0x46304163
    private static func encode(_ key: String) -> UInt32? {
        let scalars = Array(key.utf8)
        guard scalars.count == 4 else { return nil }
        return scalars.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func decode(bytes: [UInt8], size: Int, type: UInt32) -> Double? {
        guard size > 0, bytes.count >= size else { return nil }

        switch type {
        case encode("flt ") ?? 0:
            // Floating-point values are little-endian on Apple silicon.
            guard size >= 4 else { return nil }
            let raw = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: raw))

        case encode("ui8 ") ?? 0:
            return Double(bytes[0])

        case encode("ui16") ?? 0:
            guard size >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))

        case encode("ui32") ?? 0:
            guard size >= 4 else { return nil }
            let raw = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            return Double(raw)

        case encode("sp78") ?? 0:
            // The older Intel format: 1 sign + 7 integer + 8 fraction bits.
            guard size >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256.0

        default:
            return nil
        }
    }
}
