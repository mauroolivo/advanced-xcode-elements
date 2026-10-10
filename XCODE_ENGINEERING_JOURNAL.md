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
