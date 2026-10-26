import AppKit
import ApplicationServices
import EventKit
import Security

/// Permission and signing report for this exact binary, written as plain text.
enum Diagnostics {
    static func write(to url: URL) {
        var lines: [String] = []
        lines.append("bundle: \(Bundle.main.bundlePath)")
        lines.append("accessibility: \(AXIsProcessTrusted())")
        lines.append("screenCapture: \(CGPreflightScreenCaptureAccess())")
        lines.append("calendar: \(EKEventStore.authorizationStatus(for: .event).rawValue)")
        lines.append(FocusMonitor().diagnostics())
        lines.append("nowPlaying (system, via perl): \(MediaRemoteBridge.probe())")
        var code: SecCode?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code {
            lines.append("selfValidity: \(SecCodeCheckValidity(code, [], nil))")
            var requirement: SecRequirement?
            var staticCode: SecStaticCode?
            SecCodeCopyStaticCode(code, [], &staticCode)
            if let staticCode, SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement {
                var text: CFString?
                SecRequirementCopyString(requirement, [], &text)
                lines.append("designated: \(text.map { $0 as String } ?? "?")")
                lines.append("validityAgainstDesignated: \(SecCodeCheckValidity(code, [], requirement))")
            }
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
