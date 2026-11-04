import Foundation

/// Where libsession keeps the OpenNC denoiser model it downloads for the
/// playout stage (`Application Support/ai.origon.sdk/models`). Capture stays on
/// VoiceProcessingIO, so the model only denoises flagged remote audio.
enum NoiseModelStorage {
    static let directory = "models"

    /// The folder for `SessionClientConfig.models_dir`, or `nil` when it cannot
    /// be prepared. `nil` never fetches: calls still work, played without
    /// denoising.
    static func prepare() -> URL? {
        #if os(iOS) || os(macOS)
        return try? prepare(in: SDKDirectory.applicationSupport())
        #else
        return nil
        #endif
    }

    /// Test seam: production always supplies Application Support.
    static func prepare(in applicationSupport: URL) throws -> URL {
        try SDKDirectory.prepare(directory, in: applicationSupport)
    }
}
