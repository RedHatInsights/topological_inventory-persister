source 'https://rubygems.org'

plugin 'bundler-inject', '~> 1.1'
require File.join(Bundler::Plugin.index.load_paths("bundler-inject")[0], "bundler-inject") rescue nil

gem "manageiq-loggers",   "~> 0.1.0"
gem "manageiq-messaging", "~> 0.1.2"

gem "inventory_refresh",          :git => "https://github.com/ManageIQ/inventory_refresh",          :branch => "master"
gem "topological_inventory-core", :git => "https://github.com/ManageIQ/topological_inventory-core", :branch => "master"

group :development do
  gem "rspec-rails", "~>3.8"
  gem "simplecov"
end
