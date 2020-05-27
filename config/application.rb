require_relative 'boot'

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"
require "action_cable/engine"
# require "sprockets/railtie"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module TopologicalInventory
  class Application < Rails::Application
    # Settings in config/environments/* take precedence over those specified here.
    # Application configuration should go into files in config/initializers
    # -- all .rb files in that directory are automatically loaded.

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true
    config.autoload_paths << Rails.root.join('lib')

    Insights::API::Common::Logging.activate(config)
    Insights::API::Common::Metrics.activate(config, "topological_inventory_persister_api")

    opts = {
      :host => ENV["QUEUE_HOST"] || "localhost",
      :port => (ENV["QUEUE_PORT"] || 9092).to_i,
      :metrics_port => 0 #(ENV["METRICS_PORT"] || 9394).to_i # 0 disables metrics
    }

    require_relative "../lib/topological_inventory/persister/worker"

    Thread.new do
      persister_worker = TopologicalInventory::Persister::Worker.new(opts)
      persister_worker.run
    end
  end
end
