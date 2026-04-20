#!/usr/bin/env ruby
require "fileutils"
require "pathname"
require "xcodeproj"

ROOT = Pathname(__dir__).join("..").expand_path
PROJECT_NAME = "WyomingAppleSpeechServer"
TEST_TARGET_NAME = "#{PROJECT_NAME}Tests"
PROJECT_PATH = ROOT.join("#{PROJECT_NAME}.xcodeproj")
SOURCE_ROOT = ROOT.join("Sources", PROJECT_NAME)
TEST_ROOT = ROOT.join("Tests", TEST_TARGET_NAME)
INFO_PLIST_PATH = SOURCE_ROOT.join("Info.plist")

FileUtils.rm_rf(PROJECT_PATH)

project = Xcodeproj::Project.new(PROJECT_PATH.to_s)
project.root_object.attributes["LastSwiftUpdateCheck"] = "2640"
project.root_object.attributes["LastUpgradeCheck"] = "2640"

app_target = project.new_target(:application, PROJECT_NAME, :osx, "26.0")
app_target.product_name = PROJECT_NAME
test_target = project.new_target(:unit_test_bundle, TEST_TARGET_NAME, :osx, "26.0")
test_target.product_name = TEST_TARGET_NAME
test_target.add_dependency(app_target)

project.build_configurations.each do |config|
  config.build_settings["MACOSX_DEPLOYMENT_TARGET"] = "26.0"
end

app_target.build_configurations.each do |config|
  settings = config.build_settings
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "io.homeassistant.#{PROJECT_NAME}"
  settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  settings["INFOPLIST_FILE"] = INFO_PLIST_PATH.relative_path_from(ROOT).to_s
  settings["GENERATE_INFOPLIST_FILE"] = "NO"
  settings["SWIFT_VERSION"] = "6.0"
  settings["ENABLE_APP_SANDBOX"] = "NO"
  settings["LD_RUNPATH_SEARCH_PATHS"] = ["$(inherited)", "@executable_path/../Frameworks"]
  settings["ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS"] = "YES"
  settings["CODE_SIGN_STYLE"] = "Automatic"
  settings["MARKETING_VERSION"] = "0.1.0"
  settings["CURRENT_PROJECT_VERSION"] = "1"
end

test_target.build_configurations.each do |config|
  settings = config.build_settings
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "io.homeassistant.#{TEST_TARGET_NAME}"
  settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  settings["SWIFT_VERSION"] = "6.0"
  settings["GENERATE_INFOPLIST_FILE"] = "YES"
  settings["CODE_SIGN_STYLE"] = "Automatic"
  settings["MACOSX_DEPLOYMENT_TARGET"] = "26.0"
  settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
  settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/#{PROJECT_NAME}.app/Contents/MacOS/#{PROJECT_NAME}"
  settings["ENABLE_TESTING_SEARCH_PATHS"] = "YES"
  settings["LD_RUNPATH_SEARCH_PATHS"] = ["$(inherited)", "@loader_path/../Frameworks", "@executable_path/../Frameworks"]
end

main_group = project.main_group
source_folder_ref = project.new(Xcodeproj::Project::Object::PBXFileSystemSynchronizedRootGroup)
source_folder_ref.source_tree = "SOURCE_ROOT"
source_folder_ref.path = SOURCE_ROOT.relative_path_from(ROOT).to_s
source_folder_ref.uses_tabs = "1"
source_folder_ref.indent_width = "2"
source_folder_ref.tab_width = "2"
source_folder_ref.wraps_lines = "1"
source_folder_ref.explicit_file_types = {}
source_folder_ref.explicit_folders = []

target_exceptions = project.new(Xcodeproj::Project::Object::PBXFileSystemSynchronizedBuildFileExceptionSet)
target_exceptions.target = app_target
target_exceptions.membership_exceptions = ["Info.plist"]
target_exceptions.public_headers = []
target_exceptions.private_headers = []
target_exceptions.additional_compiler_flags_by_relative_path = {}
target_exceptions.attributes_by_relative_path = {}
target_exceptions.platform_filters_by_relative_path = {}

source_folder_ref.exceptions << target_exceptions

main_group.children << source_folder_ref
app_target.file_system_synchronized_groups << source_folder_ref

test_folder_ref = project.new(Xcodeproj::Project::Object::PBXFileSystemSynchronizedRootGroup)
test_folder_ref.source_tree = "SOURCE_ROOT"
test_folder_ref.path = TEST_ROOT.relative_path_from(ROOT).to_s
test_folder_ref.uses_tabs = "1"
test_folder_ref.indent_width = "2"
test_folder_ref.tab_width = "2"
test_folder_ref.wraps_lines = "1"
test_folder_ref.explicit_file_types = {}
test_folder_ref.explicit_folders = []

main_group.children << test_folder_ref
test_target.file_system_synchronized_groups << test_folder_ref

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app_target)
scheme.add_build_target(test_target)
scheme.set_launch_target(app_target)
scheme.add_test_target(test_target)
scheme.save_as(PROJECT_PATH.to_s, PROJECT_NAME, true)

project.save
