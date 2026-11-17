import Foundation

/// Where the config comes from. Several files are layered: later files override earlier ones.
public struct ConfigSource {
    enum Layer {
        case resource(name: String, bundle: Bundle)
        case data(Data, label: String)
    }

    let layers: [Layer]
    /// Info.plist used for `${NAME}`.
    let infoBundle: Bundle

    /// `<name>.json` in `bundle`.
    public static func bundled(_ name: String, bundle: Bundle = .main) -> ConfigSource {
        ConfigSource(layers: [.resource(name: name, bundle: bundle)], infoBundle: .main)
    }

    /// Several bundled files, merged in order. Objects merge by key. `fields` merge by `key`,
    /// `tags` and `destinations` by `id`, `triggers` by `type`. Other arrays are replaced.
    public static func merged(_ names: [String], bundle: Bundle = .main) -> ConfigSource {
        ConfigSource(layers: names.map { .resource(name: $0, bundle: bundle) }, infoBundle: .main)
    }

    /// Raw JSON, e.g. a config fetched or generated at runtime. Layered in order.
    public static func data(_ data: [Data], infoBundle: Bundle = .main) -> ConfigSource {
        ConfigSource(
            layers: data.enumerated().map { .data($0.element, label: "data[\($0.offset)]") },
            infoBundle: infoBundle
        )
    }
}
