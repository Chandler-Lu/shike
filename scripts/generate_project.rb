#!/usr/bin/env ruby
# Refresh source membership in the checked-in project, preserving targets, schemes and signing.
require 'xcodeproj'
root = File.expand_path('..', __dir__)
Dir.chdir(root)
abort 'Restore the checked-in Shike.xcodeproj before refreshing membership.' unless File.exist?('Shike.xcodeproj/project.pbxproj')
project = Xcodeproj::Project.open('Shike.xcodeproj')
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
  'ShikeTests' => Dir.glob('Tests/**/*.swift'),
  'ShikeUITests' => Dir.glob('UITests/**/*.swift'),
  'ShikeWatchUITests' => Dir.glob('WatchUITests/**/*.swift')
}
legal = Dir.glob('Shared/Resources/**/*').select { |f| File.file?(f) && !f.include?('.xcassets/') }
companion_legal = legal.reject { |f| f.end_with?('PrivacyPolicy.txt') }
resources = {
  'Shike' => legal + ['App/Assets.xcassets'], 'ShikeShare' => legal,
  'ShikeWidgets' => companion_legal, 'ShikeWatch' => companion_legal + ['WatchApp/Assets.xcassets'],
  'ShikeWatchWidgets' => companion_legal
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
puts 'Refreshed iPhone, widget and Watch file membership; preserved signing, versions and schemes.'
