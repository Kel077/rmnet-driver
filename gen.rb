#!/usr/bin/ruby
# Generates RMNet.xcodeproj: the RMNetDriver dext (driver/ plus Core) and the RMNet host app that embeds it.
#
# Usage: /usr/bin/ruby gen.rb [TEAM_ID]
#   With a team ID both targets use Xcode automatic signing for that team; without one no signing
#   settings are written and the project is only built with signing turned off (make driver).
#
# Every path in the project is relative to the repository root (this file's directory), and object
# identifiers are derived from the project's contents, so the output is the same from any working
# directory, in any clone or worktree. Sources are collected by wildcard: a new driver/*.cpp,
# driver/*.iig or core/src/*.cpp needs no edit here.
require 'xcodeproj'

ROOT    = __dir__
APP_ID  = 'io.rmnetdriver.RMNet'
DRV_ID  = "#{APP_ID}.driver"
VERSION = '1.0'
Obj     = Xcodeproj::Project::Object

team = ARGV[0]
abort('usage: ruby gen.rb [TEAM_ID]') if ARGV.length > 1
abort("gen.rb: '#{team}' is not a team ID") if team && team !~ /\A[A-Z0-9]{10}\z/

signing = if team
            {
              'DEVELOPMENT_TEAM'   => team,
              'CODE_SIGN_STYLE'    => 'Automatic',
              'CODE_SIGN_IDENTITY' => 'Apple Development',
            }
          else
            {}
          end

def config_list(proj, settings)
  list = proj.new(Obj::XCConfigurationList)
  list.default_configuration_is_visible = '0'
  list.default_configuration_name = 'Release'
  %w[Debug Release].each do |name|
    cfg = proj.new(Obj::XCBuildConfiguration)
    cfg.name = name
    cfg.build_settings = settings.dup
    list.build_configurations << cfg
  end
  list
end

def native_target(proj, name, product_type, product_file, file_type, settings)
  t = proj.new(Obj::PBXNativeTarget)
  proj.targets << t
  t.name = name
  t.product_name = name
  t.product_type = product_type
  t.build_configuration_list = config_list(proj, settings)
  ref = proj.products_group.new_reference(product_file, :built_products)
  ref.include_in_index = '0'
  ref.set_explicit_file_type(file_type)
  t.product_reference = ref
  t.build_phases << proj.new(Obj::PBXSourcesBuildPhase)
  t.build_phases << proj.new(Obj::PBXFrameworksBuildPhase)
  t
end

# Repository-relative paths matching a pattern, in a stable order.
def sources(pattern)
  Dir.glob(pattern, base: ROOT).sort
end

proj = Xcodeproj::Project.new(File.join(ROOT, 'RMNet.xcodeproj'))

# --- driver --------------------------------------------------------------------------------------
drv = native_target(
  proj, 'RMNetDriver', 'com.apple.product-type.driver-extension',
  "#{DRV_ID}.dext", 'wrapper.driver-extension',
  {
    'SDKROOT'                      => 'driverkit',
    'DRIVERKIT_DEPLOYMENT_TARGET'  => '27.0',
    'ARCHS'                        => 'arm64',
    'PRODUCT_BUNDLE_IDENTIFIER'    => DRV_ID,
    'PRODUCT_NAME'                 => '$(PRODUCT_BUNDLE_IDENTIFIER)',
    'CURRENT_PROJECT_VERSION'      => '1',
    'MARKETING_VERSION'            => VERSION,
    'INFOPLIST_FILE'               => 'driver/Info.plist',
    'CODE_SIGN_ENTITLEMENTS'       => 'driver/Driver.entitlements',
    'ENABLE_APP_SANDBOX'           => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD'  => 'c++17',
    'GCC_ENABLE_CPP_EXCEPTIONS'    => 'NO',
    'GCC_ENABLE_CPP_RTTI'          => 'NO',
    'HEADER_SEARCH_PATHS'          => ['$(SRCROOT)/core/include'],
    'OTHER_LDFLAGS'                => '-framework DriverKit -framework USBDriverKit -framework NetworkingDriverKit -framework SerialDriverKit -framework USBSerialDriverKit',
    'SKIP_INSTALL'                 => 'YES',
  }.merge(signing),
)
dgrp = proj.main_group.new_group('driver', 'driver')
sources('driver/*.iig').each do |path|
  ref = dgrp.new_reference(File.basename(path))
  ref.last_known_file_type = 'sourcecode.iig'
  drv.source_build_phase.add_file_reference(ref)
end
sources('driver/*.cpp').each do |path|
  drv.source_build_phase.add_file_reference(dgrp.new_reference(File.basename(path)))
end
sources('driver/*.h').each { |path| dgrp.new_reference(File.basename(path)) }
dgrp.new_reference('Info.plist')
dgrp.new_reference('Driver.entitlements')

cgrp = proj.main_group.new_group('core', 'core')
csrc = cgrp.new_group('src', 'src')
sources('core/src/*.cpp').each do |path|
  drv.source_build_phase.add_file_reference(csrc.new_reference(File.basename(path)))
end

# --- host app ------------------------------------------------------------------------------------
app = native_target(
  proj, 'RMNet', 'com.apple.product-type.application',
  'RMNet.app', 'wrapper.application',
  {
    'SDKROOT'                   => 'macosx',
    'MACOSX_DEPLOYMENT_TARGET'  => '27.0',
    'ARCHS'                     => 'arm64',
    'PRODUCT_BUNDLE_IDENTIFIER' => APP_ID,
    'PRODUCT_NAME'              => '$(TARGET_NAME)',
    'CURRENT_PROJECT_VERSION'   => '1',
    'MARKETING_VERSION'         => VERSION,
    'GENERATE_INFOPLIST_FILE'   => 'YES',
    'CODE_SIGN_ENTITLEMENTS'    => 'app/Host.entitlements',
    'ENABLE_HARDENED_RUNTIME'   => 'YES',
    'SWIFT_VERSION'             => '5.0',
  }.merge(signing),
)
agrp = proj.main_group.new_group('app', 'app')
sources('app/*.swift').each do |path|
  app.source_build_phase.add_file_reference(agrp.new_reference(File.basename(path)))
end
agrp.new_reference('Host.entitlements')

embed = proj.new(Obj::PBXCopyFilesBuildPhase)
embed.name = 'Embed System Extensions'
embed.dst_subfolder_spec = '16'
embed.dst_path = '$(SYSTEM_EXTENSIONS_FOLDER_PATH)'
app.build_phases << embed
embed.add_file_reference(drv.product_reference).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
app.add_dependency(drv)

# Identifiers derived from the contents. The target dependency's identifier depends on the target's,
# so it is stable only after a second pass.
2.times { proj.predictabilize_uuids }
proj.save
puts "gen.rb: wrote RMNet.xcodeproj#{team ? " (signing team #{team})" : ' (no signing)'}"
