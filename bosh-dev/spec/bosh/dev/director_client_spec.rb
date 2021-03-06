require 'spec_helper'
require 'bosh/dev/director_client'

module Bosh::Dev
  describe DirectorClient do
    let (:director_handle) { instance_double('Bosh::Cli::Director') }
    let(:cli) { instance_double('Bosh::Dev::BoshCliSession', run_bosh: nil) }

    subject(:director_client) do
      DirectorClient.new(
        uri: 'bosh.example.com',
        username: 'fake_username',
        password: 'fake_password',
      )
    end

    before do
      BoshCliSession.stub(new: cli)

      director_klass = class_double('Bosh::Cli::Director').as_stubbed_const
      director_klass.stub(:new).with(
        'bosh.example.com',
        'fake_username',
        'fake_password',
      ).and_return(director_handle)
    end

    describe '#upload_stemcell' do
      let(:stemcell_archive) do
        instance_double('Bosh::Stemcell::Archive', name: 'fake-stemcell', version: '008', path: '/path/to/fake-stemcell-008.tgz')
      end

      before do
        director_handle.stub(:list_stemcells) { [] }
      end

      it 'uploads the stemcell with the cli' do
        cli.should_receive(:run_bosh).with('upload stemcell /path/to/fake-stemcell-008.tgz', debug_on_fail: true)

        director_client.upload_stemcell(stemcell_archive)
      end

      it 'always re-targets and logs in first' do
        cli.should_receive(:run_bosh).with('target bosh.example.com').ordered
        cli.should_receive(:run_bosh).with('login fake_username fake_password').ordered
        cli.should_receive(:run_bosh).with(/upload stemcell/, debug_on_fail: true).ordered

        director_client.upload_stemcell(stemcell_archive)
      end

      context 'when the stemcell being uploaded exists on the director' do
        before do
          director_handle.stub(:list_stemcells).and_return([{ 'name' => 'fake-stemcell', 'version' => '008' }])
        end

        it 'does not re-upload it' do
          cli.should_not_receive(:run_bosh).with(/upload stemcell/, debug_on_fail: true)

          director_client.upload_stemcell(stemcell_archive)
        end
      end
    end

    describe '#upload_release' do
      it 'uploads the release using the cli, rebasing assuming this is a dev release' do
        cli.should_receive(:run_bosh).with('upload release /path/to/fake-release.tgz --rebase', debug_on_fail: true)

        director_client.upload_release('/path/to/fake-release.tgz')
      end

      it 'always re-targets and logs in first' do
        cli.should_receive(:run_bosh).with('target bosh.example.com').ordered
        cli.should_receive(:run_bosh).with('login fake_username fake_password').ordered
        cli.should_receive(:run_bosh).with(/upload release/, debug_on_fail: true).ordered

        director_client.upload_release('/path/to/fake-release.tgz')
      end

      context 'when the release has previously been uploaded' do
        it 'should ignore the associated error' do
          cli.stub(:run_bosh).
            with(/upload release/, debug_on_fail: true).
            and_raise('... Error 100: Rebase is attempted without any job or package changes ...')

          expect {
            director_client.upload_release('/path/to/fake-release.tgz')
          }.not_to raise_error
        end
      end
    end

    describe '#deploy' do
      it 'sets the deployment and then runs a deplpy using the cli' do
        cli.should_receive(:run_bosh).with('deployment /path/to/fake-manifest.yml').ordered
        cli.should_receive(:run_bosh).with('deploy', debug_on_fail: true).ordered

        director_client.deploy('/path/to/fake-manifest.yml')
      end

      it 'always re-targets and logs in first' do
        cli.should_receive(:run_bosh).with('target bosh.example.com').ordered
        cli.should_receive(:run_bosh).with('login fake_username fake_password').ordered
        cli.should_receive(:run_bosh).with(/deployment/).ordered
        cli.should_receive(:run_bosh).with(/deploy/, debug_on_fail: true).ordered

        director_client.deploy('/path/to/fake-manifest.yml')
      end
    end
  end
end
