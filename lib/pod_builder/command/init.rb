require 'pod_builder/core'

module PodBuilder
  module Command
    class Init
      def self.call
        raise "\n\nAlready initialized\n".red if Configuration.exists

        xcworkspace = Dir.glob("*.xcworkspace")
        raise "\n\nNo xcworkspace found in current folder\n".red if xcworkspace.count == 0
        raise "\n\nToo many xcworkspaces found in current folder\n#{xcworkspace}\n".red if xcworkspace.count > 1

        Configuration.project_name = File.basename(xcworkspace.first, ".*")
        
        OPTIONS[:prebuild_path] ||= Configuration.base_path

        if File.expand_path(OPTIONS[:prebuild_path]) != OPTIONS[:prebuild_path] # if not absolute
          OPTIONS[:prebuild_path] = File.expand_path(PodBuilder::project_path(OPTIONS[:prebuild_path]))
        end

        FileUtils.mkdir_p(OPTIONS[:prebuild_path])
        FileUtils.mkdir_p("#{OPTIONS[:prebuild_path]}/.pod_builder")
        FileUtils.touch("#{OPTIONS[:prebuild_path]}/.pod_builder/pod_builder")

        source_path_rel_path = "Sources"
        development_pods_config_rel_path = Configuration.dev_pods_configuration_filename

        git_ignores = ["Pods/",
                       "*.xcworkspace",
                       "*.xcodeproj",
                       "Podfile.lock",
                       source_path_rel_path,
                       development_pods_config_rel_path]
        
        File.write("#{OPTIONS[:prebuild_path]}/.gitignore", git_ignores.join("\n"))

        project_podfile_path = PodBuilder::project_path("Podfile")
        prebuilt_podfile_path = File.join(OPTIONS[:prebuild_path], "Podfile")
        FileUtils.cp(project_podfile_path, prebuilt_podfile_path)

        podfile_content = File.read(prebuilt_podfile_path)
        
        podfile_content = Podfile.add_install_block(podfile_content)
        podfile_content = Podfile.update_path_entries(podfile_content, Init.method(:podfile_path_transform))
        podfile_content = Podfile.update_project_entries(podfile_content, Init.method(:podfile_path_transform))
        podfile_content = Podfile.update_require_entries(podfile_content, Init.method(:podfile_path_transform))

        if podfile_content.include?("/node_modules/react-native/")
          podfile_content = Podfile.prepare_for_react_native(podfile_content)
        end

        File.write(prebuilt_podfile_path, podfile_content)

        Configuration.write

        update_gemfile

        puts "\n\n🎉 done!\n".green
        return 0
      end

      private 

      def self.podfile_path_transform(path)
        use_absolute_paths = false
        podfile_path = File.join(OPTIONS[:prebuild_path], "Podfile")
        original_basepath = PodBuilder::project_path

        podfile_base_path = Pathname.new(File.dirname(podfile_path))
  
        original_path = Pathname.new(File.join(original_basepath, path))
        replace_path = original_path.relative_path_from(podfile_base_path)
        if use_absolute_paths
          replace_path = replace_path.expand_path(podfile_base_path)
        end
  
        return replace_path
      end   

      def self.update_gemfile
        gemfile_path = File.join(PodBuilder::home, "Gemfile")
        unless File.exist?(gemfile_path)
          FileUtils.touch(gemfile_path)
        end

        source_line = "source 'https://rubygems.org'"
        podbuilder_line = "gem 'pod-builder'"

        gemfile = File.read(gemfile_path)

        gemfile_lines = gemfile.split("\n")
        gemfile_lines.select! { |x| !trim_gemfile_line(x).include?(trim_gemfile_line(source_line)) }
        gemfile_lines.select! { |x| !trim_gemfile_line(x).include?(trim_gemfile_line(podbuilder_line)) }

        gemfile_lines.insert(0, source_line)
        gemfile_lines.push(podbuilder_line)
     
        File.write(gemfile_path, gemfile_lines.join("\n"))

        Dir.chdir(PodBuilder::home)
        system("bundle")
      end

      def self.trim_gemfile_line(line)
        return line.gsub("\"", "'").gsub(" ", "")
      end
    end
  end
end
