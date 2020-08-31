require 'digest'
require 'colored'

# The following begin/end clause contains a set of monkey patches of the original CP implementation

# The Pod::Target and Pod::Installer::Xcode::PodTargetDependencyInstaller swizzles patch
# the following issues: 
# - https://github.com/CocoaPods/Rome/issues/81
# - https://github.com/leavez/cocoapods-binary/issues/50
begin
  require 'cocoapods/installer/xcode/pods_project_generator/pod_target_dependency_installer.rb'

  class Pod::Specification
    Pod::Specification.singleton_class.send(:alias_method, :swz_from_hash, :from_hash)
    Pod::Specification.singleton_class.send(:alias_method, :swz_from_string, :from_string)

    def self.from_string(*args)
      spec = swz_from_string(*args)

      if overrides = PodBuilder::Configuration.spec_overrides[spec.name]
        overrides.each do |k, v|
          spec.attributes_hash[k] = v
        end
      end

      spec
    end
  end 

  class Pod::Target
    attr_accessor :mock_dynamic_framework

    alias_method :swz_build_type, :build_type

    def build_type
      if mock_dynamic_framework == true
        if defined?(Pod::BuildType) # CocoaPods 1.9 and later
          Pod::BuildType.new(linkage: :dynamic, packaging: :framework)
        elsif defined?(Pod::Target::BuildType) # CocoaPods 1.7, 1.8
          Pod::Target::BuildType.new(linkage: :dynamic, packaging: :framework)
        else
          raise "\n\nBuildType not found. Open an issue reporting your CocoaPods version".red
        end
      else
        swz_build_type()
      end
    end
  end

  # Starting from CocoaPods 1.10.0 and later resources are no longer copied inside the .framework
  # when building static frameworks. While this is correct when using CP normally, for redistributable
  # frameworks we require resources to be shipped along the binary
  class Pod::Installer::Xcode::PodsProjectGenerator::PodTargetInstaller
    alias_method :swz_add_files_to_build_phases, :add_files_to_build_phases

    def add_files_to_build_phases(native_target, test_native_targets, app_native_targets)
      target.mock_dynamic_framework = target.build_as_static_framework?
      swz_add_files_to_build_phases(native_target, test_native_targets, app_native_targets)
      target.mock_dynamic_framework = false
    end
  end 

  class Pod::Installer::Xcode::PodTargetDependencyInstaller
    alias_method :swz_wire_resource_bundle_targets, :wire_resource_bundle_targets
  
    def wire_resource_bundle_targets(resource_bundle_targets, native_target, pod_target)
      pod_target.mock_dynamic_framework = pod_target.build_as_static_framework?
      res = swz_wire_resource_bundle_targets(resource_bundle_targets, native_target, pod_target)
      pod_target.mock_dynamic_framework = false
      return res
    end
  end  
rescue LoadError
  # CocoaPods 1.6.2 or earlier
end

module PodBuilder
  class Install
    # This method will build frameworks starting from the "/tmp/pod_builder/Podfile"
    def self.podfile(podfile_content, podfile_items, build_configuration)
      puts "Preparing build Podfile".yellow

      PodBuilder::safe_rm_rf(Configuration.build_path)
      FileUtils.mkdir_p(Configuration.build_path)
      
      init_git(Configuration.build_path) # this is needed to be able to call safe_rm_rf

      podfile_content = copy_development_pods_source_code(podfile_content, podfile_items)

      podfile_content = Podfile.update_path_entries(podfile_content, Install.method(:podfile_path_transform))
      podfile_content = Podfile.update_project_entries(podfile_content, Install.method(:podfile_path_transform))
      podfile_content = Podfile.update_require_entries(podfile_content, Install.method(:podfile_path_transform))

      podfile_path = File.join(Configuration.build_path, "Podfile")
      File.write(podfile_path, podfile_content)

      begin  
        lock_file = "#{Configuration.build_path}/pod_builder.lock"
        FileUtils.touch(lock_file)

        use_prebuilt_entries_for_unchanged_pods(podfile_path, podfile_items)
  
        install

        add_framework_info_file(podfile_items)
        copy_frameworks(podfile_items)
        copy_libraries(podfile_items)
        copy_dsyms(podfile_items)

        return license_specifiers
      rescue Exception => e
        raise e
      ensure
        FileUtils.rm(lock_file)

        if !OPTIONS.has_key?(:debug)
          PodBuilder::safe_rm_rf(Configuration.build_path)
        end  
      end
    end

    private 

    def self.license_specifiers
      acknowledge_file = "#{Configuration.build_path}/Pods/Target Support Files/Pods-DummyTarget/Pods-DummyTarget-acknowledgements.plist"
      unless File.exist?(acknowledge_file)
        raise "\n\nLicense file not found".red
      end

      plist = CFPropertyList::List.new(:file => acknowledge_file)
      data = CFPropertyList.native_types(plist.value)
        
      return data["PreferenceSpecifiers"] || []
    end

    def self.copy_development_pods_source_code(podfile_content, podfile_items)
      if Configuration.build_using_repo_paths
        return podfile_content
      end

      # Development pods are normally built/integrated without moving files from their original paths.
      # It is important that CocoaPods compiles the files under Configuration.build_path in order that 
      # DWARF debug info reference to this constant path. Doing otherwise breaks the assumptions that 
      # makes  the `update_lldbinit` command work.
      development_pods = podfile_items.select { |x| x.is_development_pod }      
      development_pods.each do |podfile_item|
        destination_path = "#{Configuration.build_path}/Pods/#{podfile_item.name}"
        FileUtils.mkdir_p(destination_path)

        if Pathname.new(podfile_item.path).absolute?
          FileUtils.cp_r("#{podfile_item.path}/.", destination_path)
        else 
          FileUtils.cp_r("#{PodBuilder::basepath(podfile_item.path)}/.", destination_path)
        end

        podfile_content.gsub!("'#{podfile_item.path}'", "'#{destination_path}'")
      end

      return podfile_content
    end

    def self.use_prebuilt_entries_for_unchanged_pods(podfile_path, podfile_items)
      if OPTIONS.has_key?(:force_rebuild)
        return
      end

      download # Copy files under #{Configuration.build_path}/Pods so that we can determine build folder hashes

      podfile_content = File.read(podfile_path)

      # Replace prebuilt entries in Podfile for Pods that have no changes in source code which will avoid rebuilding them
      items = podfile_items.group_by { |t| t.root_name }.map { |k, v| v.first } # Return one podfile_item per root_name
      items.each do |item|
        framework_path = PodBuilder::prebuiltpath("#{item.root_name}/#{item.module_name}.framework")
        podspec_path = item.prebuilt_podspec_path
        if (last_build_folder_hash = build_folder_hash_in_framework_info_file(framework_path)) && File.exist?(podspec_path)
          if last_build_folder_hash == build_folder_hash(item)
            puts "No changes detected to '#{item.root_name}', will skip rebuild".blue
            podfile_items.select { |t| t.root_name == item.root_name }.each do |replace_item|
              replace_regex = "pod '#{Regexp.quote(replace_item.name)}', .*"
              replace_line_found = podfile_content =~ /#{replace_regex}/i
              raise "\n\nFailed finding pod entry for '#{replace_item.name}'".red unless replace_line_found
              podfile_content.gsub!(/#{replace_regex}/, replace_item.prebuilt_entry(true, true))
            end
          end
        end
      end

      File.write(podfile_path, podfile_content)
    end

    def self.install
      puts "Building frameworks".yellow

      CLAide::Command::PluginManager.load_plugins("cocoapods")

      Dir.chdir(Configuration.build_path) do
        config = Pod::Config.new()
        installer = Pod::Installer.new(config.sandbox, config.podfile, config.lockfile)
        installer.repo_update = false
        installer.update = false
        
        install_start_time = Time.now
        installer.install! 
        install_time = Time.now - install_start_time

        puts "Build completed in #{install_time.to_i} seconds".blue
      end
    end

    def self.download
      puts "Downloading Pods source code".yellow

      CLAide::Command::PluginManager.load_plugins("cocoapods")

      Dir.chdir(Configuration.build_path) do
        Pod::UserInterface::config.silent = true

        config = Pod::Config.new()
        installer = Pod::Installer.new(config.sandbox, config.podfile, config.lockfile)
        installer.repo_update = false
        installer.update = false
        installer.prepare
        installer.resolve_dependencies
        installer.download_dependencies

        Pod::UserInterface::config.silent = false
      end
    end

    def self.add_framework_info_file(podfile_items)
      swift_version = PodBuilder::system_swift_version
      Dir.glob(PodBuilder::buildpath_prebuiltpath("*.framework")) do |framework_path|
        filename_ext = File.basename(framework_path)
        filename = File.basename(framework_path, ".*")

        specs = podfile_items.select { |x| x.module_name == filename }
        specs += podfile_items.select { |x| x.vendored_frameworks.map { |x| File.basename(x) }.include?(filename_ext) }
        if podfile_item = specs.first
          parent_framework_path = File.expand_path(File.joing(framework_path, ".."))
          podbuilder_file = File.join(parent_framework_path, Configuration.framework_info_filename)
          entry = podfile_item.entry(true, false)

          data = {}
          data['entry'] = entry
          data['is_prebuilt'] = podfile_item.is_prebuilt  
          if Dir.glob(File.join(framework_path, "Headers/*-Swift.h")).count > 0
            data['swift_version'] = swift_version
          end
          subspecs_deps = specs.map(&:dependency_names).flatten
          subspec_self_deps = subspecs_deps.select { |x| x.start_with?("#{podfile_item.root_name}/") }
          data['specs'] = (specs.map(&:name) + subspec_self_deps).uniq
          data['is_static'] = podfile_item.is_static
          data['original_compile_path'] = Pathname.new(Configuration.build_path).realpath.to_s
          data['build_folder_hash'] = build_folder_hash(podfile_item)

          File.write(podbuilder_file, JSON.pretty_generate(data))
        else
          raise "\n\nUnable to detect item for framework #{filename}.framework. Please open a bug report!".red
        end
      end
    end

    def self.copy_frameworks(podfile_items)
      Dir.glob(PodBuilder::buildpath_prebuiltpath("*.framework")) do |framework_path|
        if item = podfile_items.detect { |t| t.module_name == File.basename(framework_path, ".*") || t.vendored_frameworks.map { |t| File.basename(t) }.include?(File.basename(framework_path)) }
          if item.is_prebuilt
            next
          end

          destination_path = PodBuilder::prebuiltpath(item.root_name)
          PodBuilder::safe_rm_rf("#{destination_path}/#{File.basename(framework_path)}")
          FileUtils.mkdir_p(destination_path)
          FileUtils.cp_r(framework_path, destination_path)
        else
          raise "\n\nUnassociated framework #{framework_path}".red
        end
      end
    end

    def self.copy_libraries(podfile_items)
      Dir.glob(PodBuilder::buildpath_prebuiltpath("*.a")) do |library_path|
        library_name = File.basename(library_path)

        # Find vendored libraries in the build folder:
        # This allows to determine which Pod is associated to the vendored_library
        # because there are cases where vendored_libraries are specified with wildcards (*.a)
        # making it impossible to determine the associated Pods when building multiple pods at once
        search_base = "#{Configuration.build_path}/Pods/"
        podfile_items.each do |podfile_item|
          podfile_item.vendored_libraries.each do |vendored_item|
            if result = Dir.glob("#{search_base}**/#{vendored_item}").first
              result_path = result.gsub(search_base, "")
              module_name = result_path.split("/").first
              if module_name == podfile_item.module_name
                library_rel_path = "#{podfile_item.root_name}/#{podfile_item.prebuilt_rel_path}"
                                
                result_path = result_path.split("/").drop(1).join("/")

                destination_path = PodBuilder::prebuiltpath("#{library_rel_path}/#{result_path}")
                FileUtils.mkdir_p(File.dirname(destination_path))
                FileUtils.cp_r(library_path, destination_path, :remove_destination => true)
                FileUtils.rm(library_path)
              end
            end
          end

          # A pod might depend upon a static library that is shipped with a prebuilt framework
          # which is not added to the Rome folder and podspecs
          # 
          # An example is Google-Mobile-Ads-SDK which adds
          # - vendored framework: GooleMobileAds.framework 
          # - vendored library: libGooleMobileAds.a
          # These might be used by another pod (e.g AppNexusSDK/GoogleAdapterThatDependsOnGooglePod)
          podfile_item.libraries.each do |library|            
            if result = Dir.glob("#{search_base}**/lib#{library}.a").first
              result_path = result.gsub(search_base, "")

              library_rel_path = "#{podfile_item.root_name}/#{podfile_item.prebuilt_rel_path}"
                                
              result_path = result_path.split("/").drop(1).join("/")

              destination_path = PodBuilder::prebuiltpath("#{library_rel_path}/#{result_path}")
              FileUtils.mkdir_p(File.dirname(destination_path))
              FileUtils.cp_r(library_path, destination_path, :remove_destination => true)
              FileUtils.rm(library_path)
            end
          end
        end
      end

      all_vendored_libraries = podfile_items.map(&:vendored_libraries).flatten
      all_vendored_libraries += all_vendored_libraries.map { |t| File.basename(t) }
      all_vendored_libraries.uniq!

      unassociated_libs = Dir.glob(PodBuilder::buildpath_prebuiltpath("*.a"))
      unassociated_libs.map! { |t| t.gsub(PodBuilder::buildpath_prebuiltpath, "")[1..] }
      unassociated_libs.reject! { |t| all_vendored_libraries.include?(t) }
      if unassociated_libs.count > 0
        puts "\n\nUnassociated libs found #{unassociated_libs} found".red
      end
    end

    def self.copy_dsyms(podfile_items)
      Configuration.supported_platforms.each do |platform|
        Dir.glob("#{Configuration.build_path}/dSYM/#{platform}/**/*.dSYM") do |dsym_path|
          destination_path = PodBuilder::dsympath(platform) 
          PodBuilder.safe_rm_rf("#{destination_path}/#{File.basename(dsym_path)}")
          FileUtils.mkdir_p(destination_path)
          FileUtils.cp_r(dsym_path, destination_path)
        end  
      end
    end

    def self.init_git(path)
      current_dir = Dir.pwd

      Dir.chdir(path)
      system("git init")
      Dir.chdir(current_dir)
    end

    def self.build_folder_hash_in_framework_info_file(framework_path)
      parent_framework_path = File.expand_path(File.joing(framework_path, ".."))
      framework_info_path = File.join(framework_path, Configuration.framework_info_filename)

      if File.exist?(framework_info_path)
        data = JSON.parse(File.read(framework_info_path))

        return data['build_folder_hash']  
      else
        return nil
      end
    end

    def self.build_folder_hash(podfile_item)
      if podfile_item.is_development_pod
        if Pathname.new(podfile_item.path).absolute?
          item_path = podfile_item.path
        else 
          item_path = PodBuilder::basepath(podfile_item.path)
        end
      else
        item_path = "#{Configuration.build_path}/Pods/#{podfile_item.root_name}"
      end

      return `find '#{item_path}' -type f -print0 | sort -z | xargs -0 shasum | shasum | cut -d' ' -f1`.strip()
    end
    
    def self.podfile_path_transform(path)
      if Configuration.build_using_repo_paths
        return File.expand_path(PodBuilder::basepath(path))
      else
        use_absolute_paths = true
        podfile_path = File.join(Configuration.build_path, "Podfile")
        original_basepath = PodBuilder::basepath
  
        podfile_base_path = Pathname.new(File.dirname(podfile_path))
  
        original_path = Pathname.new(File.join(original_basepath, path))
        replace_path = original_path.relative_path_from(podfile_base_path)
        if use_absolute_paths
          replace_path = replace_path.expand_path(podfile_base_path)
        end
  
        return replace_path
      end
    end  
  end
end
