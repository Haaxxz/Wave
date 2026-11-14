@@
-private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
-    weak var manager: DownloadManager?
+private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
+    nonisolated(unsafe) weak var manager: DownloadManager?
