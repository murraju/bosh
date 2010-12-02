require "yaml"

module Bosh
  module Cli

    class Runner

      CONFIG_PATH = File.expand_path("~/.bosh_config")

      def self.run(cmd, output, *args)
        new(cmd, output, *args).run
      end

      def initialize(cmd, output, *args)
        @cmd      = cmd
        @args     = args
        @out      = output
        @work_dir = Dir.pwd

        if logged_in?
          @api_client = ApiClient.new(config["target"], credentials["username"], credentials["password"])
        end
      end

      def run
        method   = find_cmd_implementation
        expected = method.arity

        if expected >= 0 && @args.size != expected
          raise ArgumentError, "wrong number of arguments for #{self.class.name}##{method.name} (#{@args.size} for #{expected})"
        end

        method.call(*@args)
      end

      def cmd_status
        say("Target:     %s" % [ config['target'] || "not set" ])
        say("User:       %s" % [ credentials && credentials["username"] || "not set" ])
        say("Deployment: %s" % [ config['deployment'] || "not set" ])
      end

      def cmd_set_target(name)
        config['target'] = name

        if config['deployment']
          deployment = Deployment.new(@work_dir, config['deployment'])
          if !deployment.manifest_exists? || deployment.target != name
            say("WARNING! Your deployment has been unset")
            config['deployment'] = nil
          end
        end
        
        save_config
        say("Target set to '%s'" % [ name ])
      end

      def cmd_show_target
        if config['target']
          say("Current target is %s" % [ config['target'] ] )
        else
          say("Target not set")
        end
      end

      def cmd_set_deployment(name)
        deployment = Deployment.new(@work_dir, name)

        if deployment.manifest_exists?
          config['deployment'] = name

          if deployment.target != config['target']
            config['target'] = deployment.target
            say("WARNING! Your target has been changed to '%s'" % [ deployment.target ])
          end

          say("Deployment set to '%s'" % [ name ])
          config['deployment'] = name
          save_config          
        else
          say("Cannot find deployment '%s'" % [ deployment.path ])
          cmd_list_deployments
        end        
      end

      def cmd_list_deployments
        deployments = Deployment.all(@work_dir)

        if deployments.size > 0
          say("Available deployments are:")

          for deployment in Deployment.all(@work_dir)
            say("  %s" % [ deployment.name ])
          end
        else
          say("No deployments available")
        end        
      end

      def cmd_show_deployment
        if config['deployment']
          say("Current deployment is %s" % [ config['deployment'] ] )
        else
          say("Deployment not set")
        end
      end

      def cmd_login(username, password)
        if config["target"].nil?
          say("Please choose target first")
          return
        end

        all_configs["auth"] ||= {}
        all_configs["auth"][config["target"]] = { "username" => username, "password" => password }
        save_config
        
        say("Saved credentials for %s" % [ username ])
      end

      def cmd_create_user(username, password)
        if !logged_in?
          say("Please login first")
          return
        end

        created, message = User.create(@api_client, username, password)
        say(message)
      end

      def cmd_verify_stemcell(tarball_path)
        stemcell = Stemcell.new(tarball_path)

        say("\nVerifying stemcell...")
        stemcell.validate do |name, passed|
          say("%-60s %s" % [ name, passed ? "OK" : "FAILED" ])
        end
        say("\n")        

        if stemcell.valid?
          say("'%s' is a valid stemcell" % [ tarball_path] )
        else
          say("'%s' is not a valid stemcell:" % [ tarball_path] )
          for error in stemcell.errors
            say("- %s" % [ error ])
          end
        end        
      end

      def cmd_upload_stemcell(tarball_path)
        if !logged_in?
          say("Please login first")
          return
        end

        say("\nUploading stemcell...\n")
        stemcell = Stemcell.new(tarball_path)

        uploaded, message = stemcell.upload(@api_client) do |poll_number, status|
          if poll_number % 10 == 0
            ts = Time.now.strftime("%H:%M:%S")
            say("[#{ts}] Stemcell creation job status is '#{status}' (#{poll_number} polls)...")
          end
        end

        if uploaded
          say("Stemcell uploaded and updated")
        else
          say(message)
        end        
      end

      def cmd_verify_release(tarball_path)
        release = Release.new(tarball_path)

        say("\nVerifying release...")
        release.validate do |name, passed|
          say("%-60s %s" % [ name, passed ? "OK" : "FAILED" ])
        end
        say("\n")        

        if release.valid?
          say("'%s' is a valid release" % [ tarball_path] )
        else
          say("'%s' is not a valid release:" % [ tarball_path] )
          for error in release.errors
            say("- %s" % [ error ])
          end
        end
      end

      def cmd_upload_release(tarball_path)
        if !logged_in?
          say("Please login first")
          return
        end

        say("\nUploading release...\n")        
        release = Release.new(tarball_path)

        uploaded, message = release.upload(@api_client) do |poll_number, status|
          if poll_number % 10 == 0
            ts = Time.now.strftime("%H:%M:%S")
            say("[#{ts}] Release update job status is '#{status}' (#{poll_number} polls)...")
          end
        end

        if uploaded
          say("Release uploaded and updated")
        else
          say(message)
        end
        
      end

      def cmd_deploy
        say("Deploying...")
        sleep(0.5)
        say("Deploy OK.")
      end

      private

      def say(message)
        @out.puts(message)
      end

      def config
        @config ||= all_configs[@work_dir] || {}
      end

      def save_config
        all_configs[@work_dir] = config
        
        File.open(CONFIG_PATH, "w") do |f|
          YAML.dump(all_configs, f)
        end
        
      rescue SystemCallError => e
        raise ConfigError, "Cannot save config: %s" % [ e.message ]
      end

      def all_configs
        return @_all_configs unless @_all_configs.nil?
        
        unless File.exists?(CONFIG_PATH)
          File.open(CONFIG_PATH, "w") { |f| YAML.dump({}, f) }
          File.chmod(0600, CONFIG_PATH)
        end

        configs = YAML.load_file(CONFIG_PATH)

        unless configs.is_a?(Hash)
          raise ConfigError, "Malformed config file: %s" % [ CONFIG_PATH ]
        end

        @_all_configs = configs

      rescue SystemCallError => e
        raise ConfigError, "Cannot read config file: %s" % [ e.message ]        
      end

      def credentials
        if config["target"].nil? || all_configs["auth"].nil? || all_configs["auth"][config["target"]].nil?
          nil
        else
          all_configs["auth"][config["target"]]
        end
      end

      def logged_in?
        !credentials.nil?
      end

      def find_cmd_implementation
        begin
          self.method("cmd_%s" % [ @cmd ])
        rescue NameError
          raise UnknownCommand, "unknown command '%s'" % [ @cmd ]
        end
      end
      
    end
    
  end
end
