require 'active_support/core_ext/array'
require 'active_support/core_ext/string/inflections'

module Pod
  # Validates a Specification.
  #
  # Extends the Linter from the Core to add additional which require the
  # LocalPod and the Installer.
  #
  # In detail it checks that the file patterns defined by the user match
  # actually do match at least a file and that the Pod builds, by installing
  # it without integration and building the project with xcodebuild.
  #
  class Builder
    include Config::Mixin

    # The default version of Swift to use when linting pods
    #
    DEFAULT_SWIFT_VERSION = '3.2'.freeze

    # The valid platforms for linting
    #
    VALID_PLATFORMS = Platform.all.freeze

    # @return [Specification] the specification to lint.
    #
    attr_reader :spec

    # @return [Pathname] the path of the `podspec` file where {#spec} is
    #         defined.
    #
    attr_reader :file

    # Initialize a new instance
    #
    # @param  [Specification, Pathname, String] spec_or_path
    #         the Specification or the path of the `podspec` file to lint.
    #
    # @param  [Array<String>] source_urls
    #         the Source URLs to use in creating a {Podfile}.
    #
    # @param. [Array<String>] platforms
    #         the platforms to lint.
    #
    def initialize(spec_or_path, source_urls, platforms = [])
      if spec_or_path.is_a?(Specification)
        @spec = spec_or_path
        @file = @spec.defined_in_file
      else
        @file = Pathname.new(spec_or_path)
        begin
          @spec = Specification.from_file(@file)
        rescue => e
          @spec = nil
          @raise_message = e.message
        end
      end

      @source_urls = if @spec && @spec.dependencies.empty? && @spec.recursive_subspecs.all? { |s| s.dependencies.empty? }
                       []
                     else
                       source_urls.map { |url| config.sources_manager.source_with_name_or_url(url) }.map(&:url)
                     end

      @platforms = platforms.map do |platform|
        result =  case platform.to_s.downcase
                    # Platform doesn't recognize 'macos' as being the same as 'osx' when initializing
                  when 'macos' then Platform.macos
                  else Platform.new(platform, nil)
                  end
        unless valid_platform?(result)
          raise Informative, "Unrecognized platform `#{platform}`. Valid platforms: #{VALID_PLATFORMS.join(', ')}"
        end
        result
      end
    end

    #-------------------------------------------------------------------------#

    # Returns a list of platforms to lint for a given Specification
    #
    # @param [Specification] spec
    #         The specification to lint
    #
    # @return [Array<Platform>] platforms to lint for the given specification
    #
    def platforms_to_build(spec)
      return spec.available_platforms if @platforms.empty?

      # Validate that the platforms specified are actually supported by the spec
      results = @platforms.map do |platform|
        matching_platform = spec.available_platforms.find { |p| p.name == platform.name }
        unless matching_platform
          raise Informative, "Platform `#{platform}` is not supported by specification `#{spec}`."
        end
        matching_platform
      end.uniq

      results
    end

    # @return [Sandbox::FileAccessor] the file accessor for the spec.
    #
    attr_accessor :file_accessor

    #-------------------------------------------------------------------------#

    # Lints the specification adding a {Result} for any
    # failed check to the {#results} list.
    #
    # @note   This method shows immediately which pod is being processed and
    #         overrides the printed line once the result is known.
    #
    # @return [Bool] whether the specification passed validation.
    #
    def build
      @results = []

      # Replace default spec with a subspec if asked for
      a_spec = @spec
      if @spec && @only_subspec
        subspec_name = @only_subspec.start_with?(@spec.root.name) ? @only_subspec : "#{@spec.root.name}/#{@only_subspec}"
        a_spec = @spec.subspec_by_name(subspec_name, true, true)
        @subspec_name = a_spec.name
      end

      unless a_spec
        raise Informative, "Specification `#{@spec}` not found"
      end

      UI.print " -> #{a_spec.name}\r" unless config.silent?
      $stdout.flush

      build_spec(a_spec)

      UI.puts ' -> '.send(result_color) << (a_spec.to_s)
      print_results
      success?
    end

    # Prints the result of the validation to the user.
    #
    # @return [void]
    #
    def print_results
      UI.puts results_message
    end

    def results_message
      message = ''
      results.each do |result|
        if result.platforms == [:ios]
          platform_message = '[iOS] '
        elsif result.platforms == [:osx]
          platform_message = '[OSX] '
        elsif result.platforms == [:watchos]
          platform_message = '[watchOS] '
        elsif result.platforms == [:tvos]
          platform_message = '[tvOS] '
        end

        subspecs_message = ''
        if result.is_a?(Result)
          subspecs = result.subspecs.uniq
          if subspecs.count > 2
            subspecs_message = '[' + subspecs[0..2].join(', ') + ', and more...] '
          elsif subspecs.count > 0
            subspecs_message = '[' + subspecs.join(',') + '] '
          end
        end

        case result.type
        when :error   then type = 'ERROR'
        when :warning then type = 'WARN'
        when :note    then type = 'NOTE'
        else raise "#{result.type}" end
        message << "    - #{type.ljust(5)} | #{platform_message}#{subspecs_message}#{result.attribute_name}: #{result.message}\n"
      end
      message << "\n"
    end

    def failure_reason
      results_by_type = results.group_by(&:type)
      results_by_type.default = []
      return nil if success?
      reasons = []
      if (size = results_by_type[:error].size) && size > 0
        reasons << "#{size} #{'error'.pluralize(size)}"
      end
      if !allow_warnings && (size = results_by_type[:warning].size) && size > 0
        reason = "#{size} #{'warning'.pluralize(size)}"
        pronoun = size == 1 ? 'it' : 'them'
        reason << " (but you can use `--allow-warnings` to ignore #{pronoun})" if reasons.empty?
        reasons << reason
      end
      if results.all?(&:public_only)
        reasons << 'all results apply only to public specs, but you can use ' \
                   '`--private` to ignore them if linting the specification for a private pod'
      end

      reasons.to_sentence
    end

    #-------------------------------------------------------------------------#

    #  @!group Configuration

    # @return [Bool] whether the linter should not clean up temporary files
    #         for inspection.
    #
    attr_accessor :no_clean

    # @return [Bool] whether the linter should fail as soon as the first build
    #         variant causes an error. Helpful for i.e. multi-platforms specs,
    #         specs with subspecs.
    #
    attr_accessor :fail_fast

    # @return [Bool] whether the validation should be performed against the root of
    #         the podspec instead to its original source.
    #
    # @note   Uses the `:path` option of the Podfile.
    #
    attr_accessor :local
    alias_method :local?, :local

    # @return [Bool] Whether the validator should fail on warnings, or only on errors.
    #
    attr_accessor :allow_warnings

    # @return [String] name of the subspec to check, if nil all subspecs are checked.
    #
    attr_accessor :only_subspec

    # @return [Bool] Whether the validator should validate all subspecs.
    #
    attr_accessor :no_subspecs

    # @return [Bool] Whether the validator should skip building and running tests.
    #
    attr_accessor :skip_tests

    # @return [Bool] Whether frameworks should be used for the installation.
    #
    attr_accessor :use_frameworks

    # @return [Boolean] Whether modular headers should be used for the installation.
    #
    attr_accessor :use_modular_headers

    # @return [Boolean] Whether attributes that affect only public sources
    #         Bool be skipped.
    #
    attr_accessor :ignore_public_only_results

    attr_accessor :skip_import_validation
    alias_method :skip_import_validation?, :skip_import_validation

    #-------------------------------------------------------------------------#

    # !@group Lint results

    #
    #
    attr_reader :results

    # @return [Boolean]
    #
    def success?
      result_type != :error && (result_type != :warning || allow_warnings)
    end

    # @return [Symbol] The type, which should been used to display the result.
    #         One of: `:error`, `:warning`, `:note`.
    #
    def result_type
      applicable_results = results
      applicable_results = applicable_results.reject(&:public_only?) if ignore_public_only_results
      types              = applicable_results.map(&:type).uniq
      if    types.include?(:error)   then :error
      elsif types.include?(:warning) then :warning
      else  :note
      end
    end

    # @return [Symbol] The color, which should been used to display the result.
    #         One of: `:green`, `:yellow`, `:red`.
    #
    def result_color
      case result_type
      when :error   then :red
      when :warning then :yellow
      else :green end
    end

    # @return [Pathname] the temporary directory used by the linter.
    #
    def build_dir
      @build_dir ||= Pathname(Dir.mktmpdir(['CocoaPods-Build-', "-#{spec.name}"]))
    end

    # @return [String] the SWIFT_VERSION to use for validation.
    #
    def swift_version
      return @swift_version unless @swift_version.nil?
      if (version = @spec.swift_version)
        @swift_version = version.to_s
      else
        DEFAULT_SWIFT_VERSION
      end
    end

    # @return [Boolean] Whether any of the pod targets part of this validator use Swift or not.
    #
    def uses_swift?
      @installer.pod_targets.any?(&:uses_swift?)
    end

    #-------------------------------------------------------------------------#

    private

    # !@group Lint steps

    # Perform analysis for a given spec (or subspec)
    #
    def build_spec(spec)
      if spec.test_specification?
        error('spec', "Building a test spec (`#{spec.name}`) is not supported.")
        return false
      end

      platforms = platforms_to_build(spec)

      valid = platforms.send(fail_fast ? :all? : :each) do |platform|
        UI.message "\n\n#{spec} - Building #{platform} platform.".green.reversed
        @consumer = spec.consumer(platform)
        setup_build_environment
        begin
          create_app_project
          download_pod
          install_pod
          add_app_project_import
          build_pod
          test_pod unless skip_tests
        ensure
          tear_down_build_environment
        end
        success?
      end
      return false if fail_fast && !valid
      build_subspecs(spec) unless @no_subspecs
    rescue => e
      message = e.to_s
      message << "\n" << e.backtrace.join("\n") << "\n" if config.verbose?
      error('unknown', "Encountered an unknown error (#{message}) during validation.")
      false
    end

    # Recursively perform the extensive analysis on all subspecs
    #
    def build_subspecs(spec)
      spec.subspecs.reject(&:test_specification?).send(fail_fast ? :all? : :each) do |subspec|
        @subspec_name = subspec.name
        build_spec(subspec)
      end
    end

    attr_accessor :consumer
    attr_accessor :subspec_name

    def setup_build_environment
      build_dir.rmtree if build_dir.exist?
      build_dir.mkpath
      @original_config = Config.instance.clone
      config.installation_root   = build_dir
      config.silent              = !config.verbose
    end

    def tear_down_build_environment
      build_dir.rmtree unless no_clean
      Config.instance = @original_config
    end

    def deployment_target
      deployment_target = @spec.subspec_by_name(subspec_name).deployment_target(consumer.platform_name)
      if consumer.platform_name == :ios && use_frameworks
        minimum = Version.new('8.0')
        deployment_target = [Version.new(deployment_target), minimum].max.to_s
      end
      deployment_target
    end

    def download_pod
      podfile = podfile_from_spec(consumer.platform_name, deployment_target, use_frameworks, consumer.spec.test_specs.map(&:name), use_modular_headers)
      sandbox = Sandbox.new(config.sandbox_root)
      @installer = Installer.new(sandbox, podfile)
      @installer.use_default_plugins = false
      @installer.has_dependencies = !spec.dependencies.empty?
      %i(prepare resolve_dependencies download_dependencies).each { |m| @installer.send(m) }
      @file_accessor = @installer.pod_targets.flat_map(&:file_accessors).find { |fa| fa.spec.name == consumer.spec.name }
    end

    def create_app_project
      app_project = Xcodeproj::Project.new(build_dir + 'App.xcodeproj')
      app_target = Pod::Generator::AppTargetHelper.add_app_target(app_project, consumer.platform_name, deployment_target)
      Pod::Generator::AppTargetHelper.add_swift_version(app_target, swift_version)
      app_project.save
      app_project.recreate_user_schemes
    end

    def add_app_project_import
      app_project = Xcodeproj::Project.open(build_dir + 'App.xcodeproj')
      app_target = app_project.targets.first
      pod_target = @installer.pod_targets.find { |pt| pt.pod_name == @spec.root.name }
      Pod::Generator::AppTargetHelper.add_app_project_import(app_project, app_target, pod_target, consumer.platform_name)
      Pod::Generator::AppTargetHelper.add_xctest_search_paths(app_target) if @installer.pod_targets.any? { |pt| pt.spec_consumers.any? { |c| c.frameworks.include?('XCTest') } }
      Pod::Generator::AppTargetHelper.add_empty_swift_file(app_project, app_target) if @installer.pod_targets.any?(&:uses_swift?)
      app_project.save
      Xcodeproj::XCScheme.share_scheme(app_project.path, 'App')
      # Share the pods xcscheme only if it exists. For pre-built vendored pods there is no xcscheme generated.
      Xcodeproj::XCScheme.share_scheme(@installer.pods_project.path, pod_target.label) if shares_pod_target_xcscheme?(pod_target)
    end

    # It creates a podfile in memory and builds a library containing the pod
    # for all available platforms with xcodebuild.
    #
    def install_pod
      %i(validate_targets generate_pods_project integrate_user_project
         perform_post_install_actions).each { |m| @installer.send(m) }

      deployment_target = @spec.subspec_by_name(subspec_name).deployment_target(consumer.platform_name)
      configure_pod_targets(@installer.aggregate_targets, @installer.target_installation_results, deployment_target)
      @installer.pods_project.save
    end

    def configure_pod_targets(targets, target_installation_results, deployment_target)
      target_installation_results.first.values.each do |pod_target_installation_result|
        pod_target = pod_target_installation_result.target
        native_target = pod_target_installation_result.native_target
        native_target.build_configuration_list.build_configurations.each do |build_configuration|
          (build_configuration.build_settings['OTHER_CFLAGS'] ||= '$(inherited)') << ' -Wincomplete-umbrella'
          build_configuration.build_settings['SWIFT_VERSION'] = (pod_target.swift_version || swift_version) if pod_target.uses_swift?
        end
        pod_target_installation_result.test_specs_by_native_target.each do |test_native_target, test_specs|
          if pod_target.uses_swift_for_test_spec?(test_specs.first)
            test_native_target.build_configuration_list.build_configurations.each do |build_configuration|
              build_configuration.build_settings['SWIFT_VERSION'] = swift_version
            end
          end
        end
      end
      targets.each do |target|
        if target.pod_targets.any?(&:uses_swift?) && consumer.platform_name == :ios &&
            (deployment_target.nil? || Version.new(deployment_target).major < 8)
          uses_xctest = target.spec_consumers.any? { |c| (c.frameworks + c.weak_frameworks).include? 'XCTest' }
          error('swift', 'Swift support uses dynamic frameworks and is therefore only supported on iOS > 8.') unless uses_xctest
        end
      end
    end

    # Performs platform specific analysis. It requires to download the source
    # at each iteration
    #
    # @note   Xcode warnings are treated as notes because the spec maintainer
    #         might not be the author of the library
    #
    # @return [void]
    #
    def build_pod
      build_with_options('Release', true)
      build_with_options('Debug', true)
      build_with_options('Release', false)
      build_with_options('Debug', false)
    end

    def build_with_options(configuration, for_simulator)
      if !xcodebuild_available?
        UI.warn "Skipping compilation with `xcodebuild` because it can't be found.\n".yellow
      else
        UI.message "\nBuilding configuration '#{configuration}' with `xcodebuild`#{' for simulator' if for_simulator}.\n".yellow do
          pod_target = @installer.pod_targets.find { |pt| pt.pod_name == @spec.root.name }
          scheme = pod_target.label if pod_target.should_build?
          if scheme.nil?
            UI.warn "Skipping compilation with `xcodebuild` because target contains no sources.\n".yellow
          else
            output = xcodebuild('build', scheme, configuration, for_simulator, true)
            parsed_output = parse_xcodebuild_output(output)
            translate_output_to_linter_messages(parsed_output)
          end
        end
      end
    end

    # Builds and runs all test sources associated with the current specification being validated.
    #
    # @note   Xcode warnings are treated as notes because the spec maintainer
    #         might not be the author of the library
    #
    # @return [void]
    #
    def test_pod
      if !xcodebuild_available?
        UI.warn "Skipping test validation with `xcodebuild` because it can't be found.\n".yellow
      else
        UI.message "\nTesting with `xcodebuild`.\n".yellow do
          pod_target = @installer.pod_targets.find { |pt| pt.pod_name == @spec.root.name }
          consumer.spec.test_specs.each do |test_spec|
            scheme = @installer.target_installation_results.first[pod_target.name].native_target_for_spec(test_spec)
            output = xcodebuild('test', scheme, 'Debug', true, false)
            parsed_output = parse_xcodebuild_output(output)
            translate_output_to_linter_messages(parsed_output)
          end
        end
      end
    end

    def xcodebuild_available?
      !Executable.which('xcodebuild').nil? && ENV['COCOAPODS_VALIDATOR_SKIP_XCODEBUILD'].nil?
    end

    #-------------------------------------------------------------------------#

    private

    # !@group Result Helpers

    def error(*args)
      add_result(:error, *args)
    end

    def warning(*args)
      add_result(:warning, *args)
    end

    def note(*args)
      add_result(:note, *args)
    end

    def translate_output_to_linter_messages(parsed_output)
      parsed_output.each do |message|
        # Checking the error for `InputFile` is to work around an Xcode
        # issue where linting would fail even though `xcodebuild` actually
        # succeeds. Xcode.app also doesn't fail when this issue occurs, so
        # it's safe for us to do the same.
        #
        # For more details see https://github.com/CocoaPods/CocoaPods/issues/2394#issuecomment-56658587
        #
        if message.include?("'InputFile' should have")
          next
        end

        if message =~ /\S+:\d+:\d+: error:/
          error('xcodebuild', message)
        elsif message =~ /\S+:\d+:\d+: warning:/
          warning('xcodebuild', message)
        else
          note('xcodebuild', message)
        end
      end
    end

    def shares_pod_target_xcscheme?(pod_target)
      scheme_path = Xcodeproj::XCScheme.user_data_dir(@installer.pods_project.path) + "#{pod_target.label}.xcscheme"
      File.exists?(scheme_path)
    end

    def add_result(type, attribute_name, message, public_only = false)
      result = results.find do |r|
        r.type == type && r.attribute_name && r.message == message && r.public_only? == public_only
      end
      unless result
        result = Result.new(type, attribute_name, message, public_only)
        results << result
      end
      result.platforms << consumer.platform_name if consumer
      result.subspecs << subspec_name if subspec_name && !result.subspecs.include?(subspec_name)
    end

    # Specialized Result to support subspecs aggregation
    #
    class Result < Specification::Linter::Results::Result
      def initialize(type, attribute_name, message, public_only = false)
        super(type, attribute_name, message, public_only)
        @subspecs = []
      end

      attr_reader :subspecs
    end

    #-------------------------------------------------------------------------#

    private

    # !@group Helpers

    # @return [Array<String>] an array of source URLs used to create the
    #         {Podfile} used in the linting process
    #
    attr_reader :source_urls

    # @param  [String] platform_name
    #         the name of the platform, which should be declared
    #         in the Podfile.
    #
    # @param  [String] deployment_target
    #         the deployment target, which should be declared in
    #         the Podfile.
    #
    # @param  [Bool] use_frameworks
    #         whether frameworks should be used for the installation
    #
    # @param [Array<String>] test_spec_names
    #         the test spec names to include in the podfile.
    #
    # @return [Podfile] a podfile that requires the specification on the
    #         current platform.
    #
    # @note   The generated podfile takes into account whether the linter is
    #         in local mode.
    #
    def podfile_from_spec(platform_name, deployment_target, use_frameworks = true, test_spec_names = [], use_modular_headers = false)
      name     = subspec_name || @spec.name
      podspec  = @file.realpath
      local    = local?
      urls     = source_urls
      Pod::Podfile.new do
        install! 'cocoapods', :deterministic_uuids => false
        # By default inhibit warnings for all pods, except the one being validated.
        inhibit_all_warnings!
        urls.each { |u| source(u) }
        target 'App' do
          use_frameworks!(use_frameworks)
          use_modular_headers! if use_modular_headers
          platform(platform_name, deployment_target)
          if local
            pod name, :path => podspec.dirname.to_s, :inhibit_warnings => false
          else
            pod name, :podspec => podspec.to_s, :inhibit_warnings => false
          end
          test_spec_names.each do |test_spec_name|
            if local
              pod test_spec_name, :path => podspec.dirname.to_s, :inhibit_warnings => false
            else
              pod test_spec_name, :podspec => podspec.to_s, :inhibit_warnings => false
            end
          end
        end
      end
    end

    # Parse the xcode build output to identify the lines which are relevant
    # to the linter.
    #
    # @param  [String] output the output generated by the xcodebuild tool.
    #
    # @note   The indentation and the temporary path is stripped form the
    #         lines.
    #
    # @return [Array<String>] the lines that are relevant to the linter.
    #
    def parse_xcodebuild_output(output)
      lines = output.split("\n")
      selected_lines = lines.select do |l|
        l.include?('error: ') && (l !~ /errors? generated\./) && (l !~ /error: \(null\)/) ||
            l.include?('warning: ') && (l !~ /warnings? generated\./) && (l !~ /frameworks only run on iOS 8/) ||
            l.include?('note: ') && (l !~ /expanded from macro/)
      end
      selected_lines.map do |l|
        new = l.gsub(%r{#{build_dir}/Pods/}, '')
        new.gsub!(/^ */, ' ')
      end
    end

    # @return [String] Executes xcodebuild in the current working directory and
    #         returns its output (both STDOUT and STDERR).
    #
    def xcodebuild(action, scheme, configuration, for_simulator, copy_framework)
      require 'fourflusher'
      derivedDataPath = File.join(build_dir, 'DerivedData')
      command = %W(clean #{action} -workspace #{File.join(build_dir, 'App.xcworkspace')} -scheme #{scheme} -configuration #{configuration})
      command += %W(-derivedDataPath #{derivedDataPath})
      command += %w(ONLY_ACTIVE_ARCH=NO)
      command += %w(CODE_SIGNING_REQUIRED=NO)
      command += %w(CODE_SIGN_IDENTITY=)
      command += %w(SKIP_INSTALL=YES)
      command += %w(GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO)
      command += %w(CLANG_ENABLE_CODE_COVERAGE=NO)
      command += %w(STRIP_INSTALLED_PRODUCT=NO)
      case consumer.platform_name
      when :mac
        build_platform_dir = "macosx"
      when :ios
        if for_simulator
          simulator_name = "iphonesimulator"
          simulator_os = "iOS"
          build_platform_dir = simulator_name
        else
          build_platform_dir = "iphoneos"
        end
      when :watchos
        if for_simulator
          simulator_name = "watchsimulator"
          simulator_os = "watchOS"
          build_platform_dir = simulator_name
        else
          build_platform_dir = "watchos"
        end
      when :tvos
        if for_simulator
          simulator_name = "appletvsimulator"
          simulator_os = "tvOS"
          build_platform_dir = simulator_name
        else
          build_platform_dir = "appletvos"
        end
      end

      if for_simulator
        command += %W(-sdk #{simulator_name})
        command += Fourflusher::SimControl.new.destination(:oldest, simulator_os, deployment_target)
      end

      begin
        output = _xcodebuild(command, true)
      rescue => e
        message = 'Returned an unsuccessful exit code.'
        message += ' You can use `--verbose` for more information.' unless config.verbose?
        error('xcodebuild', message)
        e.message
      end

      if copy_framework
        built_pod_dir = Pathname.new(Pathname.pwd).join('BuiltPods', "#{configuration}-#{build_platform_dir}")
        src_dir = Pathname.new(derivedDataPath).join('Build', 'Products', "#{configuration}-#{build_platform_dir}", scheme)
        FileUtils.mkdir_p(built_pod_dir)
        FileUtils.cp_r(src_dir, built_pod_dir)
      end

      output
    end

    # Executes the given command in the current working directory.
    #
    # @return [String] The output of the given command
    #
    def _xcodebuild(command, raise_on_failure = false)
      Executable.execute_command('xcodebuild', command, raise_on_failure)
    end

    # Whether the platform with the specified name is valid
    #
    # @param  [Platform] platform
    #         The platform to check
    #
    # @return [Bool] True if the platform is valid
    #
    def valid_platform?(platform)
      VALID_PLATFORMS.any? { |p| p.name == platform.name }
    end

    # Whether the platform is supported by the specification
    #
    # @param  [Platform] platform
    #         The platform to check
    #
    # @param  [Specification] specification
    #         The specification which must support the provided platform
    #
    # @return [Bool] Whether the platform is supported by the specification
    #
    def supported_platform?(platform, spec)
      available_platforms = spec.available_platforms

      available_platforms.any? { |p| p.name == platform.name }
    end

    # Whether the provided name matches the platform
    #
    # @param  [Platform] platform
    #         The platform
    #
    # @param  [String] name
    #         The name to check against the provided platform
    #
    def platform_name_match?(platform, name)
      [platform.name, platform.string_name].any? { |n| n.casecmp(name) == 0 }
    end

    #-------------------------------------------------------------------------#
  end
end
