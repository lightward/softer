#!/usr/bin/env ruby
require 'xcodeproj'

project_path = File.expand_path('../Softer.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

# Find the main target
main_target = project.targets.find { |t| t.name == 'Softer' }
test_target = project.targets.find { |t| t.name == 'SofterTests' }

# Find or create the Store group under Softer
softer_group = project.main_group.find_subpath('Softer', true)
store_group = softer_group.find_subpath('Store', false) || softer_group.new_group('Store', 'Store')

# Add Store files to main target
store_files = [
  'LocalStore.swift',
  'SyncStatus.swift',
  'SofterStore.swift'
]

store_files.each do |filename|
  file_path = "Softer/Store/#{filename}"

  # Check if file already exists in project
  existing = store_group.files.find { |f| f.path == filename }
  if existing
    puts "#{filename} already in project"
    next
  end

  file_ref = store_group.new_file(filename)
  main_target.source_build_phase.add_file_reference(file_ref)
  puts "Added #{filename} to Softer target"
end

# Find SofterTests group
tests_group = project.main_group.find_subpath('SofterTests', true)

# Add test files to test target
test_files = [
  'LocalStoreTests.swift',
  'SofterStoreTests.swift'
]

test_files.each do |filename|
  # Check if file already exists in project
  existing = tests_group.files.find { |f| f.path == filename }
  if existing
    puts "#{filename} already in project"
    next
  end

  file_ref = tests_group.new_file(filename)
  test_target.source_build_phase.add_file_reference(file_ref)
  puts "Added #{filename} to SofterTests target"
end

project.save
puts "Project saved successfully"
