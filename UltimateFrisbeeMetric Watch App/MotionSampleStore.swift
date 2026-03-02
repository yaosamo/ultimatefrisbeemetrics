import CoreMotion
import Foundation

enum MotionSampleLabel: String, CaseIterable, Identifiable, Codable {
    case forehand
    case backhand
    case hammer
    case catchSample = "catch"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forehand:
            return "Forehand"
        case .backhand:
            return "Backhand"
        case .hammer:
            return "Hammer"
        case .catchSample:
            return "Catch"
        }
    }
}

struct MotionSampleFrame: Codable, Equatable {
    let timestamp: TimeInterval
    let rotationX: Double
    let rotationY: Double
    let rotationZ: Double
    let accelerationX: Double
    let accelerationY: Double
    let accelerationZ: Double
    let gravityX: Double
    let gravityY: Double
    let gravityZ: Double
}

struct LabeledMotionSample: Codable, Identifiable, Equatable {
    let id: UUID
    let label: MotionSampleLabel
    let watchWrist: String
    let recordedAt: Date
    let duration: TimeInterval
    let frames: [MotionSampleFrame]
}

private struct MotionSampleExport: Codable {
    let exportedAt: Date
    let sampleCount: Int
    let samples: [LabeledMotionSample]
}

extension MotionSampleFrame {
    init(deviceMotion: CMDeviceMotion) {
        timestamp = deviceMotion.timestamp
        rotationX = deviceMotion.rotationRate.x
        rotationY = deviceMotion.rotationRate.y
        rotationZ = deviceMotion.rotationRate.z
        accelerationX = deviceMotion.userAcceleration.x
        accelerationY = deviceMotion.userAcceleration.y
        accelerationZ = deviceMotion.userAcceleration.z
        gravityX = deviceMotion.gravity.x
        gravityY = deviceMotion.gravity.y
        gravityZ = deviceMotion.gravity.z
    }
}

@MainActor
final class MotionSampleStore: ObservableObject {
    @Published private(set) var samples: [LabeledMotionSample] = []

    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let storageKey = "motion_training_samples"
    private let storageURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let directoryURL = baseURL.appendingPathComponent("MotionSamples", isDirectory: true)
        storageURL = directoryURL.appendingPathComponent("samples.json", isDirectory: false)

        load()
    }

    func save(sample: LabeledMotionSample) {
        samples.insert(sample, at: 0)
        persist()
    }

    func count(for label: MotionSampleLabel) -> Int {
        samples.filter { $0.label == label }.count
    }

    func latest(for label: MotionSampleLabel) -> LabeledMotionSample? {
        samples.first { $0.label == label }
    }

    var totalCount: Int {
        samples.count
    }

    func deleteLatest(for label: MotionSampleLabel) {
        guard let index = samples.firstIndex(where: { $0.label == label }) else { return }
        samples.remove(at: index)
        persist()
    }

    func deleteAll(for label: MotionSampleLabel) {
        samples.removeAll { $0.label == label }
        persist()
    }

    func exportAllSamplesJSON() -> String? {
        let export = MotionSampleExport(
            exportedAt: Date(),
            sampleCount: samples.count,
            samples: samples
        )

        let exportEncoder = JSONEncoder()
        exportEncoder.dateEncodingStrategy = .iso8601
        exportEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? exportEncoder.encode(export) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func printAllSamplesJSONToConsole() -> Bool {
        guard let json = exportAllSamplesJSON() else { return false }
        print("[SampleExport] BEGIN")
        print(json)
        print("[SampleExport] END")
        return true
    }

    private func load() {
        if let data = try? Data(contentsOf: storageURL) {
            do {
                samples = try decoder.decode([LabeledMotionSample].self, from: data)
                return
            } catch {
                samples = []
            }
        }

        migrateLegacyDefaultsIfNeeded()
    }

    private func migrateLegacyDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: storageKey) else { return }

        do {
            samples = try decoder.decode([LabeledMotionSample].self, from: data)
            persist()
            defaults.removeObject(forKey: storageKey)
        } catch {
            samples = []
        }
    }

    private func persist() {
        guard let data = try? encoder.encode(samples) else { return }
        let directoryURL = storageURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: storageURL, options: [.atomic])
    }
}
