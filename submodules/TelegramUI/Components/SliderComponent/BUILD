load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load(
    "@build_bazel_rules_apple//apple:resources.bzl",
    "apple_resource_bundle",
)
load("//build-system/bazel-utils:plist_fragment.bzl",
    "plist_fragment",
)

filegroup(
    name = "SliderComponentMetalResources",
    srcs = glob([
        "MetalResources/**/*.*",
    ]),
    visibility = ["//visibility:public"],
)

plist_fragment(
    name = "SliderComponentBundleInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>org.telegram.SliderComponent</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>SliderComponent</string>
    """
)

apple_resource_bundle(
    name = "SliderComponentBundle",
    infoplists = [
        ":SliderComponentBundleInfoPlist",
    ],
    resources = [
        ":SliderComponentMetalResources",
    ],
)

swift_library(
    name = "SliderComponent",
    module_name = "SliderComponent",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    data = [
        ":SliderComponentBundle",
    ],
    deps = [
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/TelegramPresentationData",
        "//submodules/LegacyComponents",
        "//submodules/ComponentFlow",
        "//submodules/CustomLiquidGlass",
    ],
    visibility = [
        "//visibility:public",
    ],
)
