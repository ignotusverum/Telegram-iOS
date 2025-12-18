load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load(
    "@build_bazel_rules_apple//apple:resources.bzl",
    "apple_resource_bundle",
)
load("//build-system/bazel-utils:plist_fragment.bzl",
    "plist_fragment",
)

filegroup(
    name = "SwitchComponentMetalResources",
    srcs = glob([
        "MetalResources/**/*.*",
    ]),
    visibility = ["//visibility:public"],
)

plist_fragment(
    name = "SwitchComponentBundleInfoPlist",
    extension = "plist",
    template =
    """
    <key>CFBundleIdentifier</key>
    <string>org.telegram.SwitchComponent</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>SwitchComponent</string>
    """
)

apple_resource_bundle(
    name = "SwitchComponentBundle",
    infoplists = [
        ":SwitchComponentBundleInfoPlist",
    ],
    resources = [
        ":SwitchComponentMetalResources",
    ],
)

swift_library(
    name = "SwitchComponent",
    module_name = "SwitchComponent",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    data = [
        ":SwitchComponentBundle",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/ContextUI:ContextUI",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/ComponentFlow:ComponentFlow",
    ],
    visibility = [
        "//visibility:public",
    ],
)
