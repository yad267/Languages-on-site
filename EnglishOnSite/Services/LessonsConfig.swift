import Foundation

/// Built-in lesson pack remote URL (not shown in Settings UI).
enum LessonsConfig {
    /// Drive direct download. Replace `REPLACE_DRIVE_FILE_ID` with the real FILE_ID after upload.
    static let lessonsPackURL =
        "https://drive.google.com/uc?export=download&id=1SpcIwSR-eTVcGQJWSudjv6hSJ612DdA6"

    /// True while placeholder is still in the URL — skip network, use bundled/cache.
    static var isPackURLConfigured: Bool {
        let u = lessonsPackURL
        return !u.isEmpty
            && !u.contains("REPLACE_DRIVE_FILE_ID")
            && URL(string: u) != nil
    }
}
