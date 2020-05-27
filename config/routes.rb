Rails.application.routes.draw do
  # Disable PUT for now since rails sends these :update and they aren't really the same thing.
  def put(*_args); end

  routing_helper = Insights::API::Common::Routing.new(self)
  prefix         = "persister"
  # if ENV["PATH_PREFIX"].present? && ENV["APP_NAME"].present?
  #   prefix = File.join(ENV["PATH_PREFIX"], ENV["APP_NAME"]).gsub(/^\/+|\/+$/, "")
  # end

  namespace :topological_inventory do
    scope :as => :persister, :module => "persister", :path => prefix do
      namespace :v1x0, :path => "1.0" do
        get "/openapi.json", :to => "root#openapi"
        post "/inventory" => "inventory#save_inventory"
      end
    end
  end
end
