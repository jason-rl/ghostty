#!/usr/bin/env nu

# Build the macOS Ghostty app using xcodebuild with a clean environment
# to avoid Nix shell interference (NIX_LDFLAGS, NIX_CFLAGS_COMPILE, etc.).

def main [
    --scheme: string = "Ghostty"       # Xcode scheme (Ghostty, Ghostty-iOS, DockTilePlugin)
    --configuration: string = "Debug"  # Build configuration (Debug, Release, ReleaseLocal)
    --action: string = "build"         # xcodebuild action (build, test, clean, etc.)
    --arch: string = ""                # Optional architecture (arm64 or x86_64)
    --unsigned                        # Disable developer signing; packaging signs ad hoc
    --optimize-runtime                # Full link-time and whole-module optimization
] {
    let project = ($env.FILE_PWD | path join "Ghostty.xcodeproj")
    let build_dir = ($env.FILE_PWD | path join "build")
    let architecture = if $arch == "" { [] } else { [-arch $arch] }
    let signing = if $unsigned {
        ["CODE_SIGNING_ALLOWED=NO" "CODE_SIGNING_REQUIRED=NO" "CODE_SIGN_IDENTITY=" "DEVELOPMENT_TEAM="]
    } else { [] }

    let optimization = if $optimize_runtime {
        ["SWIFT_OPTIMIZATION_LEVEL=-O" "SWIFT_COMPILATION_MODE=wholemodule"
         "SWIFT_ENABLE_CROSS_MODULE_OPTIMIZATION=YES" "LLVM_LTO=YES"
         "GCC_OPTIMIZATION_LEVEL=3" "DEBUG_INFORMATION_FORMAT=dwarf-with-dsym"]
    } else { [] }

    # Skip UI tests for CLI-based invocations because it requires
    # special permissions.
    let skip_testing = if $action == "test" {
        [-skip-testing GhosttyUITests]
    } else {
        []
    }

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        xcodebuild
        -project $project
        -scheme $scheme
        -configuration $configuration
        $"SYMROOT=($build_dir)"
        ...$skip_testing
        ...$architecture
        ...$signing
        ...$optimization
        $action)
}
