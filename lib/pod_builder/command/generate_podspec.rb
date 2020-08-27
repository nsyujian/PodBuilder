require 'pod_builder/core'

module PodBuilder
  module Command
    class GeneratePodspec
      def self.call
        Configuration.check_inited
        PodBuilder::prepare_basepath

        installer, analyzer = Analyze.installer_at(PodBuilder::basepath, false)
        all_buildable_items = Analyze.podfile_items(installer, analyzer)

        Podspec::generate(all_buildable_items, analyzer)

        puts "\n\n🎉 done!\n".green
        return 0
      end
    end
  end
end
