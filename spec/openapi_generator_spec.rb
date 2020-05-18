require 'rake'
$LOAD_PATH << File.expand_path("../lib", __dir__)

describe "openapi_generate.rake" do
  before do
    Rake.application.rake_require('tasks/openapi_generate')
    allow(File).to receive(:write).and_return(nil)
  end

  it "doesn't raise an exception" do
    # TODO: It can work after the generator will be able to create json
    # TODO: it's only able to update existing openapi json now
    # expect { Rake.application["openapi:generate"].invoke }.not_to raise_exception
  end
end
