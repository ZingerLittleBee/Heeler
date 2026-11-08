// The stand-in for a Foundation call the Linux toolchain does not have.
// `String(localized:)` comes from Darwin's Foundation, and swift-corelibs-foundation,
// which the agent-tools image's swiftc runs against, has no form of it. App sources
// compiled by these tool tests use it only for display text, and those tests exercise
// the scripts' shape and behavior, never the wording, so on Linux the call answers its
// own interpolated argument back unchanged. On macOS this file adds nothing, and the
// real Foundation initializer, reading the String Catalog, compiles instead.
#if !canImport(Darwin)
extension String {
    init(localized value: String) { self = value }
}
#endif
