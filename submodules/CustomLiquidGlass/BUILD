load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load(
    "@build_bazel_rules_apple//apple:resources.bzl",
    "apple_resource_bundle",
)
load("//build-system/bazel-utils:plist_fragment.bzl",
    "plist_fragment",
)

filegroup(
    name = "CustomLiquidGlassMetalResources",
    srcs = glob([
        "MetalResources/**/*.*",
    ]),
    visibility = ["//visibility:public"],
)

plist_fragment(
    name = "CustomLiquidGlassBundleInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>org.telegram.CustomLiquidGlass</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>CustomLiquidGlass</string>
    """
)

apple_resource_bundle(
    name = "CustomLiquidGlassBundle",
    infoplists = [
        ":CustomLiquidGlassBundleInfoPlist",
    ],
    resources = [
        ":CustomLiquidGlassMetalResources",
    ],
)

swift_library(
    name = "CustomLiquidGlass",
    module_name = "CustomLiquidGlass",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    data = [
        ":CustomLiquidGlassBundle",
    ],
    deps = [
    ],
    visibility = [
        "//visibility:public",
    ],
)
