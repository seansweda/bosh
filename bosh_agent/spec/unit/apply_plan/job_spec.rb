# Copyright (c) 2009-2012 VMware, Inc.

require "spec_helper"

describe Bosh::Agent::ApplyPlan::Job do

  before :each do
    @base_dir = Dir.mktmpdir
    Bosh::Agent::Config.base_dir = @base_dir
  end

  class MockTemplate
    def initialize(base)
      @base = base
      FileUtils.mkdir_p(base)
    end

    def add_directory(path)
      FileUtils.mkdir_p(File.join(@base, path))
    end

    def add_file(path, contents)
      full_path = File.join(@base, path)

      FileUtils.mkdir_p(File.dirname(full_path))
      if contents
        File.open(full_path, "w") { |f| f.write(contents) }
      end
    end
  end

  def make_job(*args)
    Bosh::Agent::ApplyPlan::Job.new(*args)
  end

  def mock_template(blobstore_id, checksum, path)
    Bosh::Agent::Util.should_receive(:unpack_blob).
      with(blobstore_id, checksum, path).
      and_return { template = MockTemplate.new(path); yield template }
  end

  JOB_NAME = "ccdb"

  let(:valid_spec) do
    {
      "name" => "postgres",
      "version" => "2",
      "sha1" => "badcafe",
      "blobstore_id" => "beefdad"
    }
  end

  describe 'initialization' do
    it 'calls #validate_spec' do
      described_class.any_instance.should_receive(:validate_spec)
      make_job(JOB_NAME, valid_spec['name'], valid_spec)
    end

    it 'initializes install path and link path' do
      install_path = File.join(@base_dir, 'data', 'jobs', 'postgres', '2')
      link_path = File.join(@base_dir, 'jobs', 'postgres')

      job = make_job(JOB_NAME, valid_spec['name'], valid_spec)
      job.install_path.should == install_path
      job.link_path.should == link_path
      job.template.should == 'postgres'

      File.exists?(install_path).should be_false
      File.exists?(link_path).should be_false
    end
  end

  describe "installation" do
    it "fetches job template, binds configuration" do
      # TODO: cannot really test permission hardening,
      # as it's only being run in 'configure' mode
      config = {
        "job" => { "name" => "ccdb" },
        "index" => "42",
        "key1" => "value1",
        "key2" => "value2",
        "properties" => {
          "a" => "b"
        }
      }
      config_binding = Bosh::Agent::Util.config_binding(config)
      job = make_job(JOB_NAME, valid_spec["name"], valid_spec, config_binding)

      manifest = {
        "templates" => {
          "foo.erb" => "bin/foo",
          "bar.erb" => "config/test.txt",
          "test" => "test",
          "properties.erb" => "properties"
        }
      }

      mock_template("beefdad", "badcafe", job.install_path) do |template|
        template.add_file("job.MF", Psych.dump(manifest))
        template.add_file("templates/foo.erb", "<%= spec.key1 %>")
        template.add_file("templates/bar.erb", "<%= spec.key2 %>")
        template.add_file("templates/test", "<%= \"\#{name}, \#{index}\" %>")
        template.add_file("templates/properties.erb", "<%= properties.a %>")
      end

      job.install

      File.exists?(job.install_path).should be_true
      File.exists?(job.link_path).should be_true

      bin_dir = File.join(job.install_path, "bin")
      File.directory?(bin_dir).should be_true

      File.read(File.join(job.install_path, "bin", "foo")).
        should == "value1"

      File.read(File.join(job.install_path, "config", "test.txt")).
        should == "value2"

      File.read(File.join(job.install_path, "test")).
        should == "ccdb, 42"

      File.read(File.join(job.install_path, "properties")).
        should == "b"
    end

    describe "installation errors" do
      let(:job) do
        config_binding = Bosh::Agent::Util.config_binding({})
        make_job(JOB_NAME, valid_spec["name"], valid_spec, config_binding)
      end

      let(:job_no_binding) do
        make_job(JOB_NAME, valid_spec["name"], valid_spec)
      end

      def template_for(job)
        mock_template("beefdad", "badcafe", job.install_path) do |template|
          yield template
        end
      end

      it "fails if configuration binding is not provided" do
        template_for(job_no_binding) do |t|
          # not important to have any contents
        end

        expect {
          job_no_binding.install
        }.to raise_error(Bosh::Agent::ApplyPlan::Job::InstallationError,
                         "Failed to install job 'ccdb.postgres': " +
                         "unable to bind configuration, no binding provided")
      end

      it "fails if there is no job manifest" do
        template_for(job) do |template|
          # not important to have any contents
        end

        manifest_path = File.join(job.install_path, "job.MF")

        expect {
          job.install
        }.to raise_error(Bosh::Agent::ApplyPlan::Job::InstallationError,
                         "Failed to install job 'ccdb.postgres': " +
                         "cannot find job manifest #{manifest_path}")
      end

      it "fails if job manifest is malformed" do
        template_for(job) do |template|
          template.add_file("job.MF", "---\ntest :\nfoo")
        end

        manifest_path = File.join(job.install_path, "job.MF")

        expect {
          job.install
        }.to raise_error(Bosh::Agent::ApplyPlan::Job::InstallationError,
                         "Failed to install job 'ccdb.postgres': " +
                         "malformed job manifest #{manifest_path}")
      end

      it "fails if job manifest is not a Hash" do
        template_for(job) do |template|
          template.add_file("job.MF", "test")
        end

        manifest_path = File.join(job.install_path, "job.MF")

        expect {
          job.install
        }.to raise_error(Bosh::Agent::ApplyPlan::Job::InstallationError,
                         "Failed to install job 'ccdb.postgres': " +
                         "invalid job manifest, " +
                         "Hash expected, String given")
      end

      it "fails if job manifest templates section is invalid" do
        manifest = {
          "templates" => "test"
        }

        template_for(job) do |template|
          template.add_file("job.MF", Psych.dump(manifest))
        end

        expect {
          job.install
        }.to raise_error(Bosh::Agent::ApplyPlan::Job::InstallationError,
                         "Failed to install job 'ccdb.postgres': " +
                         "invalid value for templates in job manifest, " +
                         "Hash expected, String given")
      end

      it "fails if template doesn't exist" do
        manifest = {
          "templates" => {
            "foo.erb" => "config/foo"
          }
        }

        template_for(job) do |template|
          template.add_file("job.MF", Psych.dump(manifest))
        end

        template_path = File.join(job.install_path, "templates", "foo.erb")

        expect {
          job.install
        }.to raise_error(Bosh::Agent::ApplyPlan::Job::InstallationError,
                         "Failed to install job 'ccdb.postgres': " +
                         "template 'foo.erb' doesn't exist")
      end

      it "fails if configuration file cannot be bound" do
        manifest = {
          "templates" => {
            "foo.erb" => "config/foo"
          }
        }

        template_for(job) do |template|
          template.add_file("job.MF", Psych.dump(manifest))
          template.add_file("templates/foo.erb", "<%= properties.foo.bar %>")
        end

        manifest_path = File.join(job.install_path, "job.MF")

        expect {
          job.install
        }.to raise_error(Bosh::Agent::ApplyPlan::Job::InstallationError,
                         "Failed to install job 'ccdb.postgres': " +
                         "failed to process configuration template " +
                         "'foo.erb': line 1, error: undefined method " +
                         "`bar' for nil:NilClass")
      end

      it "fails if property cannot be found" do
        manifest = {
          "templates" => {
            "foo.erb" => "config/foo"
          }
        }

        template_for(job) do |template|
          template.add_file("job.MF", Psych.dump(manifest))
          template.add_file("templates/foo.erb", "<%= p('foo.bar') %>")
        end

        manifest_path = File.join(job.install_path, "job.MF")

        expect {
          job.install
        }.to raise_error(Bosh::Agent::ApplyPlan::Job::InstallationError,
                         "Failed to install job 'ccdb.postgres': " +
                         "failed to process configuration template " +
                         "'foo.erb': line 1, error: Can't find property " +
                         "`[\"foo.bar\"]'")
      end
    end
  end

  describe "configuration" do

    it "runs post install hook and configures monit" do
      config = {
        "properties" => {
          "foo" => "bar"
        }
      }

      config_binding = Bosh::Agent::Util.config_binding(config)
      job = make_job(JOB_NAME, valid_spec["name"], valid_spec, config_binding)

      mock_template("beefdad", "badcafe", job.install_path) do |template|
        template.add_file("job.MF", Psych.dump({}))
        template.add_file("monit", "check process ccdb\nmode manual\n" +
                          "<%= properties.foo %>")
        template.add_file("extra.monit", "check process ccdb_extra\n")
      end

      job.install

      Bosh::Agent::Util.should_receive(:run_hook).
        with("post_install", "postgres")

      job.configure(3)

      monit_file = File.join(job.install_path, "0003_ccdb.postgres.monitrc")
      monit_link = File.join(@base_dir, "monit", "job", "0003_ccdb.postgres.monitrc")

      File.exists?(monit_file).should be_true
      File.exists?(monit_link).should be_true
      File.read(monit_file).should == "check process ccdb mode manual bar"

      extra_monit_file = File.join(job.install_path,
                                   "0003_ccdb.postgres_extra.monitrc")
      extra_monit_link = File.join(@base_dir, "monit", "job",
                                   "0003_ccdb.postgres_extra.monitrc")

      File.exists?(extra_monit_file).should be_true
      File.exists?(extra_monit_link).should be_true
      File.read(extra_monit_file).
        should == "check process ccdb_extra mode manual"

      File.realpath(extra_monit_link).should == File.realpath(extra_monit_file)
    end

    describe "configuration errors" do

      it "fails if cannot bind monit file to configuration" do
        config_binding = Bosh::Agent::Util.config_binding({})
        job = make_job(JOB_NAME, valid_spec["name"], valid_spec, config_binding)

        mock_template("beefdad", "badcafe", job.install_path) do |template|
          template.add_file("job.MF", Psych.dump({}))
          template.add_file("monit", "check process ccdb\nmode manual\n" +
                            "<%= properties.foo.bar %>")
        end

        job.install

        Bosh::Agent::Util.should_receive(:run_hook).
          with("post_install", "postgres")

        expect {
          job.configure(0)
        }.to raise_error(Bosh::Agent::ApplyPlan::Job::ConfigurationError,
                         "Failed to configure job 'ccdb.postgres': " +
                         "failed to process monit template " +
                         "'monit': line 3, error: undefined method " +
                         "`bar' for nil:NilClass")
      end

    end

    describe "monit config modifications" do
      # FIXME testing a private method like this is not right,
      # need to move it out into its own abstraction

      it "adds 'mode manual' to each 'check process' block" do
        job = make_job(JOB_NAME, valid_spec["name"], valid_spec)

        file1 = "check process nats mode active start program " +
                "\"bla\" stop program \"bla bla\""

        result1 = "check process nats mode active start program " +
                  "\"bla\" stop program \"bla bla\""

        job.send(:add_modes, file1).should == result1


        file2 = <<-IN
          check process nats
            start program "bla"
            stop program "bla bla"
        IN

        result2 = "check process nats start program " +
                  "\"bla\" stop program \"bla bla\" mode manual"

        job.send(:add_modes, file2).should == result2

        file3 = <<-IN
          check process nats
            start program "bla"
            stop program "bla bla"

          check process zb
          start program "ppc"
          mode active

          check filesystem aaa
          start program "mode active"
        IN

        result3 = "check process nats start program " +
                  "\"bla\" stop program \"bla bla\" mode manual " +
                  "check process zb start program \"ppc\" mode active " +
                  "check filesystem aaa start program " +
                  "\"mode active\" mode manual"

        job.send(:add_modes, file3).should == result3
      end

      it "doesn't alter empty monit file" do
        job = make_job(JOB_NAME, valid_spec["name"], valid_spec)
        job.send(:add_modes, "").should == ""
      end
    end

  end

end
