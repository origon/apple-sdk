import Foundation

extension OrigonClient {
    /// The licence and notice texts for third-party material the SDK ships,
    /// sorted by file name (today OpenNC's `opennc-LICENSE.txt` and
    /// `opennc-NOTICE.txt`, for the denoiser model libsession downloads).
    /// Show them in your app's acknowledgements. Each is a UTF-8 text file in
    /// the SDK's resource bundle.
    public static var thirdPartyNotices: [URL] {
        guard let folder = Bundle.module.url(
            forResource: "THIRD_PARTY_NOTICES",
            withExtension: nil
        ) else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
