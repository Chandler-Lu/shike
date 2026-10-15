#!/usr/bin/env ruby
# Refresh source membership in the checked-in project, preserving targets, schemes and signing.
begin
  require 'xcodeproj'
rescue LoadError
  # Optional repository-local tooling; no global Ruby installation is required.
  Gem.use_paths(File.expand_path('../build/gems', __dir__))
  require 'xcodeproj'
end
root = File.expand_path('..', __dir__)
Dir.chdir(root)
abort 'Restore the checked-in Shike.xcodeproj before refreshing membership.' unless File.exist?('Shike.xcodeproj/project.pbxproj')
project = Xcodeproj::Project.open('Shike.xcodeproj')
app = project.targets.find { |t| t.name == 'Shike' }
share = project.targets.find { |t| t.name == 'ShikeShare' }
ios_widget = project.targets.find { |t| t.name == 'ShikeWidgets' }
watch = project.targets.find { |t| t.name == 'ShikeWatch' }
mac_widget = project.targets.find { |t| t.name == 'ShikeMacWidgets' }
unless mac_widget
  mac_widget = project.new_target(:app_extension, 'ShikeMacWidgets', :osx, '14.0')
  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.product_name = 'ShikeCore'
  dependency.package = app.package_product_dependencies.first.package
  mac_widget.package_product_dependencies << dependency
  framework = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  framework.product_ref = dependency
  mac_widget.frameworks_build_phase.files << framework
end
project.targets.each do |target|
  target.build_configurations.each do |config|
    s = config.build_settings
    if %w[Shike ShikeShare ShikeWidgets ShikeTests ShikeUITests].include?(target.name)
      s['TARGETED_DEVICE_FAMILY'] = '1,2'
    end
    if %w[Shike ShikeShare ShikeTests ShikeUITests].include?(target.name)
      s['SUPPORTS_MACCATALYST'] = 'YES'
      s['DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER'] = 'NO'
      s['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
      s['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator macosx'
    end
    if target == app
      s['INFOPLIST_KEY_UISupportedInterfaceOrientations'] = 'UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight'
      s['CODE_SIGN_ENTITLEMENTS[sdk=macosx*]'] = 'Config/ShikeMac.entitlements'
      s['SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD'] = 'NO'
    elsif target == share
      s['CODE_SIGN_ENTITLEMENTS[sdk=macosx*]'] = 'Config/ShikeMacShare.entitlements'
    elsif target == mac_widget
      host = app.build_configurations.find { |c| c.name == config.name }
      config.base_configuration_reference = host.base_configuration_reference
      %w[DEVELOPMENT_TEAM CODE_SIGN_STYLE MARKETING_VERSION CURRENT_PROJECT_VERSION SWIFT_VERSION SWIFT_ACTIVE_COMPILATION_CONDITIONS].each do |key|
        s[key] = host.build_settings[key] if host.build_settings.key?(key)
      end
      s.merge!({ 'PRODUCT_BUNDLE_IDENTIFIER' => '$(SHIKE_BUNDLE_ID).macwidgets',
                 'CODE_SIGN_ENTITLEMENTS' => 'Config/MacWidget.entitlements',
                 'INFOPLIST_FILE' => 'Config/Widget-Info.plist', 'GENERATE_INFOPLIST_FILE' => 'YES',
                 'INFOPLIST_KEY_CFBundleDisplayName' => '拾刻计划倒数日',
                 'SKIP_INSTALL' => 'YES', 'APPLICATION_EXTENSION_API_ONLY' => 'YES',
                 'ENABLE_APP_SANDBOX' => 'YES', 'SWIFT_VERSION' => '5.0',
                 'MACOSX_DEPLOYMENT_TARGET' => '14.0', 'SDKROOT' => 'macosx',
                 'SUPPORTED_PLATFORMS' => 'macosx', 'SUPPORTS_MACCATALYST' => 'NO',
                 'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/../Frameworks', '@executable_path/../../../../Frameworks'] })
      s.delete('TARGETED_DEVICE_FAMILY')
    end
  end
end
# The Mac host embeds a native macOS widget, never the iOS widget or Watch app.
app.add_dependency(mac_widget) unless app.dependencies.any? { |d| d.target == mac_widget }
app.dependencies.each do |dependency|
  dependency.platform_filter = 'maccatalyst' if dependency.target == mac_widget
  dependency.platform_filter = 'ios' if [ios_widget, watch].include?(dependency.target)
end
app.copy_files_build_phases.each do |phase|
  phase.files.each do |file|
    file.platform_filter = 'ios' if [ios_widget.product_reference, watch.product_reference].include?(file.file_ref)
  end
end
mac_embed = app.copy_files_build_phases.find { |p| p.name == 'Embed Mac Extensions' } || app.new_copy_files_build_phase('Embed Mac Extensions')
mac_embed.dst_subfolder_spec = '13'
mac_embed.add_file_reference(mac_widget.product_reference, true).tap do |file|
  file.platform_filter = 'maccatalyst'
  file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end
shared = Dir.glob('Shared/{Services,UI}/**/*.swift')
companion = Dir.glob('Shared/CountdownCompanion/*.swift')
widget = Dir.glob('CountdownWidgets/*.swift')
widget_shared = companion.reject { |f| f.end_with?('CountdownConnectivity.swift') }
sources = {
  'Shike' => Dir.glob('App/**/*.swift') + shared + companion + ['CountdownWidgets/CountdownWidgetContent.swift'],
  'ShikeShare' => Dir.glob('ShareExtension/**/*.swift') + shared,
  'ShikeWidgets' => widget + widget_shared,
  'ShikeWatch' => Dir.glob('WatchApp/**/*.swift') + companion,
  'ShikeWatchWidgets' => widget + widget_shared,
  'ShikeMacWidgets' => widget + widget_shared,
  'ShikeTests' => Dir.glob('Tests/**/*.swift'),
  'ShikeUITests' => Dir.glob('UITests/**/*.swift'),
  'ShikeWatchUITests' => Dir.glob('WatchUITests/**/*.swift')
}
legal = Dir.glob('Shared/Resources/**/*').select { |f| File.file?(f) && !f.include?('.xcassets/') }
companion_legal = legal.reject { |f| f.end_with?('PrivacyPolicy.txt') }
resources = {
  'Shike' => legal + ['App/Assets.xcassets'], 'ShikeShare' => legal,
  'ShikeWidgets' => companion_legal, 'ShikeWatch' => companion_legal + ['WatchApp/Assets.xcassets'],
  'ShikeWatchWidgets' => companion_legal, 'ShikeMacWidgets' => companion_legal
}
missing = sources.keys - project.targets.map(&:name)
abort "Restore missing targets from the checked-in project: #{missing.join(', ')}" unless missing.empty?
def refresh(project, phase, paths)
  wanted = paths.uniq.sort
  phase.files.to_a.each do |file|
    phase.remove_build_file(file) unless file.file_ref && wanted.include?(file.file_ref.path)
  end
  wanted.each do |path|
    ref = project.files.find { |file| file.path == path } || project.main_group.new_file(path)
    phase.add_file_reference(ref, true)
  end
end
project.targets.each do |target|
  refresh(project, target.source_build_phase, sources.fetch(target.name)) if sources.key?(target.name)
  refresh(project, target.resources_build_phase, resources.fetch(target.name, [])) if sources.key?(target.name)
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.add_test_target(project.targets.find { |t| t.name == 'ShikeTests' })
scheme.add_test_target(project.targets.find { |t| t.name == 'ShikeUITests' })
scheme.save_as('Shike.xcodeproj', 'ShikeMac', true)
puts 'Refreshed iPhone/iPad, Catalyst, native Mac widget and Watch targets; preserved signing and versions.'
