# Xcode Engineering Journal

## Stage 0 - Laboratory and project anatomy

### Question
Which target(s) and phases does this project actually build, and where do effective settings come from in this toolchain/project combination?

### Hypothesis
- The scheme builds one app target with no target dependencies.
- Build work should include compile, link, Info.plist processing, and code signing for simulator artifacts.
- Effective settings should resolve from target/project defaults plus toolchain/platform defaults, visible via `xcodebuild -showBuildSettings`.

### Setting/command
```bash
xcode-select -p
xcodebuild -version
xcrun swift --version
xcodebuild -list -project advanced-xcode-elements.xcodeproj
xcodebuild -showdestinations -project advanced-xcode-elements.xcodeproj -scheme advanced-xcode-elements
xcodebuild -showBuildSettings -project advanced-xcode-elements.xcodeproj -scheme advanced-xcode-elements -configuration Debug -destination 'generic/platform=iOS Simulator'
xcodebuild -project advanced-xcode-elements.xcodeproj -scheme advanced-xcode-elements -configuration Debug -destination 'generic/platform=iOS Simulator' clean build
```

### Observed evidence
- Toolchain:
  - Xcode `27.1` (`27A9269`)
  - Swift `6.4` (`swiftlang-6.4.0.34.1`)
  - Selected developer dir: `/Users/mauro/Downloads/Xcode.app/Contents/Developer`
- Project structure from `xcodebuild -list`:
  - Targets: `advanced-xcode-elements`
  - Configurations: `Debug`, `Release`
  - Schemes: `advanced-xcode-elements`
- Destination inspection:
  - Compatible generic destinations include `Any iOS Device` and `Any iOS Simulator Device`
  - Deployment target is iOS `27.0`; older iOS 26.x devices/simulators are reported incompatible
- Effective settings excerpt (Debug + generic simulator):
  - `PRODUCT_BUNDLE_IDENTIFIER = com.mauroolivo.advanced-xcode-elements`
  - `SWIFT_VERSION = 5.0`
  - `IPHONEOS_DEPLOYMENT_TARGET = 27.0`
  - `SDKROOT = .../iPhoneSimulator27.1.sdk`
  - DerivedData-backed `OBJROOT`, `SYMROOT`, `TARGET_BUILD_DIR`
- Build graph/log evidence:
  - `note: Target dependency graph (1 target)`
  - `Target 'advanced-xcode-elements' ... (no dependencies)`
  - Build steps include `SwiftCompile`, `Ld`, `ProcessInfoPlistFile`, `CopySwiftLibs`, `CodeSign`

### Deliberate failure and repair
- Failure command:
```bash
xcodebuild -project advanced-xcode-elements.xcodeproj -scheme DOES_NOT_EXIST -destination 'generic/platform=iOS Simulator' build
```
- Failure signature:
  - `error: ... does not contain a scheme named "DOES_NOT_EXIST"`
- Repair:
  - Re-ran build using valid scheme `advanced-xcode-elements`
  - Build succeeded

### Diagnosis
- Scheme selection is a first-order build graph input; invalid scheme blocks graph construction entirely.
- Effective values come from layered resolution (project/target/config/platform/toolchain defaults), not from one declaration point.
- The project currently has a single-target graph, making Stage 0 a clean baseline for later dependency experiments.

### Trade-off
- Single-target baseline improves observability and reduces confounders.
- It does not reflect multi-target production complexity yet (added in later stages).

### Toolchain caveats
- Although Swift compiler version is 6.4, `SWIFT_VERSION` resolves to `5.0` for this target, so language mode and compiler version are distinct.
- Deployment target at iOS 27.0 excludes many connected 26.x devices/simulators in destination selection.
- Preview behavior was inferred from build artifacts/log signatures (`__preview.dylib`) and was not interactively measured inside Xcode UI in this CLI run.

## Stage 1 - Build setting resolution

### Question
When project and target declare conflicting values for the same build setting, which value becomes effective for the built target, and how does command-line override precedence compare?

### Hypothesis
- Target-level value should override project-level value for the same configuration.
- A command-line override passed to `xcodebuild` should override both project and target declarations.

### Setting/command
Configured a controlled conflict in `advanced-xcode-elements.xcodeproj/project.pbxproj`:
- Project Debug: `SWIFT_VERSION = 6.0`
- Target Debug: `SWIFT_VERSION = 5.0`

Commands used:
```bash
xcodebuild -showBuildSettings -project advanced-xcode-elements.xcodeproj -scheme advanced-xcode-elements -configuration Debug -destination 'generic/platform=iOS Simulator' | grep -E '^\s*SWIFT_VERSION\s*='
xcodebuild -showBuildSettings -project advanced-xcode-elements.xcodeproj -scheme advanced-xcode-elements -configuration Debug -destination 'generic/platform=iOS Simulator' SWIFT_VERSION=6.0 | grep -E '^\s*SWIFT_VERSION\s*='
```

### Observed evidence
- Declared conflict in `project.pbxproj` was present:
  - Project Debug: `SWIFT_VERSION = 6.0`
  - Target Debug: `SWIFT_VERSION = 5.0`
- Effective value for normal Debug build settings:
  - `SWIFT_VERSION = 5.0` (target-level value wins)
- Effective value with command-line override:
  - `SWIFT_VERSION = 6.0` (CLI override wins over project+target)

### Deliberate failure and repair
- Failure command:
```bash
xcodebuild -project advanced-xcode-elements.xcodeproj -scheme advanced-xcode-elements -configuration Debug -destination 'generic/platform=iOS Simulator' SWIFT_VERSION=9.9 build
```
- Failure signature:
  - `error: SWIFT_VERSION '9.9' is unsupported, supported versions are: 4.0, 4.2, 5.0, 6.0.`
- Repair:
  - Removed invalid CLI override and rebuilt with normal settings
  - Build succeeded

### Diagnosis
- For same-key conflicts in one configuration scope, target-level declaration overrides project-level declaration for target builds.
- Command-line overrides are higher precedence and can mask project/target declarations in local/CI runs.

### Trade-off
- Project-level defaults reduce duplication across targets.
- Target overrides enable intentional divergence but can create hidden behavior if not documented.
- CLI overrides are useful for experimentation/CI matrix work, but can reduce reproducibility if not explicitly logged.

### Toolchain caveats
- `SWIFT_VERSION` accepts language mode values; it does not imply compiler binary version.
- In this environment, compiler is Swift 6.4 while target language mode can still be 5.0 or 6.0.

#### Restore note
After collecting evidence, the temporary project Debug `SWIFT_VERSION = 6.0` conflict was removed so the project returns to baseline (`SWIFT_VERSION = 5.0` effective in Debug).

## Stage 2 - Layered xcconfig

### Question
Can selected in-project build settings be moved into layered `.xcconfig` files without changing effective values?

### Hypothesis
- Moving equivalent values to layered `.xcconfig` files (Base -> Debug/Release) and attaching them as project base configurations should preserve effective values.
- `xcodebuild -showBuildSettings` snapshots before/after should match for the moved keys.

### Setting/command
Created:
- `Config/Base.xcconfig`
- `Config/Debug.xcconfig`
- `Config/Release.xcconfig`

Attached as project base configurations in `advanced-xcode-elements.xcodeproj/project.pbxproj`:
- Project Debug -> `Config/Debug.xcconfig`
- Project Release -> `Config/Release.xcconfig`

Moved these project-level declarations out of `.pbxproj` into xcconfigs:
- `GCC_C_LANGUAGE_STANDARD`
- `IPHONEOS_DEPLOYMENT_TARGET`
- `SDKROOT`
- `ONLY_ACTIVE_ARCH` (Debug)
- `SWIFT_ACTIVE_COMPILATION_CONDITIONS` (Debug)
- `SWIFT_OPTIMIZATION_LEVEL` (Debug)
- `SWIFT_COMPILATION_MODE` (Release)

Before/after comparison commands:
```bash
xcodebuild -showBuildSettings -project advanced-xcode-elements.xcodeproj -scheme advanced-xcode-elements -configuration Debug -destination 'generic/platform=iOS Simulator'
xcodebuild -showBuildSettings -project advanced-xcode-elements.xcodeproj -scheme advanced-xcode-elements -configuration Release -destination 'generic/platform=iOS Simulator'
```

### Observed evidence
- Effective-value snapshot for moved keys matched before and after migration.
- Debug effective values remained:
  - `GCC_C_LANGUAGE_STANDARD = gnu17`
  - `IPHONEOS_DEPLOYMENT_TARGET = 27.0`
  - `SDKROOT = .../iPhoneSimulator27.1.sdk`
  - `ONLY_ACTIVE_ARCH = NO` (for generic simulator destination)
  - `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`
  - `SWIFT_OPTIMIZATION_LEVEL = -Onone`
- Release effective values remained:
  - `GCC_C_LANGUAGE_STANDARD = gnu17`
  - `IPHONEOS_DEPLOYMENT_TARGET = 27.0`
  - `SDKROOT = .../iPhoneSimulator27.1.sdk`
  - `SWIFT_COMPILATION_MODE = wholemodule`
- Post-migration Debug build succeeded.

### Deliberate failure and repair
- Failure command (xcconfig path override):
```bash
xcodebuild -project advanced-xcode-elements.xcodeproj -scheme advanced-xcode-elements -configuration Debug -destination 'generic/platform=iOS Simulator' -xcconfig /tmp/DOES_NOT_EXIST_STAGE2.xcconfig build
```
- Failure signature:
  - `error: Unable to open file '/tmp/DOES_NOT_EXIST_STAGE2.xcconfig' referenced by xcodebuild -xcconfig flag or OverridingXCConfigPath user default.`
- Repair:
  - Rebuilt without invalid `-xcconfig` override
  - Build succeeded

### Diagnosis
- Layered `.xcconfig` files can preserve behavior when declarations are transferred exactly and attached at the intended scope.
- Include path resolution is significant; using explicit project-relative include (`#include "Config/Base.xcconfig"`) avoids ambiguity.

### Trade-off
- Pros: cleaner separation of shared/default/config-specific concerns; easier reuse and review.
- Cons: misconfigured include paths or wrong attachment scope can silently alter effective platform behavior.

### Toolchain caveats
- Effective values remain destination-dependent (example: `ONLY_ACTIVE_ARCH = NO` for generic simulator destination even with Debug declaration `YES`).
- `-xcconfig` CLI override is high leverage; it can replace configuration sources and should be logged in CI.

## Stage 3 - Schemes and build configurations

### Question
How do scheme action mappings (Run/Test/Profile/Analyze/Archive) select configurations, and how does a shared Staging scheme differ from the default scheme behavior?

### Hypothesis
- A new `Staging` build configuration can be introduced without changing target graph shape.
- A shared Staging scheme can map actions to different configurations (for example Run=Staging, Test=Debug, Profile=Release).
- Scheme-name mismatch should fail before build execution.

### Setting/command
Added `Staging` build configuration at project and target levels in `advanced-xcode-elements.xcodeproj/project.pbxproj`.

Added config file:
- `Config/Staging.xcconfig`

Created shared schemes:
- `advanced-xcode-elements.xcodeproj/xcshareddata/xcschemes/advanced-xcode-elements.xcscheme`
- `advanced-xcode-elements.xcodeproj/xcshareddata/xcschemes/advanced-xcode-elements-Staging.xcscheme`

Key commands:
```bash
xcodebuild -list -project advanced-xcode-elements.xcodeproj
xcodebuild -showBuildSettings -project advanced-xcode-elements.xcodeproj -scheme advanced-xcode-elements-Staging -configuration Staging -destination 'generic/platform=iOS Simulator'
xcodebuild -project advanced-xcode-elements.xcodeproj -scheme advanced-xcode-elements-Staging -configuration Staging -destination 'generic/platform=iOS Simulator' build
```

### Observed evidence
- `xcodebuild -list` now shows build configurations: `Debug`, `Release`, `Staging`.
- `xcodebuild -list` shows schemes: `advanced-xcode-elements`, `advanced-xcode-elements-Staging`.
- Effective settings for Staging include:
  - `SWIFT_COMPILATION_MODE = wholemodule`
  - `SWIFT_ACTIVE_COMPILATION_CONDITIONS = STAGING`
- Shared Staging scheme action mapping (from `.xcscheme`):
  - TestAction -> `Debug`
  - LaunchAction -> `Staging`
  - ProfileAction -> `Release`
  - AnalyzeAction -> `Staging`
  - ArchiveAction -> `Staging`

### Deliberate failure and repair
- Failure command:
```bash
xcodebuild -project advanced-xcode-elements.xcodeproj -scheme advanced-xcode-elements-Staging-NOTFOUND -destination 'generic/platform=iOS Simulator' build
```
- Failure signature:
  - `error: ... does not contain a scheme named "advanced-xcode-elements-Staging-NOTFOUND"`
- Repair:
  - Rebuilt with valid scheme `advanced-xcode-elements-Staging` and configuration `Staging`
  - Build succeeded

### Diagnosis
- Scheme identity is an explicit input to action/configuration selection; invalid scheme names fail early.
- Action-specific config mapping is data in the `.xcscheme` file, independent from target build settings.
- Shared schemes make these mappings deterministic for CLI/CI and between developers.

### Trade-off
- Shared schemes improve reproducibility and reduce "works on my machine" behavior.
- Additional schemes increase maintenance surface and must be reviewed when adding/removing configurations.

### Toolchain caveats
- `xcodebuild -configuration <X>` can drive build configuration directly, while scheme action mapping matters for IDE actions and default CLI behavior without explicit `-configuration`.
- No test target exists yet, so TestAction mapping is inspectable but not yet behaviorally exercised by `xcodebuild test`.

## Stage 4 - Build variants and Info.plist

### Question
Can build-time settings like bundle ID suffix and display name variant be configured per build configuration, properly resolved via xcconfig variable expansion, and verified in the generated Info.plist?

### Hypothesis
- Bundle ID suffixes and app name variants can be declared via `PRODUCT_BUNDLE_IDENTIFIER` and `INFOPLIST_KEY_CFBundleDisplayName` in layered xcconfig files.
- A shared `BUNDLE_ID_PREFIX` in Base.xcconfig plus configuration-specific suffixes should allow three distinct variants (Debug, Release, Staging) to coexist.
- `xcodebuild -showBuildSettings` will show effective resolved values.
- `plutil -p Info.plist` will show CFBundleIdentifier and CFBundleDisplayName with correct variant values.
- xcconfig include path errors should corrupt the build configuration in a detectable way.

### Setting/command
Created variant strategy in layered xcconfig files:

**Config/Base.xcconfig:**
```
BUNDLE_ID_PREFIX = com.mauroolivo.advanced-xcode-elements
```

**Config/Debug.xcconfig:**
```
PRODUCT_BUNDLE_IDENTIFIER = $(BUNDLE_ID_PREFIX).debug
INFOPLIST_KEY_CFBundleDisplayName = $(PRODUCT_NAME) Debug
```

**Config/Release.xcconfig:**
```
PRODUCT_BUNDLE_IDENTIFIER = $(BUNDLE_ID_PREFIX)
INFOPLIST_KEY_CFBundleDisplayName = $(PRODUCT_NAME)
```

**Config/Staging.xcconfig:**
```
PRODUCT_BUNDLE_IDENTIFIER = $(BUNDLE_ID_PREFIX).staging
INFOPLIST_KEY_CFBundleDisplayName = $(PRODUCT_NAME) Staging
```

Verification commands:
```bash
# Effective settings for each configuration
xcodebuild -showBuildSettings -project advanced-xcode-elements.xcodeproj -scheme advanced-xcode-elements -configuration Debug -destination 'generic/platform=iOS Simulator' | grep -E '(PRODUCT_BUNDLE_IDENTIFIER|INFOPLIST_KEY_CFBundleDisplayName)'

# Build and inspect Info.plist
xcodebuild -project advanced-xcode-elements.xcodeproj -scheme advanced-xcode-elements -configuration Debug -destination 'generic/platform=iOS Simulator' clean build
plutil -p ~/Library/Developer/Xcode/DerivedData/advanced-xcode-elements-cjrfaydyyltnupfjxstveorqztmm/Build/Products/Debug-iphonesimulator/advanced-xcode-elements.app/Info.plist | grep -E '(CFBundleIdentifier|CFBundleDisplayName)'
```

### Observed evidence

**Effective settings via xcodebuild -showBuildSettings:**

Debug:
- `PRODUCT_BUNDLE_IDENTIFIER = com.mauroolivo.advanced-xcode-elements.debug`
- `INFOPLIST_KEY_CFBundleDisplayName = advanced-xcode-elements Debug`

Release:
- `PRODUCT_BUNDLE_IDENTIFIER = com.mauroolivo.advanced-xcode-elements`
- `INFOPLIST_KEY_CFBundleDisplayName = advanced-xcode-elements`

Staging:
- `PRODUCT_BUNDLE_IDENTIFIER = com.mauroolivo.advanced-xcode-elements.staging`
- `INFOPLIST_KEY_CFBundleDisplayName = advanced-xcode-elements Staging`

**Generated Info.plist inspection after build:**

Debug Info.plist:
```
"CFBundleIdentifier" => "com.mauroolivo.advanced-xcode-elements.debug"
"CFBundleDisplayName" => "advanced-xcode-elements Debug"
```

Release Info.plist:
```
"CFBundleIdentifier" => "com.mauroolivo.advanced-xcode-elements"
"CFBundleDisplayName" => "advanced-xcode-elements"
```

Staging Info.plist:
```
"CFBundleIdentifier" => "com.mauroolivo.advanced-xcode-elements.staging"
"CFBundleDisplayName" => "advanced-xcode-elements Staging"
```

### Deliberate failure and repair

**Failure command:**
Broke xcconfig include in `Config/Staging.xcconfig`:
```
#include "Config/DOES_NOT_EXIST.xcconfig"
```

**Failure signature:**
```
xcodebuild: error: Could not configure request to show build settings: Unable to find a destination matching the provided destination specifier: { generic:1, platform:iOS Simulator }
Destinations incompatible with the "advanced-xcode-elements-Staging" scheme:
    { platform:iOS Simulator, ... error:...platform doesn't match advanced-xcode-elements.app's supported platforms. }
```

The broken include corrupted the build configuration; the target became incompatible with iOS Simulator and only macOS destinations remained available.

**Repair:**
```
#include "Config/Base.xcconfig"
```

Verified restoration:
```
PRODUCT_BUNDLE_IDENTIFIER = com.mauroolivo.advanced-xcode-elements.staging
BUILD SUCCEEDED
```

### Diagnosis

1. **Variant resolution via xcconfig expansion works correctly:** Each configuration uses `PRODUCT_BUNDLE_IDENTIFIER = $(BUNDLE_ID_PREFIX).suffix` pattern. Xcode resolves variables at build time and embeds into Info.plist during `ProcessInfoPlistFile` phase.

2. **Three distinct bundle IDs coexist safely:** Debug (.debug), Release (base), and Staging (.staging) have unique identifiers, allowing parallel installation on the same device for testing.

3. **Display name customization via INFOPLIST_KEY_* is transparent:** Build-time substitution requires no plist file editing. `GENERATE_INFOPLIST_FILE = YES` processes these keys.

4. **Xcconfig include errors are high-impact failures:** Missing `#include` silently prevents variable definitions. Configuration becomes corrupted, destinations become incompatible. Not an immediate build error, but a severe functional failure.

5. **Layered xcconfig precedence is clear:** Base defines prefix, each config includes Base and appends suffixes. Fully traceable via `xcodebuild -showBuildSettings`.

### Trade-off

**Pros:**
- Multiple variants on same device (QA/A/B testing essential).
- Xcconfig variables reduce duplication.
- Build-time customization, no code changes required.
- Inspectable via `xcodebuild -showBuildSettings` and `plutil`.

**Cons:**
- Xcconfig include errors fail silently; severe configuration corruption without immediate build failure.
- Variable expansion not validated; typos expand to empty/incorrect values.
- `INFOPLIST_KEY_*` naming convention not obvious; requires documentation.

### Toolchain caveats

- `GENERATE_INFOPLIST_FILE = YES` required for `INFOPLIST_KEY_*` to be embedded.
- Bundle ID uniqueness not enforced; duplicates cause installation/signing conflicts.
- `plutil -p` shows final plist only; intermediate variable expansions not visible in build logs without verbose flags.
- Xcode 27.1/Swift 6.4 support `$(inherited)` concatenation in display name keys.

### Takeaway

Build variants are achieved through layered xcconfig files and build-time variable substitution. Effective bundle ID and display name are resolved during `ProcessInfoPlistFile` phase and embedded into the generated plist. Validation requires both `xcodebuild -showBuildSettings` (declared/resolved values) and `plutil` inspection (final embedded values). Xcconfig include errors are a critical failure mode; preventive path validation would reduce risk.

## Stage 5 - Swift compiler configuration

### Question
How do `SWIFT_ACTIVE_COMPILATION_CONDITIONS` and `SWIFT_OPTIMIZATION_LEVEL` resolve into actual `swiftc` flags, and what failure signature appears when optimization is misconfigured?

### Hypothesis
- Debug baseline should compile with `-Onone` and `-DDEBUG`.
- Adding a custom condition should add another `-D<FLAG>` in the Swift invocation.
- Forcing `SWIFT_OPTIMIZATION_LEVEL=-O` in Debug should swap `-Onone` for `-O`.
- An invalid optimization level should fail during Swift driver planning/argument validation.

### Setting/command
No persistent project-setting changes were made. Experiments were run with `xcodebuild` CLI overrides to keep the repository state stable.

```bash
# Toolchain check
xcodebuild -version
xcrun swift --version

# Baseline effective compiler settings (Debug)
xcodebuild -showBuildSettings \
  -project advanced-xcode-elements.xcodeproj \
  -scheme advanced-xcode-elements \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  | grep -E '^\s*(SWIFT_VERSION|SWIFT_ACTIVE_COMPILATION_CONDITIONS|SWIFT_OPTIMIZATION_LEVEL|SWIFT_COMPILATION_MODE)\s*='

# Alternative config snapshot (Staging)
xcodebuild -showBuildSettings \
  -project advanced-xcode-elements.xcodeproj \
  -scheme advanced-xcode-elements \
  -configuration Staging \
  -destination 'generic/platform=iOS Simulator' \
  | grep -E '^\s*(SWIFT_VERSION|SWIFT_ACTIVE_COMPILATION_CONDITIONS|SWIFT_OPTIMIZATION_LEVEL|SWIFT_COMPILATION_MODE)\s*='

# Inspect concrete swift invocation (baseline)
xcodebuild -project advanced-xcode-elements.xcodeproj \
  -scheme advanced-xcode-elements \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build -verbose \
  | grep -E 'builtin-SwiftDriver --|swiftc -module-name|\\-Onone|\\-DDEBUG'

# Toggle condition via CLI override and inspect effective value
xcodebuild -showBuildSettings \
  -project advanced-xcode-elements.xcodeproj \
  -scheme advanced-xcode-elements \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG STAGE5_CONDITION' \
  | grep -E '^\s*SWIFT_ACTIVE_COMPILATION_CONDITIONS\s*='

# Toggle optimization via CLI override and inspect swift invocation
xcodebuild -project advanced-xcode-elements.xcodeproj \
  -scheme advanced-xcode-elements \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build -verbose SWIFT_OPTIMIZATION_LEVEL=-O \
  | grep -E 'builtin-SwiftDriver --|swiftc -module-name|-Onone\\b|-O\\b'
```

### Observed evidence
- Toolchain remains:
  - Xcode `27.1` (`27A9269`)
  - Swift `6.4` (`swiftlang-6.4.0.34.1`)
- Debug effective compiler settings:
  - `SWIFT_VERSION = 5.0`
  - `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG DEBUG`
  - `SWIFT_OPTIMIZATION_LEVEL = -Onone`
- Staging comparison:
  - `SWIFT_ACTIVE_COMPILATION_CONDITIONS = STAGING STAGING`
  - `SWIFT_COMPILATION_MODE = wholemodule`
- Baseline debug compiler invocation (`build -verbose`) includes:
  - `swiftc ... -Onone ... -DDEBUG -DDEBUG ... -swift-version 5 ...`
- Condition toggle via override (`SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG STAGE5_CONDITION'`) resolves and appears in invocation as:
  - `-DDEBUG -DSTAGE5_CONDITION`
- Optimization toggle via override (`SWIFT_OPTIMIZATION_LEVEL=-O`) resolves and appears in invocation as:
  - `swiftc ... -O ...` (replacing baseline `-Onone`)

### Deliberate failure and repair
- Failure command:
```bash
xcodebuild -project advanced-xcode-elements.xcodeproj \
  -scheme advanced-xcode-elements \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build SWIFT_OPTIMIZATION_LEVEL=-O123
```
- Failure signature:
  - `error: Driver threw unknown argument: '-O123' without emitting errors.`
  - Build fails in `SwiftDriver ... swift.compiler` phase.
- Repair:
  - Removed invalid override and rebuilt with default Debug settings.
  - Build returned to `** BUILD SUCCEEDED **`.

### Diagnosis
- Declared build settings become concrete compiler behavior only after expansion into the actual `swiftc` invocation.
- In this project, `SWIFT_VERSION=5.0` controls language mode (`-swift-version 5`) while the compiler binary remains Swift 6.4.
- `SWIFT_ACTIVE_COMPILATION_CONDITIONS` maps directly to `-D` flags and is easy to audit in verbose logs.
- `SWIFT_OPTIMIZATION_LEVEL` maps directly to `swiftc` optimization flags and can hard-fail if invalid.

### Trade-off
- CLI overrides are excellent for controlled experiments and CI matrices with zero persistent project churn.
- They are also a reproducibility risk if command-line overrides are not logged, because local/CI behavior can silently diverge from checked-in settings.

### Toolchain caveats
- In this Xcode 27.1 toolchain, adding `OTHER_SWIFT_FLAGS=-driver-print-jobs` caused `Swift driver build planning failed`; `build -verbose` was a safer way to inspect real invocations.
- Duplicate condition tokens (`DEBUG DEBUG`, `STAGING STAGING`) can appear from combined setting layers; this is usually harmless but signals layering noise worth cleaning later.
- Simulator generic destination emits both arm64 and x86_64 compiler invocations in this environment; inspect both if architecture-specific behavior is suspected.

### Takeaway
Compiler-configuration work should be validated at the invocation level, not only at Build Settings UI level: `SWIFT_*` keys are hypotheses, and the verbose `swiftc` command is the evidence.

## Stage 6 - Swift concurrency configuration

### Question
How do Swift language mode (`SWIFT_VERSION`) and concurrency strictness settings interact with default actor isolation in this project, and when does an isolation issue move from warning to error?

### Hypothesis
- With current target defaults (`SWIFT_VERSION = 5.0`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`), a deliberate actor-isolation violation should appear as a warning.
- Keeping strict concurrency checks in Swift 5 mode should still allow build completion (warning-level diagnostics).
- Switching to Swift 6 mode with strict concurrency should escalate the same violation to a build-stopping error.

### Setting/command
Added a minimal probe in `advanced-xcode-elements/ContentView.swift`, gated behind a compile condition so baseline builds are unaffected:

```swift
#if STAGE6_CONCURRENCY_LAB
final class Stage6MutableBox {
    var value = 0
}

func stage6IsolationProbe() {
    let box = Stage6MutableBox()
    Task.detached {
        box.value += 1
    }
}
#endif
```

Commands used:

```bash
# Baseline concurrency settings
xcodebuild -showBuildSettings \
  -project advanced-xcode-elements.xcodeproj \
  -scheme advanced-xcode-elements \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  | grep -E '^\s*(SWIFT_VERSION|SWIFT_STRICT_CONCURRENCY|SWIFT_APPROACHABLE_CONCURRENCY|SWIFT_DEFAULT_ACTOR_ISOLATION|SWIFT_ACTIVE_COMPILATION_CONDITIONS)\s*='

# Swift 5 + minimal strictness with probe enabled
xcodebuild -project advanced-xcode-elements.xcodeproj \
  -scheme advanced-xcode-elements \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG STAGE6_CONCURRENCY_LAB' \
  SWIFT_STRICT_CONCURRENCY=minimal

# Swift 5 + complete strictness with probe enabled
xcodebuild -project advanced-xcode-elements.xcodeproj \
  -scheme advanced-xcode-elements \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG STAGE6_CONCURRENCY_LAB' \
  SWIFT_STRICT_CONCURRENCY=complete

# Swift 6 + complete strictness with probe enabled (expected failure)
xcodebuild -project advanced-xcode-elements.xcodeproj \
  -scheme advanced-xcode-elements \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG STAGE6_CONCURRENCY_LAB' \
  SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_VERSION=6.0

# Inspect concrete compiler invocation for one probe run
xcodebuild -project advanced-xcode-elements.xcodeproj \
  -scheme advanced-xcode-elements \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build -verbose \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG STAGE6_CONCURRENCY_LAB' \
  SWIFT_STRICT_CONCURRENCY=minimal \
  | grep -E 'swiftc -module-name|default-isolation|swift-version|\-DDEBUG|\-DSTAGE6_CONCURRENCY_LAB'
```

### Observed evidence
- Baseline effective concurrency settings (Debug):
  - `SWIFT_VERSION = 5.0`
  - `SWIFT_APPROACHABLE_CONCURRENCY = YES`
  - `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
  - `SWIFT_STRICT_CONCURRENCY` not explicitly declared in baseline output.
- Swift invocation evidence includes:
  - `-default-isolation=MainActor`
  - `-swift-version 5`
  - `-DDEBUG -DSTAGE6_CONCURRENCY_LAB` (when probe flag is enabled)
- Probe diagnostics under Swift 5 (`minimal` and `complete` both tested):
  - Warning at `ContentView.swift:13:13`
  - `warning: main actor-isolated property 'value' can not be mutated from a nonisolated context`
  - Build continues.
- Probe diagnostics under Swift 6 + `complete`:
  - Same site (`ContentView.swift:13:13`) escalates to:
  - `error: main actor-isolated property 'value' can not be mutated from a nonisolated context`
  - Build fails.

### Deliberate failure and repair
- Failure setup:
  - Enabled probe + `SWIFT_STRICT_CONCURRENCY=complete` + `SWIFT_VERSION=6.0`.
- Failure signature:
  - `error: main actor-isolated property 'value' can not be mutated from a nonisolated context`
  - Build fails in `SwiftCompile ... ContentView.swift`.
- Repair:
  - Removed temporary CLI overrides and rebuilt with default project settings.
  - Default Debug build returned to `** BUILD SUCCEEDED **`.

### Diagnosis
- In this toolchain/project, language mode boundary (`SWIFT_VERSION=5.0` vs `6.0`) is the key diagnostic severity switch for this isolation violation.
- `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` makes unannotated declarations main-actor isolated, which is why mutating from `Task.detached` is diagnosed.
- Strictness toggles alone (minimal vs complete) did not change severity for this specific probe while remaining in Swift 5 mode.

### Trade-off
- Keeping Swift 5 mode with approachable concurrency can ease migration by preserving warning-level diagnostics.
- Swift 6 mode surfaces stronger correctness guarantees sooner but can turn existing warnings into blocking errors, requiring planned refactors.

### Toolchain caveats
- Concurrency diagnostics are highly toolchain- and mode-dependent; always log `xcodebuild -version`, `swift --version`, and effective build settings with each experiment.
- Some strict-concurrency keys may be implicit/defaulted and not visible unless explicitly set.
- Generic simulator destination still builds for multiple simulator architectures in this environment; duplicate warning lines can appear.

### Takeaway
Concurrency behavior is determined by the combination of actor isolation defaults, strictness policy, and Swift language mode; in this project, the same code path is warning-level in Swift 5 and error-level in Swift 6.
