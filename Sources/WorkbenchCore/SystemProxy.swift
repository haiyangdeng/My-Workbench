import CFNetwork
import Foundation

/// Proxy variables for CLIs, taken from the macOS network settings. An app opened from Finder does not inherit the
/// HTTPS_PROXY a user sets in their terminal, so a CLI behind a local proxy (for example 127.0.0.1:7890) can take
/// minutes per request while it retries direct connections. Measured with Codex on 2026-10-24: 123 s without, 23 s with.
public enum SystemProxy {
    static let variableNames = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]

    /// The current system proxy settings (the dictionary CFNetwork returns).
    public static func current() -> [String: Any] {
        (CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]) ?? [:]
    }

    /// Variables to add for a CLI. Empty when the app's own environment already names a proxy (the user's choice wins)
    /// or when no HTTP, HTTPS or SOCKS proxy is enabled. Local addresses always bypass the proxy.
    public static func environment(settings: [String: Any], inherited: [String: String]) -> [String: String] {
        if variableNames.contains(where: { !(inherited[$0] ?? "").isEmpty }) { return [:] }
        func server(_ prefix: String) -> String? {
            guard (settings[prefix + "Enable"] as? NSNumber)?.boolValue == true, let host = settings[prefix + "Proxy"] as? String, !host.isEmpty else { return nil }
            let port = (settings[prefix + "Port"] as? NSNumber)?.intValue
            return port.map { "\(host):\($0)" } ?? host
        }
        var result: [String: String] = [:]
        if let https = server("HTTPS") { result["HTTPS_PROXY"] = "http://" + https; result["https_proxy"] = "http://" + https }
        if let http = server("HTTP") { result["HTTP_PROXY"] = "http://" + http; result["http_proxy"] = "http://" + http }
        if let socks = server("SOCKS") { result["ALL_PROXY"] = "socks5h://" + socks; result["all_proxy"] = "socks5h://" + socks }
        guard !result.isEmpty else { return [:] }
        var bypass = ["localhost", "127.0.0.1", "::1"]
        for entry in (settings["ExceptionsList"] as? [String]) ?? [] where !bypass.contains(entry) { bypass.append(entry) }
        result["NO_PROXY"] = bypass.joined(separator: ","); result["no_proxy"] = result["NO_PROXY"]
        return result
    }

    /// A short description of the enabled system proxies for the CLI form, or nil when none is enabled.
    public static func summary(settings: [String: Any] = current()) -> String? {
        let found = environment(settings: settings, inherited: [:])
        let parts = [("HTTPS", found["HTTPS_PROXY"]), ("HTTP", found["HTTP_PROXY"]), ("SOCKS", found["ALL_PROXY"])].compactMap { name, value in
            value.map { "\(name) \($0.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "socks5h://", with: ""))" }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
