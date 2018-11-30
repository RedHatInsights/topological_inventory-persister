begin
  require 'bundler/setup'
rescue LoadError
  puts 'You must `gem install bundler` and `bundle install` to run rake tasks'
end

require "rspec/core/rake_task"

require "active_record"
load "active_record/railties/databases.rake"

namespace :db do
  task :environment do
    require "topological_inventory/core/ar_helper"
    TopologicalInventory::Core::ArHelper.database_yaml_path = Pathname.new(__dir__).join("config/database.yml")
    TopologicalInventory::Core::ArHelper.load_environment!
  end
  Rake::Task["db:load_config"].enhance(["db:environment"])
end

# Spec related rake tasks
RSpec::Core::RakeTask.new(:spec)

namespace :spec do
  task :initialize do
    ENV["RAILS_ENV"] ||= "test"
  end

  desc "Setup the database for running tests"
  task :setup => [:initialize, "db:test:prepare"]
end

task default: :spec
