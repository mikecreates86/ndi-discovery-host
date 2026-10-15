import Foundation

/// Facts about the NDI Discovery Server binary.
/// These were NOT verified against the real binary when the app was written
/// (no NDI SDK was available). Run tools/inspect-ndi-server.sh on the Mac and
/// update `port` and `arguments` here if the results differ.
public enum NDIServer {
    public static let defaultPath = "/Library/NDI SDK for Apple/bin/Application.Mac.NDI.DirectoryService"
    public static let port: UInt16 = 5959      // UNVERIFIED (NDI's documented default)
    public static let arguments: [String] = [] // UNVERIFIED: none assumed
}
