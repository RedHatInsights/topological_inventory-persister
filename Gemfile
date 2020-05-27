source 'https://rubygems.org'

plugin 'bundler-inject', '~> 1.1'
require File.join(Bundler::Plugin.index.load_paths("bundler-inject")[0], "bundler-inject") rescue nil

gem "cloudwatchlogger",    "~> 0.2"
gem 'insights-api-common', '~> 4.0'
gem "manageiq-loggers",    "~> 0.4.0", ">= 0.4.2"
gem "manageiq-messaging",  "~> 0.1.2"
gem "prometheus_exporter", "~> 0.4.5"
gem 'puma',                '>= 4.3.3', '~> 4.3'
gem 'rails',               '~> 5.2.4.3'
gem "topological_inventory-core", "~> 1.1.4"

group :development, :test do
  gem "simplecov"
end

group :test do
  gem 'rspec-rails', '~>3.8'
end
