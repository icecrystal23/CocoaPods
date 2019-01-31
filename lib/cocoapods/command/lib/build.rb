module Pod
  class Command
    class Lib < Command
      class Build < Lib
        self.summary = 'Builds a Pod'

        self.description = <<-DESC
          Compiles the Pod using the files in the working directory.
        DESC

        def self.options
          [
              ['--allow-warnings', 'Build succeeds even if warnings are present'],
              ['--subspec=NAME', 'Build only the given subspec'],
              ['--no-subspecs', 'Build skips subspecs'],
              ['--no-clean', 'Build leaves the build directory intact for inspection'],
              ['--fail-fast', 'Build stops on the first failing platform or subspec'],
              ['--use-libraries', 'Build uses static libraries to install the spec'],
              ['--use-modular-headers', 'Build uses modular headers during installation'],
              ['--sources=https://github.com/artsy/Specs,master', 'The sources from which to pull dependent pods ' \
             '(defaults to https://github.com/CocoaPods/Specs.git). ' \
             'Multiple sources must be comma-delimited.'],
              ['--platforms=ios,macos', 'Build against specific platforms' \
              '(defaults to all platforms supported by the podspec).' \
              'Multiple platforms must be comma-delimited'],
              ['--skip-tests', 'Build skips building and running tests'],
          ].concat(super)
        end

        def initialize(argv)
          @allow_warnings  = argv.flag?('allow-warnings')
          @clean           = argv.flag?('clean', true)
          @fail_fast       = argv.flag?('fail-fast', false)
          @subspecs        = argv.flag?('subspecs', true)
          @only_subspec    = argv.option('subspec')
          @use_frameworks  = !argv.flag?('use-libraries')
          @use_modular_headers = argv.flag?('use-modular-headers')
          @source_urls     = argv.option('sources', 'https://github.com/CocoaPods/Specs.git').split(',')
          @platforms       = argv.option('platforms', '').split(',')
          @skip_tests      = argv.flag?('skip-tests', false)
          @podspecs_paths  = argv.arguments!
          super
        end

        def validate!
          super
        end

        def run
          UI.puts
          podspecs_to_build.each do |podspec|
            builder                = Builder.new(podspec, @source_urls, @platforms)
            builder.local          = true
            builder.no_clean       = !@clean
            builder.fail_fast      = @fail_fast
            builder.allow_warnings = @allow_warnings
            builder.no_subspecs    = !@subspecs || @only_subspec
            builder.only_subspec   = @only_subspec
            builder.use_frameworks = @use_frameworks
            builder.use_modular_headers = @use_modular_headers
            builder.skip_tests = @skip_tests
            builder.build

            unless @clean
              UI.puts "Pods workspace available at `#{builder.build_dir}/App.xcworkspace` for inspection."
              UI.puts
            end
            if builder.success?
              UI.puts "#{builder.spec.name} passed built.".green
            else
              spec_name = podspec
              spec_name = builder.spec.name if builder.spec
              message = "#{spec_name} could not build, due to #{builder.failure_reason}."

              if @clean
                message << "\nYou can use the `--no-clean` option to inspect " \
                  'any issue.'
              end
              raise Informative, message
            end
          end
        end

        private

        #----------------------------------------#

        # !@group Private helpers

        # @return [Pathname] The path of the podspec found in the current
        #         working directory.
        #
        # @raise  If no podspec is found.
        # @raise  If multiple podspecs are found.
        #
        def podspecs_to_build
          if !@podspecs_paths.empty?
            Array(@podspecs_paths)
          else
            podspecs = Pathname.glob(Pathname.pwd + '*.podspec{.json,}')
            if podspecs.count.zero?
              raise Informative, 'Unable to find a podspec in the working ' \
                'directory'
            end
            podspecs
          end
        end
      end
    end
  end
end
