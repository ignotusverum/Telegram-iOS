load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

objc_library(
    name = "DisplayObjC",
    module_name = "DisplayObjC",
    srcs = glob([
        "Source/**/*.m",
    ]),
    hdrs = glob([
        "Source/**/*.h",
    ]),
    copts = [
        "-Werror",
    ],
    sdk_frameworks = [
        "UIKit",
        "QuartzCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "Display",
    module_name = "Display",
    srcs = glob([
        "Source/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
    	"//submodules/ObjCRuntimeUtils:ObjCRuntimeUtils",
    	"//submodules/UIKitRuntimeUtils:UIKitRuntimeUtils",
        "//submodules/AppBundle:AppBundle",
    	"//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Markdown:Markdown",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        ":DisplayObjC",
    ],
    visibility = [
        "//visibility:public",
    ],
)
