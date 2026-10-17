from pathlib import Path
root = Path(__file__).resolve().parents[1]
project = root / 'MyWorkbench.xcodeproj'
project.mkdir(exist_ok=True)
sources = sorted((root / 'Sources').rglob('*.swift'))
lines = ['// !$*UTF8*$!', '{', 'archiveVersion = 1;', 'classes = {};', 'objectVersion = 56;', 'objects = {']
file_ids = []
build_ids = []
for i, path in enumerate(sources):
    file_id = f'{100+i:024X}'; build_id = f'{200+i:024X}'
    file_ids.append(file_id); build_ids.append(build_id)
    relative = path.relative_to(root).as_posix()
    lines.append(f'{file_id} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{relative}"; sourceTree = "<group>";}};')
    lines.append(f'{build_id} = {{isa = PBXBuildFile; fileRef = {file_id};}};')
def obj(id, text): lines.append(f'{id:024X} = {{{text}}};')
def ref(id): return f'{id:024X}'
obj(1, f'isa = PBXProject; attributes = {{LastUpgradeCheck = 2620;}}; buildConfigurationList = {ref(11)}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, "zh-Hans", Base); mainGroup = {ref(2)}; productRefGroup = {ref(3)}; projectDirPath = ""; projectRoot = ""; targets = ({ref(5)}); packageReferences = ({ref(20)});')
obj(2, f'isa = PBXGroup; children = ({", ".join(file_ids)}, {ref(9)}, {ref(3)}); sourceTree = "<group>";')
obj(3, f'isa = PBXGroup; children = ({ref(4)}); name = Products; sourceTree = "<group>";')
obj(4, 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = MyWorkbench.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj(9, 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";')
obj(10, f'isa = PBXBuildFile; fileRef = {ref(9)};')
obj(5, f'isa = PBXNativeTarget; buildConfigurationList = {ref(12)}; buildPhases = ({ref(6)}, {ref(7)}, {ref(8)}); buildRules = (); dependencies = (); name = MyWorkbench; productName = MyWorkbench; productReference = {ref(4)}; productType = "com.apple.product-type.application"; packageProductDependencies = ({ref(21)});')
obj(6, f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(build_ids)}); runOnlyForDeploymentPostprocessing = 0;')
obj(7, f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({ref(22)}); runOnlyForDeploymentPostprocessing = 0;')
obj(20, 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/migueldeicaza/SwiftTerm.git"; requirement = {kind = exactVersion; version = 1.10.0;};')
obj(21, f'isa = XCSwiftPackageProductDependency; package = {ref(20)}; productName = SwiftTerm;')
obj(22, f'isa = PBXBuildFile; productRef = {ref(21)};')
obj(8, f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({ref(10)}); runOnlyForDeploymentPostprocessing = 0;')
obj(11, f'isa = XCConfigurationList; buildConfigurations = ({ref(13)}, {ref(14)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj(12, f'isa = XCConfigurationList; buildConfigurations = ({ref(15)}, {ref(16)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
for id, name in [(13,'Debug'),(14,'Release')]:
    obj(id, f'isa = XCBuildConfiguration; buildSettings = {{CLANG_ENABLE_MODULES = YES; MACOSX_DEPLOYMENT_TARGET = 14.0; SDKROOT = macosx; SWIFT_VERSION = 5.0;}}; name = {name};')
settings = 'CODE_SIGN_STYLE = Manual; CODE_SIGN_IDENTITY = "-"; COMBINE_HIDPI_IMAGES = YES; ENABLE_APP_SANDBOX = NO; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_CFBundleDisplayName = "My Workbench"; INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.productivity"; PRODUCT_BUNDLE_IDENTIFIER = com.ocean.myworkbench; PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_VERSION = 5.0; MARKETING_VERSION = 0.5.0; CURRENT_PROJECT_VERSION = 6; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";'
settings += ' ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;'
obj(15, f'isa = XCBuildConfiguration; buildSettings = {{{settings} ONLY_ACTIVE_ARCH = YES; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;}}; name = Debug;')
obj(16, f'isa = XCBuildConfiguration; buildSettings = {{{settings} ONLY_ACTIVE_ARCH = NO; SWIFT_COMPILATION_MODE = wholemodule;}}; name = Release;')
lines += ['};',f'rootObject = {ref(1)};','}']
(project / 'project.pbxproj').write_text('\n'.join(lines) + '\n')
scheme = project / 'xcshareddata/xcschemes'; scheme.mkdir(parents=True, exist_ok=True)
target = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref(5)}" BuildableName="MyWorkbench.app" BlueprintName="MyWorkbench" ReferencedContainer="container:MyWorkbench.xcodeproj"/>'
(scheme/'MyWorkbench.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2620" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{target}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{target}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{target}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Xcode project created')
