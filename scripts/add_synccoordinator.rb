#!/usr/bin/env ruby
require 'xcodeproj'

project_path = File.expand_path('../Softer.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

main_target = project.targets.find { |t| t.name == 'Softer' }
test_target = project.targets.find { |t| t.name == 'SofterTests' }

# Add SyncCoordinator to Store group
softer_group = project.main_group.find_subpath('Softer', true)
store_group = softer_group.find_subpath('Store', false)

if store_group
  existing = store_group.files.find { |f| f.path == 'SyncCoordinator.swift' }
  unless existing
    file_ref = store_group.new_file('SyncCoordinator.swift')
    main_target.source_build_phase.add_file_reference(file_ref)
    puts "Added SyncCoordinator.swift to Softer target"
  else
    puts "SyncCoordinator.swift already in project"
  end
else
  puts "Store group not found"
end

project.save
puts "Project saved successfully"
