import Foundation

public enum Paths {
    public static var home: String { NSHomeDirectory() }

    /// The per-user temporary folder, e.g. /var/folders/jb/…/T/
    public static var userTemp: String { confString(_CS_DARWIN_USER_TEMP_DIR) }

    /// The per-user cache folder, e.g. /var/folders/jb/…/C/
    public static var userCache: String { confString(_CS_DARWIN_USER_CACHE_DIR) }

    /// The parent of T and C, holding X where code-signing clones live.
    public static var userFolders: String {
        (userTemp as NSString).deletingLastPathComponent
    }

    public static var appSupport: String {
        home + "/Library/Application Support/Headroom"
    }

    /// Expands `~/`, `$TMP/`, `$CACHE/` and `$FOLDERS/` prefixes.
    public static func expand(_ path: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        if path.hasPrefix("$TMP/") { return join(userTemp, String(path.dropFirst(5))) }
        if path.hasPrefix("$CACHE/") { return join(userCache, String(path.dropFirst(7))) }
        if path.hasPrefix("$FOLDERS/") { return join(userFolders, String(path.dropFirst(9))) }
        return path
    }

    /// Shortens a path for display: home becomes ~, the per-user /var/folders prefix is elided.
    public static func display(_ path: String) -> String {
        let folders = userFolders
        if path.hasPrefix(folders) {
            return "/var/folders/…" + path.dropFirst(folders.count)
        }
        let h = home
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }

    static func join(_ base: String, _ rest: String) -> String {
        base.hasSuffix("/") ? base + rest : base + "/" + rest
    }

    private static func confString(_ name: Int32) -> String {
        let length = confstr(name, nil, 0)
        guard length > 0 else { return NSTemporaryDirectory() }
        var buffer = [CChar](repeating: 0, count: length)
        confstr(name, &buffer, length)
        return String(cString: buffer)
    }
}

/// Last line of defence before anything is deleted.
public enum PathSafety {
    /// Folders that must never be deleted themselves, whatever a catalogue entry says.
    static var protected: Set<String> {
        let h = Paths.home
        return [
            "/", "/System", "/Users", "/Applications", "/Library", "/private", "/var", "/var/folders",
            "/System/Volumes/Data", "/Volumes", h, h + "/Library", h + "/Library/Caches",
            h + "/Library/Application Support", h + "/Library/Containers", h + "/Documents",
            h + "/Desktop", h + "/Downloads", h + "/Pictures", h + "/Movies", h + "/Music",
            h + "/.ssh", h + "/.claude", h + "/Library/Developer",
            (Paths.userTemp as NSString).standardizingPath, (Paths.userCache as NSString).standardizingPath,
            (Paths.userFolders as NSString).standardizingPath,
        ]
    }

    public static func isDeletable(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let standard = (path as NSString).standardizingPath
        if standard.contains("/../") || standard.hasSuffix("/..") { return false }
        if protected.contains(standard) { return false }
        // Require some depth: nothing directly under the root.
        let components = standard.split(separator: "/")
        return components.count >= 3
    }
}
