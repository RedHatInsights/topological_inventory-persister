source 'https://rubygems.org'

plugin 'bundler-inject', '~> 1.1'
require File.join(Bundler::Plugin.index.load_paths("bundler-inject")[0], "bundler-inject") rescue nil

gem "cloudwatchlogger",    "~> 0.2"
gem "manageiq-loggers",    "~> 0.4.0", ">= 0.4.2"
gem "manageiq-messaging",  "~> 0.1.2"
gem "prometheus_exporter", "~> 0.4.5"

gem "topological_inventory-core", :git => "https://github.com/RedHatInsights/topological_inventory-core", :branch => "master"

group :development do
  gem "rspec-rails", "~>3.8"
  gem "simplecov"
end
