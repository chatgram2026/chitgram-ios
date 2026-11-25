load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# Chitgram's voice changer (Android org/fenixuz/voice): the effects, their state, and the call buffer. Pure Swift and
# Foundation, so the recorder (TelegramUI), the call audio (TelegramVoip, TelegramCallsUI) and the settings may use it.
# Built -O even in debug, like GradientBackground: it runs per sample on the audio threads.
swift_library(
    name = "ChitgramVoice",
    module_name = "ChitgramVoice",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-O",
    ],
    deps = [
        "//submodules/ChitgramCore",
    ],
    visibility = [
        "//visibility:public",
    ],
)
