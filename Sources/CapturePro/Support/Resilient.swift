import Foundation

/// Decodes saved JSON on top of current defaults, so files written by older versions keep
/// loading when new settings appear (missing keys take their default values).
enum Resilient {
    static func decode<T: Codable>(_ type: T.Type, from data: Data, defaults: T, dropping: [[String]] = []) -> T? {
        guard var saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaultData = try? JSONEncoder().encode(defaults),
              let base = (try? JSONSerialization.jsonObject(with: defaultData)) as? [String: Any] else { return nil }
        for path in dropping { remove(path, from: &saved) }
        let merged = merge(base, saved)
        guard let data = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if let b = base[k] as? [String: Any], let o = v as? [String: Any] {
                out[k] = merge(b, o)
            } else {
                out[k] = v
            }
        }
        return out
    }

    private static func remove(_ path: [String], from dict: inout [String: Any]) {
        guard let first = path.first else { return }
        if path.count == 1 { dict[first] = nil; return }
        guard var child = dict[first] as? [String: Any] else { return }
        remove(Array(path.dropFirst()), from: &child)
        dict[first] = child
    }
}
