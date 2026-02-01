#!/usr/bin/env ruby
require 'xcodeproj'

project_path = File.expand_path('../Softer.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

# Find the main target
main_target = project.targets.find { |t| t.name == 'Softer' }

# Remove AppCoordinator.swift
softer_group = project.main_group.find_subpath('Softer', true)
app_coord_ref = softer_group.files.find { |f| f.path == 'AppCoordinator.swift' }

if app_coord_ref
  # Remove from build phase
  main_target.source_build_phase.files.each do |build_file|
    if build_file.file_ref == app_coord_ref
      build_file.remove_from_project
      puts "Removed AppCoordinator.swift from build phase"
    end
  end

  # Remove file reference
  app_coord_ref.remove_from_project
  puts "Removed AppCoordinator.swift file reference"
else
  puts "AppCoordinator.swift not found in project"
end

project.save
puts "Project saved successfully"
