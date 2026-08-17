#!/usr/bin/env ruby
# frozen_string_literal: true

require 'xcodeproj'

project = Xcodeproj::Project.open(File.expand_path('../MarkEdit.xcodeproj', __dir__))
main = project.targets.find { |target| target.name == 'MarkEditMac' } or abort 'MarkEditMac target missing'

def add_local_dependency(project, owner, target)
  return if owner.dependencies.any? { |dependency| dependency.target == target }
  proxy = project.new(Xcodeproj::Project::Object::PBXContainerItemProxy)
  proxy.container_portal = project.root_object.uuid
  proxy.proxy_type = Xcodeproj::Constants::PROXY_TYPES[:native_target]
  proxy.remote_global_id_string = target.uuid
  proxy.remote_info = target.name
  dependency = project.new(Xcodeproj::Project::Object::PBXTargetDependency)
  dependency.name = target.name
  dependency.target = target
  dependency.target_proxy = proxy
  owner.dependencies << dependency
end

def configure(target, bundle_id, plist, entitlements, product_name)
  target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    # Xcode requires every embedded executable's identifier to be prefixed by
    # its containing app. The main target adds `.dev` in Debug builds, so its
    # embedded login item and Quick Action must mirror that configuration.
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = if configuration.name == 'Debug'
                                              bundle_id.sub(
                                                'art.apuch.ksamint.markedit.',
                                                'art.apuch.ksamint.markedit.dev.'
                                              )
                                            else
                                              bundle_id
                                            end
    settings['PRODUCT_NAME'] = product_name
    settings['INFOPLIST_FILE'] = plist
    settings['CODE_SIGN_ENTITLEMENTS'] = entitlements
    settings['GENERATE_INFOPLIST_FILE'] = 'NO'
    settings['MACOSX_DEPLOYMENT_TARGET'] = '15.0'
    settings['SDKROOT'] = 'macosx'
    settings['SWIFT_VERSION'] = '6.0'
    settings['SKIP_INSTALL'] = 'YES'
    settings['MARKETING_VERSION'] = '2.5.5'
    settings['CURRENT_PROJECT_VERSION'] = '18'
    settings['CODE_SIGN_STYLE'] = 'Automatic'
  end
end

def require_codesign_on_copy(phase, product_reference)
  build_file = phase.files.find { |file| file.file_ref == product_reference }
  return unless build_file

  build_file.settings = {
    'ATTRIBUTES' => %w[CodeSignOnCopy RemoveHeadersOnCopy]
  }
end

helper = project.targets.find { |target| target.name == 'ConversationCaptureHelper' }
unless helper
  helper = project.new_target(:application, 'ConversationCaptureHelper', :osx, '15.0')
  group = project.main_group.new_group('ConversationCaptureHelper', 'ConversationCaptureHelper')
  source = group.new_file('main.swift')
  group.new_file('Info.plist')
  group.new_file('Info.entitlements')
  helper.source_build_phase.add_file_reference(source)
  add_local_dependency(project, main, helper)
  phase = main.new_copy_files_build_phase('Embed Login Items')
  phase.dst_subfolder_spec = '1'
  phase.dst_path = 'Contents/Library/LoginItems'
  phase.add_file_reference(helper.product_reference, true)
end
helper_embed_phase = main.copy_files_build_phases.find { |phase| phase.name == 'Embed Login Items' }
require_codesign_on_copy(helper_embed_phase, helper.product_reference) if helper_embed_phase
helper_group = project.main_group.find_subpath('ConversationCaptureHelper', false)
if helper_group
  helper_strings = helper_group.files.find { |file| file.path == 'Localizable.xcstrings' }
  helper_strings ||= helper_group.new_file('Localizable.xcstrings')
  helper.resources_build_phase.add_file_reference(helper_strings) unless helper.resources_build_phase.files_references.include?(helper_strings)
end
configure(
  helper,
  'art.apuch.ksamint.markedit.conversation-capture-helper',
  'ConversationCaptureHelper/Info.plist',
  'ConversationCaptureHelper/Info.entitlements',
  'ConversationCaptureHelper'
)
helper.frameworks_build_phase.files.each(&:remove_from_project)
helper.build_configurations.each do |configuration|
  configuration.build_settings.delete('ASSETCATALOG_COMPILER_APPICON_NAME')
  configuration.build_settings.delete('ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME')
end

quick = project.targets.find { |target| target.name == 'QuickActionExtension' }
unless quick
  quick = project.new_target(:app_extension, 'QuickActionExtension', :osx, '15.0')
  group = project.main_group.new_group('QuickActionExtension', 'QuickActionExtension')
  source = group.new_file('QuickActionViewController.swift')
  group.new_file('Info.plist')
  group.new_file('Info.entitlements')
  quick.source_build_phase.add_file_reference(source)
  add_local_dependency(project, main, quick)
  phase = main.copy_files_build_phases.find { |candidate| candidate.name == 'Embed Foundation Extensions' }
  phase ||= main.new_copy_files_build_phase('Embed Foundation Extensions').tap do |candidate|
    candidate.dst_subfolder_spec = '13'
  end
  phase.add_file_reference(quick.product_reference, true) unless phase.files_references.include?(quick.product_reference)
end
quick_embed_phase = main.copy_files_build_phases.find { |phase| phase.name == 'Embed Foundation Extensions' }
require_codesign_on_copy(quick_embed_phase, quick.product_reference) if quick_embed_phase
quick_group = project.main_group.find_subpath('QuickActionExtension', false)
if quick_group
  quick_strings = quick_group.files.find { |file| file.path == 'Localizable.xcstrings' }
  quick_strings ||= quick_group.new_file('Localizable.xcstrings')
  quick.resources_build_phase.add_file_reference(quick_strings) unless quick.resources_build_phase.files_references.include?(quick_strings)
end
configure(
  quick,
  'art.apuch.ksamint.markedit.quick-actions',
  'QuickActionExtension/Info.plist',
  'QuickActionExtension/Info.entitlements',
  'QuickActionExtension'
)
quick.build_configurations.each do |configuration|
  configuration.build_settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
end
quick.frameworks_build_phase.files.each(&:remove_from_project)

project.files.select { |file| file.path&.end_with?('/Cocoa.framework') }.each(&:remove_from_project)

application_group = project.main_group.find_subpath('MarkEditMac/Sources/Main/Application', false)
if application_group
  %w[
    QuickActionCoordinator.swift
    ConversationCaptureDocument.swift
    ConversationCaptureQueue.swift
  ].each do |filename|
    reference = application_group.files.find { |file| file.path == filename }
    reference ||= application_group.new_file(filename)
    main.source_build_phase.add_file_reference(reference) unless main.source_build_phase.files_references.include?(reference)
  end
end

main.copy_files_build_phases.select { |phase| phase.name == 'Embed Conversation Capture Agent' }.each do |phase|
  main.build_phases.delete(phase)
  phase.remove_from_project
end

project.save
