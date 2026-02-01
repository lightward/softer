#!/usr/bin/env ruby
require 'xcodeproj'

project_path = File.expand_path('../Softer.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

main_target = project.targets.find { |t| t.name == 'Softer' }

# Find ViewModels group
softer_group = project.main_group.find_subpath('Softer', true)
viewmodels_group = softer_group.find_subpath('ViewModels', false)

if viewmodels_group
  file_ref = viewmodels_group.files.find { |f| f.path == 'RoomListViewModel.swift' }

  if file_ref
    # Remove from build phase
    main_target.source_build_phase.files.each do |build_file|
      if build_file.file_ref == file_ref
        build_file.remove_from_project
        puts "Removed RoomListViewModel.swift from build phase"
      end
    end

    # Remove file reference
    file_ref.remove_from_project
    puts "Removed RoomListViewModel.swift file reference"
  else
    puts "RoomListViewModel.swift not found in ViewModels group"
  end
else
  puts "ViewModels group not found"
end

project.save
puts "Project saved successfully"
