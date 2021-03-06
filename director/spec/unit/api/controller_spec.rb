# Copyright (c) 2009-2012 VMware, Inc.

require 'spec_helper'
require 'rack/test'

module Bosh::Director
  module Api
    describe Controller do
      include Rack::Test::Methods

      let!(:temp_dir) { Dir.mktmpdir}

      before do
        blobstore_dir = File.join(temp_dir, 'blobstore')
        FileUtils.mkdir_p(blobstore_dir)

        test_config = Psych.load(spec_asset('test-director-config.yml'))
        test_config['dir'] = temp_dir
        test_config['blobstore'] = {
            'provider' => 'local',
            'options' => {'blobstore_path' => blobstore_dir}
        }
        test_config['snapshots']['enabled'] = true
        Config.configure(test_config)
        @director_app = App.new(Config.load_hash(test_config))
      end

      after do
        FileUtils.rm_rf(temp_dir)
      end

      def app
        @rack_app ||= Controller.new
      end

      def login_as_admin
        basic_authorize 'admin', 'admin'
      end

      def login_as(username, password)
        basic_authorize username, password
      end

      def expect_redirect_to_queued_task(response)
        response.should be_redirect
        (last_response.location =~ /\/tasks\/(\d+)/).should_not be_nil

        new_task = Models::Task[$1]
        new_task.state.should == 'queued'
        new_task
      end


      it 'requires auth' do
        get '/'
        last_response.status.should == 401
      end

      it 'sets the date header' do
        get '/'
        last_response.headers['Date'].should_not be_nil
      end

      it 'allows Basic HTTP Auth with admin/admin credentials for ' +
             "test purposes (even though user doesn't exist)" do
        basic_authorize 'admin', 'admin'
        get '/'
        last_response.status.should == 404
      end

      context 'when serving resources from temp' do
        let(:resouce_manager) { instance_double('Bosh::Director::Api::ResourceManager') }
        let(:tmp_file) { File.join(Dir.tmpdir, "resource-#{SecureRandom.uuid}") }

        def app
          ResourceManager.stub(new: resouce_manager)
          Controller.new
        end

        before do
          File.open(tmp_file, 'w') do |f|
            f.write('some data')
          end

          FileUtils.touch(tmp_file)
        end

        it 'cleans up temp file after serving it' do
          login_as_admin

          resouce_manager.should_receive(:get_resource_path).with('deadbeef').and_return(tmp_file)

          File.exists?(tmp_file).should be_true
          get '/resources/deadbeef'
          last_response.body.should == 'some data'
          File.exists?(tmp_file).should be_false
        end
      end

      describe 'Fetching status' do
        it 'not authenticated' do
          get '/info'
          last_response.status.should == 200
          Yajl::Parser.parse(last_response.body)['user'].should == nil
        end

        it 'authenticated' do
          login_as_admin
          get '/info'

          last_response.status.should == 200
          expected = {
              'name' => 'Test Director',
              'version' => "#{VERSION} (#{Config.revision})",
              'uuid' => Config.uuid,
              'user' => 'admin',
              'cpi' => 'dummy',
              'features' => {
                  'dns' => {
                      'status' => true,
                      'extras' => {'domain_name' => 'bosh'}
                  },
                  'compiled_package_cache' => {
                      'status' => true,
                      'extras' => {'provider' => 'local'}
                  },
                  'snapshots' => {
                      'status' => true
                  }
              }
          }

          Yajl::Parser.parse(last_response.body).should == expected
        end
      end

      describe 'API calls' do
        before(:each) { login_as_admin }

        describe 'creating a stemcell' do
          it 'expects compressed stemcell file' do
            post '/stemcells', spec_asset('tarball.tgz'), { 'CONTENT_TYPE' => 'application/x-compressed' }
            expect_redirect_to_queued_task(last_response)
          end

          it 'expects remote stemcell location' do
            post '/stemcells', Yajl::Encoder.encode('location' => 'http://stemcell_url'), { 'CONTENT_TYPE' => 'application/json' }
            expect_redirect_to_queued_task(last_response)
          end

          it 'only consumes application/x-compressed and application/json' do
            post '/stemcells', spec_asset('tarball.tgz'), { 'CONTENT_TYPE' => 'application/octet-stream' }
            last_response.status.should == 404
          end
        end

        describe 'creating a release' do
          it 'expects compressed release file' do
            post '/releases', spec_asset('tarball.tgz'), { 'CONTENT_TYPE' => 'application/x-compressed' }
            expect_redirect_to_queued_task(last_response)
          end

          it 'expects remote release location' do
            post '/releases', Yajl::Encoder.encode('location' => 'http://release_url'), { 'CONTENT_TYPE' => 'application/json' }
            expect_redirect_to_queued_task(last_response)
          end

          it 'only consumes application/x-compressed and application/json' do
            post '/releases', spec_asset('tarball.tgz'), { 'CONTENT_TYPE' => 'application/octet-stream' }
            last_response.status.should == 404
          end
        end

        describe 'creating a deployment' do
          it 'expects compressed deployment file' do
            post '/deployments', spec_asset('test_conf.yaml'), { 'CONTENT_TYPE' => 'text/yaml' }
            expect_redirect_to_queued_task(last_response)
          end

          it 'only consumes text/yaml' do
            post '/deployments', spec_asset('test_conf.yaml'), { 'CONTENT_TYPE' => 'text/plain' }
            last_response.status.should == 404
          end
        end

        describe 'job management' do
          it 'allows putting jobs into different states' do
            Models::Deployment.
                create(:name => 'foo', :manifest => Psych.dump({'foo' => 'bar'}))
            put '/deployments/foo/jobs/nats?state=stopped', spec_asset('test_conf.yaml'), { 'CONTENT_TYPE' => 'text/yaml' }
            expect_redirect_to_queued_task(last_response)
          end

          it 'allows putting job instances into different states' do
            Models::Deployment.
                create(:name => 'foo', :manifest => Psych.dump({'foo' => 'bar'}))
            put '/deployments/foo/jobs/dea/2?state=stopped', spec_asset('test_conf.yaml'), { 'CONTENT_TYPE' => 'text/yaml' }
            expect_redirect_to_queued_task(last_response)
          end

          it 'allows putting the job instance into different resurrection_paused values' do
            deployment = Models::Deployment.
                create(:name => 'foo', :manifest => Psych.dump({'foo' => 'bar'}))
            instance = Models::Instance.
                create(:deployment => deployment, :job => 'dea',
                       :index => '0', :state => 'started')
            put '/deployments/foo/jobs/dea/0/resurrection', Yajl::Encoder.encode('resurrection_paused' => true), { 'CONTENT_TYPE' => 'application/json' }
            last_response.status.should == 200
            expect(instance.reload.resurrection_paused).to be_true
          end

          it "doesn't like invalid indices" do
            put '/deployments/foo/jobs/dea/zb?state=stopped', spec_asset('test_conf.yaml'), { 'CONTENT_TYPE' => 'text/yaml' }
            last_response.status.should == 400
          end

          it 'can get job information' do
            deployment = Models::Deployment.create(name: 'foo', manifest: Psych.dump({'foo' => 'bar'}))
            instance = Models::Instance.create(deployment: deployment, job: 'nats', index: '0', state: 'started')
            disk = Models::PersistentDisk.create(instance: instance, disk_cid: 'disk_cid')

            get '/deployments/foo/jobs/nats/0', {}

            last_response.status.should == 200
            expected = {
                'deployment' => 'foo',
                'job' => 'nats',
                'index' => 0,
                'state' => 'started',
                'disks' => %w[disk_cid]
            }

            Yajl::Parser.parse(last_response.body).should == expected
          end

          it 'should return 404 if the instance cannot be found' do
            get '/deployments/foo/jobs/nats/0', {}
            last_response.status.should == 404
          end
        end

        describe 'log management' do
          it 'allows fetching logs from a particular instance' do
            deployment = Models::Deployment.
                create(:name => 'foo', :manifest => Psych.dump({'foo' => 'bar'}))
            instance = Models::Instance.
                create(:deployment => deployment, :job => 'nats',
                       :index => '0', :state => 'started')
            get '/deployments/foo/jobs/nats/0/logs', {}
            expect_redirect_to_queued_task(last_response)
          end

          it '404 if no instance' do
            get '/deployments/baz/jobs/nats/0/logs', {}
            last_response.status.should == 404
          end

          it '404 if no deployment' do
            deployment = Models::Deployment.
                create(:name => 'bar', :manifest => Psych.dump({'foo' => 'bar'}))
            get '/deployments/bar/jobs/nats/0/logs', {}
            last_response.status.should == 404
          end
        end

        describe 'listing stemcells' do
          it 'has API call that returns a list of stemcells in JSON' do
            stemcells = (1..10).map do |i|
              Models::Stemcell.
                  create(:name => "stemcell-#{i}", :version => i,
                         :cid => rand(25000 * i))
            end

            get '/stemcells', {}, {}
            last_response.status.should == 200

            body = Yajl::Parser.parse(last_response.body)

            body.kind_of?(Array).should be_true
            body.size.should == 10

            response_collection = body.map do |e|
              [e['name'], e['version'], e['cid']]
            end

            expected_collection = stemcells.sort_by { |e| e.name }.map do |e|
              [e.name.to_s, e.version.to_s, e.cid.to_s]
            end

            response_collection.should == expected_collection
          end

          it 'returns empty collection if there are no stemcells' do
            get '/stemcells', {}, {}
            last_response.status.should == 200

            body = Yajl::Parser.parse(last_response.body)
            body.should == []
          end
        end

        describe 'listing releases' do
          it 'has API call that returns a list of releases in JSON' do
            release1 = Models::Release.create(name: 'release-1')
            Models::ReleaseVersion.
                create(release: release1, version: 1)
            deployment1 = Models::Deployment.create(name: 'deployment-1')
            release1 = deployment1.add_release_version(release1.versions.first) # release-1 is now currently_deployed
            release2 = Models::Release.create(name: 'release-2')
            Models::ReleaseVersion.
                create(release: release2, version: 2, commit_hash: '0b2c3d', uncommitted_changes: true)

            get '/releases', {}, {}
            last_response.status.should == 200
            body = last_response.body

            expected_collection = [
                {'name' => 'release-1',
                 'release_versions' => [Hash['version', '1', 'commit_hash', 'unknown', 'uncommitted_changes', false, 'currently_deployed', true, 'job_names', []]]},
                {'name' => 'release-2',
                 'release_versions' => [Hash['version', '2', 'commit_hash', '0b2c3d', 'uncommitted_changes', true, 'currently_deployed', false, 'job_names', []]]}
            ]

            body.should == Yajl::Encoder.encode(expected_collection)
          end

          it 'returns empty collection if there are no releases' do
            get '/releases', {}, {}
            last_response.status.should == 200

            body = Yajl::Parser.parse(last_response.body)
            body.should == []
          end
        end

        describe 'listing deployments' do
          it 'has API call that returns a list of deployments in JSON' do
            num_dummies = Random.new.rand(3..7)
            stemcells = (1..num_dummies).map { |i|
              Models::Stemcell.create(
                  :name => "stemcell-#{i}", :version => i, :cid => rand(25000 * i))
            }
            releases = (1..num_dummies).map { |i|
              release = Models::Release.create(:name => "release-#{i}")
              Models::ReleaseVersion.create(:release => release, :version => i)
              release
            }
            deployments = (1..num_dummies).map { |i|
              d = Models::Deployment.create(:name => "deployment-#{i}")
              (0..rand(num_dummies)).each do |v|
                d.add_stemcell(stemcells[v])
                d.add_release_version(releases[v].versions.sample)
              end
              d
            }

            get '/deployments', {}, {}
            last_response.status.should == 200

            body = Yajl::Parser.parse(last_response.body)
            body.kind_of?(Array).should be_true
            body.size.should == num_dummies

            expected_collection = deployments.sort_by { |e| e.name }.map { |e|
              name = e.name
              releases = e.release_versions.map { |rv|
                Hash['name', rv.release.name, 'version', rv.version.to_s]
              }
              stemcells = e.stemcells.map { |sc|
                Hash['name', sc.name, 'version', sc.version]
              }
              Hash['name', name, 'releases', releases, 'stemcells', stemcells]
            }

            body.should == expected_collection
          end
        end

        describe 'getting deployment info' do
          it 'returns manifest' do
            deployment = Models::Deployment.
                create(:name => 'test_deployment',
                       :manifest => Psych.dump({'foo' => 'bar'}))
            get '/deployments/test_deployment'

            last_response.status.should == 200
            body = Yajl::Parser.parse(last_response.body)
            Psych.load(body['manifest']).should == {'foo' => 'bar'}
          end
        end

        describe 'getting deployment vms info' do
          it 'returns a list of agent_ids, jobs and indices' do
            deployment = Models::Deployment.
                create(:name => 'test_deployment',
                       :manifest => Psych.dump({'foo' => 'bar'}))
            vms = []

            15.times do |i|
              vm_params = {
                  'agent_id' => "agent-#{i}",
                  'cid' => "cid-#{i}",
                  'deployment_id' => deployment.id
              }
              vm = Models::Vm.create(vm_params)

              instance_params = {
                  'deployment_id' => deployment.id,
                  'vm_id' => vm.id,
                  'job' => "job-#{i}",
                  'index' => i,
                  'state' => 'started'
              }
              instance = Models::Instance.create(instance_params)
            end

            get '/deployments/test_deployment/vms'

            last_response.status.should == 200
            body = Yajl::Parser.parse(last_response.body)
            body.should be_kind_of Array
            body.size.should == 15

            15.times do |i|
              body[i].should == {
                  'agent_id' => "agent-#{i}",
                  'job' => "job-#{i}",
                  'index' => i,
                  'cid' => "cid-#{i}"
              }
            end
          end
        end

        describe 'deleting deployment' do
          it 'deletes the deployment' do
            deployment = Models::Deployment.create(:name => 'test_deployment', :manifest => Psych.dump({'foo' => 'bar'}))

            delete '/deployments/test_deployment'
            expect_redirect_to_queued_task(last_response)
          end
        end

        describe 'deleting release' do
          it 'deletes the whole release' do
            release = Models::Release.create(:name => 'test_release')
            release.add_version(Models::ReleaseVersion.make(:version => '1'))
            release.save

            delete '/releases/test_release'
            expect_redirect_to_queued_task(last_response)
          end

          it 'deletes a particular version' do
            release = Models::Release.create(:name => 'test_release')
            release.add_version(Models::ReleaseVersion.make(:version => '1'))
            release.save

            delete '/releases/test_release?version=1'
            expect_redirect_to_queued_task(last_response)
          end
        end

        describe 'getting release info' do
          it 'returns versions' do
            release = Models::Release.create(:name => 'test_release')
            (1..10).map do |i|
              release.add_version(Models::ReleaseVersion.make(:version => i))
            end
            release.save

            get '/releases/test_release'
            last_response.status.should == 200
            body = Yajl::Parser.parse(last_response.body)

            body['versions'].sort.should == (1..10).map { |i| i.to_s }.sort
          end
        end

        describe 'listing tasks' do
          it 'has API call that returns a list of running tasks' do
            ['queued', 'processing', 'cancelling', 'done'].each do |state|
              (1..20).map { |i| Models::Task.make(
                  :type => :update_deployment,
                  :state => state,
                  :timestamp => Time.now.to_i - i) }
            end
            get '/tasks?state=processing'
            last_response.status.should == 200
            body = Yajl::Parser.parse(last_response.body)
            body.size.should == 20

            get '/tasks?state=processing,cancelling,queued'
            last_response.status.should == 200
            body = Yajl::Parser.parse(last_response.body)
            body.size.should == 60
          end

          it 'has API call that returns a list of recent tasks' do
            ['queued', 'processing'].each do |state|
              (1..20).map { |i| Models::Task.make(
                  :type => :update_deployment,
                  :state => state,
                  :timestamp => Time.now.to_i - i) }
            end
            get '/tasks?limit=20'
            last_response.status.should == 200
            body = Yajl::Parser.parse(last_response.body)
            body.size.should == 20
          end
        end

        describe 'polling task status' do
          it 'has API call that return task status' do
            post '/releases', spec_asset('tarball.tgz'), { 'CONTENT_TYPE' => 'application/x-compressed' }
            new_task_id = last_response.location.match(/\/tasks\/(\d+)/)[1]

            get "/tasks/#{new_task_id}"

            last_response.status.should == 200
            task_json = Yajl::Parser.parse(last_response.body)
            task_json['id'].should == 1
            task_json['state'].should == 'queued'
            task_json['description'].should == 'create release'

            task = Models::Task[new_task_id]
            task.state = 'processed'
            task.save

            get "/tasks/#{new_task_id}"
            last_response.status.should == 200
            task_json = Yajl::Parser.parse(last_response.body)
            task_json['id'].should == 1
            task_json['state'].should == 'processed'
            task_json['description'].should == 'create release'
          end

          it 'has API call that return task output and task output with ranges' do
            post '/releases', spec_asset('tarball.tgz'), { 'CONTENT_TYPE' => 'application/x-compressed' }

            new_task_id = last_response.location.match(/\/tasks\/(\d+)/)[1]

            output_file = File.new(File.join(temp_dir, 'debug'), 'w+')
            output_file.print('Test output')
            output_file.close

            task = Models::Task[new_task_id]
            task.output = temp_dir
            task.save

            get "/tasks/#{new_task_id}/output"
            last_response.status.should == 200
            last_response.body.should == 'Test output'
          end

          it 'has API call that return task output with ranges' do
            post '/releases', spec_asset('tarball.tgz'), { 'CONTENT_TYPE' => 'application/x-compressed' }
            new_task_id = last_response.location.match(/\/tasks\/(\d+)/)[1]

            output_file = File.new(File.join(temp_dir, 'debug'), 'w+')
            output_file.print('Test output')
            output_file.close

            task = Models::Task[new_task_id]
            task.output = temp_dir
            task.save

            # Range test
            get "/tasks/#{new_task_id}/output", {}, {'HTTP_RANGE' => 'bytes=0-3'}
            last_response.status.should == 206
            last_response.body.should == 'Test'
            last_response.headers['Content-Length'].should == '4'
            last_response.headers['Content-Range'].should == 'bytes 0-3/11'

            # Range test
            get "/tasks/#{new_task_id}/output", {}, {'HTTP_RANGE' => 'bytes=5-'}
            last_response.status.should == 206
            last_response.body.should == 'output'
            last_response.headers['Content-Length'].should == '6'
            last_response.headers['Content-Range'].should == 'bytes 5-10/11'
          end

          it 'supports returning different types of output (debug, cpi, event)' do
            %w(debug event cpi).each do |log_type|
              output_file = File.new(File.join(temp_dir, log_type), 'w+')
              output_file.print("Test output #{log_type}")
              output_file.close
            end

            task = Models::Task.new
            task.state = 'done'
            task.type = :update_deployment
            task.timestamp = Time.now.to_i
            task.description = 'description'
            task.output = temp_dir
            task.save

            %w(debug event cpi).each do |log_type|
              get "/tasks/#{task.id}/output?type=#{log_type}"
              last_response.status.should == 200
              last_response.body.should == "Test output #{log_type}"
            end

            # Backward compatibility: when log_type=soap return cpi log
            get "/tasks/#{task.id}/output?type=soap"
            last_response.status.should == 200
            last_response.body.should == 'Test output cpi'

            # Default output is debug
            get "/tasks/#{task.id}/output"
            last_response.status.should == 200
            last_response.body.should == 'Test output debug'
          end

          it 'supports returning old soap logs when type = (cpi || soap)' do
            output_file = File.new(File.join(temp_dir, 'soap'), 'w+')
            output_file.print('Test output soap')
            output_file.close

            task = Models::Task.new
            task.state = 'done'
            task.type = :update_deployment
            task.timestamp = Time.now.to_i
            task.description = 'description'
            task.output = temp_dir
            task.save

            %w(soap cpi).each do |log_type|
              get "/tasks/#{task.id}/output?type=#{log_type}"
              last_response.status.should == 200
              last_response.body.should == 'Test output soap'
            end
          end
        end

        describe 'resources' do
          it '404 on missing resource' do
            get '/resources/deadbeef'
            last_response.status.should == 404
          end

          it 'can fetch resources from blobstore' do
            id = @director_app.blobstores.blobstore.create('some data')
            get "/resources/#{id}"
            last_response.status.should == 200
            last_response.body.should == 'some data'
          end
        end

        describe 'users' do
          let (:username) { 'john' }
          let (:password) { '123' }
          let (:user_data) { {'username' => 'john', 'password' => '123'} }

          it 'creates a user' do
            Models::User.all.size.should == 0

            post '/users', Yajl::Encoder.encode(user_data), { 'CONTENT_TYPE' => 'application/json' }

            new_user = Models::User[:username => username]
            new_user.should_not be_nil
            BCrypt::Password.new(new_user.password).should == password
          end

          it "doesn't create a user with exising username" do
            post '/users', Yajl::Encoder.encode(user_data), { 'CONTENT_TYPE' => 'application/json' }

            login_as(username, password)
            post '/users', Yajl::Encoder.encode(user_data), { 'CONTENT_TYPE' => 'application/json' }

            last_response.status.should == 400
            Models::User.all.size.should == 1
          end

          it 'updates user password but not username' do
            post '/users', Yajl::Encoder.encode(user_data), { 'CONTENT_TYPE' => 'application/json' }

            login_as(username, password)
            new_data = {'username' => username, 'password' => '456'}
            put "/users/#{username}", Yajl::Encoder.encode(new_data), { 'CONTENT_TYPE' => 'application/json' }

            last_response.status.should == 204
            user = Models::User[:username => username]
            BCrypt::Password.new(user.password).should == '456'

            login_as(username, '456')
            change_name = {'username' => 'john2', 'password' => password}
            put "/users/#{username}", Yajl::Encoder.encode(change_name), { 'CONTENT_TYPE' => 'application/json' }
            last_response.status.should == 400
            last_response.body.should ==
                "{\"code\":20001,\"description\":\"The username is immutable\"}"
          end

          it 'deletes user' do
            post '/users', Yajl::Encoder.encode(user_data), { 'CONTENT_TYPE' => 'application/json' }

            login_as(username, password)
            delete "/users/#{username}"

            last_response.status.should == 204

            user = Models::User[:username => username]
            user.should be_nil
          end
        end

        describe 'property management' do

          it 'REST API for creating, updating, getting and deleting ' +
                 'deployment properties' do

            deployment = Models::Deployment.make(:name => 'mycloud')

            get '/deployments/mycloud/properties/foo'
            last_response.status.should == 404

            get '/deployments/othercloud/properties/foo'
            last_response.status.should == 404

            post '/deployments/mycloud/properties', Yajl::Encoder.encode('name' => 'foo', 'value' => 'bar'), { 'CONTENT_TYPE' => 'application/json' }
            last_response.status.should == 204

            get '/deployments/mycloud/properties/foo'
            last_response.status.should == 200
            Yajl::Parser.parse(last_response.body)['value'].should == 'bar'

            get '/deployments/othercloud/properties/foo'
            last_response.status.should == 404

            put '/deployments/mycloud/properties/foo', Yajl::Encoder.encode('value' => 'baz'), { 'CONTENT_TYPE' => 'application/json' }
            last_response.status.should == 204

            get '/deployments/mycloud/properties/foo'
            Yajl::Parser.parse(last_response.body)['value'].should == 'baz'

            delete '/deployments/mycloud/properties/foo'
            last_response.status.should == 204

            get '/deployments/mycloud/properties/foo'
            last_response.status.should == 404
          end
        end

        describe 'problem management' do
          let!(:deployment) { Models::Deployment.make(:name => 'mycloud') }

          it 'exposes problem managent REST API' do
            get '/deployments/mycloud/problems'
            last_response.status.should == 200
            Yajl::Parser.parse(last_response.body).should == []

            post '/deployments/mycloud/scans'
            expect_redirect_to_queued_task(last_response)

            put '/deployments/mycloud/problems', Yajl::Encoder.encode('solutions' => { 42 => 'do_this', 43 => 'do_that', 44 => nil }), { 'CONTENT_TYPE' => 'application/json' }
            expect_redirect_to_queued_task(last_response)

            problem = Models::DeploymentProblem.
                create(:deployment_id => deployment.id, :resource_id => 2,
                       :type => 'test', :state => 'open', :data => {})

            put '/deployments/mycloud/problems', Yajl::Encoder.encode('solution' => 'default'), { 'CONTENT_TYPE' => 'application/json' }
            expect_redirect_to_queued_task(last_response)
          end

          it 'scans and fixes problems' do
            put '/deployments/mycloud/scan_and_fix', Yajl::Encoder.encode('jobs' => { 'job' => [0] }), { 'CONTENT_TYPE' => 'application/json' }
            expect_redirect_to_queued_task(last_response)
          end
        end

        describe 'snapshots' do
          before do
            deployment = Models::Deployment.make(name: 'mycloud')

            instance = Models::Instance.make(deployment: deployment, job: 'job', index: 0)
            disk = Models::PersistentDisk.make(disk_cid: 'disk0', instance: instance, active: true)
            Models::Snapshot.make(persistent_disk: disk, snapshot_cid: 'snap0a')

            instance = Models::Instance.make(deployment: deployment, job: 'job', index: 1)
            disk = Models::PersistentDisk.make(disk_cid: 'disk1', instance: instance, active: true)
            Models::Snapshot.make(persistent_disk: disk, snapshot_cid: 'snap1a')
            Models::Snapshot.make(persistent_disk: disk, snapshot_cid: 'snap1b')
          end

          describe 'creating' do
            it 'should create a snapshot for a job' do
              post '/deployments/mycloud/jobs/job/1/snapshots'
              expect_redirect_to_queued_task(last_response)
            end

            it 'should create a snapshot for a deployment' do
              post '/deployments/mycloud/snapshots'
              expect_redirect_to_queued_task(last_response)
            end
          end

          describe 'deleting' do
            it 'should delete all snapshots of a deployment' do
              delete '/deployments/mycloud/snapshots'
              expect_redirect_to_queued_task(last_response)
            end

            it 'should delete a snapshot' do
              delete '/deployments/mycloud/snapshots/snap1a'
              expect_redirect_to_queued_task(last_response)
            end

            it 'should raise an error if the snapshot belongs to a different deployment' do
              snap = Models::Snapshot.make(snapshot_cid: 'snap2b')
              delete "/deployments/#{snap.persistent_disk.instance.deployment.name}/snapshots/snap2a"
              last_response.status.should == 400
            end
          end

          describe 'listing' do
            it 'should list all snapshots for a job' do
              get '/deployments/mycloud/jobs/job/0/snapshots'
              last_response.status.should == 200
            end

            it 'should list all snapshots for a deployment' do
              get '/deployments/mycloud/snapshots'
              last_response.status.should == 200
            end
          end

          describe 'backup' do
            describe 'creating' do
              it 'returns a successful response' do
                post '/backups'
                expect_redirect_to_queued_task(last_response)
              end
            end

            describe 'fetching' do
              it 'returns the backup tarball' do
                Dir.mktmpdir do |temp|
                  backup_file = File.join(temp, 'backup.tgz')
                  FileUtils.touch(backup_file)
                  BackupManager.any_instance.stub(destination_path: backup_file)

                  get '/backups'
                  expect(last_response.status).to eq 200
                end
              end

              it 'returns file not found for missing tarball' do
                get '/backups'
                expect(last_response.status).to eq 404
              end
            end
          end
        end
      end
    end
  end
end
