require 'digest'
require 'colored'
require 'highline/import'

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
  
  class Pod::Target::BuildSettings
    alias_method :swz_save_as, :save_as

    @specs_remove_module_maps = Hash.new

    class << self
      attr_accessor :specs_remove_module_maps
    end

    def save_as(path)
      Pod::Target::BuildSettings.specs_remove_module_maps.each do |root_name, module_maps_to_remove|
        if target.name == root_name
          module_maps_to_remove.each do |module_map_to_remove|
            xcconfig.attributes["OTHER_CFLAGS"] = xcconfig.attributes["OTHER_CFLAGS"].gsub(/-fmodule-map-file=\S*#{module_map_to_remove}.modulemap.*?(\s|$)/, '')
           end
        end
      end
     
      swz_save_as(path)
    end
  end
rescue LoadError
  # CocoaPods 1.6.2 or earlier
end

module PodBuilder
  class Install
    # This method will generate prebuilt data by building from "/tmp/pod_builder/Podfile"
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

        prepare_for_static_framework_workarounds(podfile_content, podfile_items)
        
        install
        
        copy_prebuilt_items(podfile_items)        
        add_prebuilt_info_file(podfile_items)
        
        licenses = license_specifiers()
        
        if !OPTIONS.has_key?(:debug)
          PodBuilder::safe_rm_rf(Configuration.build_path)
        end  
        
        return licenses
      rescue Exception => e
        if File.directory?("#{Configuration.build_path}/Pods/Pods.xcodeproj")
          if ENV['DEBUGGING']
            system("xed #{Configuration.build_path}/Pods")  
          else
            confirm = ask("\n\nOh no! Something went wrong during prebuild phase! Do you want to open the prebuild project to debug the error, you will need to add and run the Pods-Dummy scheme? [Y/N] ".red) { |yn| yn.limit = 1, yn.validate = /[yn]/i }
            if confirm.downcase == 'y'
              system("xed #{Configuration.build_path}/Pods")  
            end
          end
        end
        
        raise e
      ensure        
        FileUtils.rm(lock_file) if File.exist?(lock_file)
      end
    end

    def self.add_prebuilt_info_files(podfile_items)
      gitignored_files = PodBuilder::gitignoredfiles
      
      swift_version = PodBuilder::system_swift_version

      write_prebuilt_info_filename_gitattributes
      
      root_names = podfile_items.reject(&:is_prebuilt).map(&:root_name).uniq
      root_names.each do |prebuilt_name| 
        path = PodBuilder::prebuiltpath(prebuilt_name)
        
        unless File.directory?(path)
          puts "Prebuilt items for #{prebuilt_name} not found".blue
          next
        end
        
        unless podfile_item = podfile_items.detect { |t| t.name == prebuilt_name } || podfile_items.detect { |t| t.root_name == prebuilt_name }
          puts "Prebuilt items for #{prebuilt_name} not found #2".blue
          next
        end
        
        podbuilder_file = File.join(path, Configuration.prebuilt_info_filename)
        entry = podfile_item.entry(true, false)
        
        data = {}
        data['entry'] = entry
        data['is_prebuilt'] = podfile_item.is_prebuilt  
        if Dir.glob(File.join(path, "#{podfile_item.prebuilt_rel_path}/Headers/*-Swift.h")).count > 0
          data['swift_version'] = swift_version
        end
        
        specs = podfile_items.select { |x| x.module_name == podfile_item.module_name }
        subspecs_deps = specs.map(&:dependency_names).flatten
        subspec_self_deps = subspecs_deps.select { |x| x.start_with?("#{prebuilt_name}/") }
        data['specs'] = (specs.map(&:name) + subspec_self_deps).uniq
        data['is_static'] = podfile_item.is_static
        data['original_compile_path'] = Pathname.new(Configuration.build_path).realpath.to_s
        data['build_folder_hash'] = build_folder_hash(podfile_item, gitignored_files)
        
        File.write(podbuilder_file, JSON.pretty_generate(data))
      end
    end
    private 

    def self.prepare_for_static_framework_workarounds(podfile_content, podfile_items)
      unless podfile_content.include?("use_modular_headers!")
        return
      end

      podfile_items.each do |podfile_item|
        Pod::Target::BuildSettings.specs_remove_module_maps[podfile_item.root_name] = podfile_item.remove_module_maps
      end
    end
    
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
      # makes  the `generate_lldbinit` command work.
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
      podfile_content = File.read(podfile_path)
      
      if OPTIONS.has_key?(:force_rebuild)
        podfile_content.gsub!("%%%prebuilt_root_paths%%%", "{}")
      else
        download # Copy files under #{Configuration.build_path}/Pods so that we can determine build folder hashes

        gitignored_files = PodBuilder::gitignoredfiles

        replaced_items = Hash.new
        
        # Replace prebuilt entries in Podfile for Pods that have no changes in source code which will avoid rebuilding them
        items = podfile_items.group_by { |t| t.root_name }.map { |k, v| v.first } # Return one podfile_item per root_name
        items.each do |item|
          podspec_path = item.prebuilt_podspec_path
          if last_build_folder_hash = build_folder_hash_in_prebuilt_info_file(item)
            if last_build_folder_hash == build_folder_hash(item, gitignored_files)
              if Configuration.subspecs_to_split.include?(item.name)
                puts "No changes detected to '#{item.name}', will skip rebuild".blue
              else
                puts "No changes detected to '#{item.root_name}', will skip rebuild".blue
              end
              podfile_items.select { |t| t.root_name == item.root_name }.each do |replace_item|
                replace_regex = "pod '#{Regexp.quote(replace_item.name)}', .*"
                replace_line_found = podfile_content =~ /#{replace_regex}/i
                raise "\n\nFailed finding pod entry for '#{replace_item.name}'".red unless replace_line_found
                podfile_content.gsub!(/#{replace_regex}/, replace_item.prebuilt_entry(true, true))

                replaced_items[replace_item.root_name] = PodBuilder::prebuiltpath
              end
            end
          end
        end

        podfile_content.gsub!("%%%prebuilt_root_paths%%%", replaced_items.to_s)
      end

      File.write(podfile_path, podfile_content)

      return replaced_items
    end
    
    def self.install
      puts "Prebuilding items".yellow
      
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
    
    def self.copy_prebuilt_items(podfile_items)
      FileUtils.mkdir_p(PodBuilder::prebuiltpath)

      non_prebuilt_items = podfile_items.reject(&:is_prebuilt)
      
      splitted_pods = non_prebuilt_items.map { |t| splitted_pod(t, podfile_items) }.compact
      non_prebuilt_items.reject! { |t| splitted_pods.map(&:root_name).include?(t.root_name) }

      pod_names = non_prebuilt_items.map(&:root_name) + splitted_pods.map(&:name)
      pod_names.uniq!

      pod_names.reject! { |t| 
        folder_path = PodBuilder::buildpath_prebuiltpath(t)
        File.directory?(folder_path) && Dir.empty?(folder_path) # When using prebuilt items we end up with empty folders
      } 

      # Selectively delete destination folder. 
      # If it's a splitted spec we just need to wipe the Subspecs/#{pod_name}
      # If it's not we need to wipe everything except the Subspecs folder
      pod_names.each do |pod_name|   
        root_name = pod_name.split("/").first
        if pod_name.include?("/") # Splitted pod
          PodBuilder::safe_rm_rf(PodBuilder::prebuiltpath("#{root_name}/Subspecs/#{pod_name.gsub("/", "_") }"))
        else
          items_to_delete = Dir.glob("#{PodBuilder::prebuiltpath(root_name)}/**/*")
          items_to_delete.reject! { |t| t.include?(PodBuilder::prebuiltpath("#{root_name}/Subspecs")) }

          items_to_delete.each { |t| PodBuilder::safe_rm_rf(t) }
        end
      end

      pod_names.each do |pod_name|        
        root_name = pod_name.split("/").first
        source_path = PodBuilder::buildpath_prebuiltpath(root_name)

        unless File.directory?(source_path)
          puts "Prebuilt items for #{pod_name} not found".blue
          next
        end

        if Configuration.subspecs_to_split.include?(pod_name)
          destination_folder = PodBuilder::prebuiltpath("#{root_name}/Subspecs/#{pod_name.gsub("/", "_") }")
          FileUtils.mkdir_p(destination_folder)
          FileUtils.cp_r("#{source_path}/.", destination_folder)
        else
          FileUtils.cp_r(source_path, PodBuilder::prebuiltpath)
        end
      end
      
      # Folder won't exist if no dSYM were generated (all static libs)
      if File.directory?(PodBuilder::buildpath_dsympath)
        FileUtils.mkdir_p(PodBuilder::dsympath)
        FileUtils.cp_r(PodBuilder::buildpath_dsympath, PodBuilder::basepath)
      end
    end

    def self.write_prebuilt_info_filename_gitattributes
      gitattributes_path = PodBuilder::basepath(".gitattributes")
      expected_attributes = ["#{Configuration.configuration_filename} binary"].join
      unless File.exists?(gitattributes_path) && File.read(gitattributes_path).include?(expected_attributes)
        File.write(gitattributes_path, expected_attributes, mode: 'a')
      end
    end
    
    def self.init_git(path)
      current_dir = Dir.pwd
      
      Dir.chdir(path)
      system("git init")
      Dir.chdir(current_dir)
    end
    
    def self.build_folder_hash_in_prebuilt_info_file(podfile_item)
      prebuilt_info_path = PodBuilder::prebuiltpath(File.join(podfile_item.root_name, Configuration.prebuilt_info_filename))
      
      if File.exist?(prebuilt_info_path)
        data = JSON.parse(File.read(prebuilt_info_path))
        return data['build_folder_hash']  
      else
        return nil
      end
    end
    
    def self.build_folder_hash(podfile_item, exclude_files)
      if podfile_item.is_development_pod
        if Pathname.new(podfile_item.path).absolute?
          item_path = podfile_item.path
        else 
          item_path = PodBuilder::basepath(podfile_item.path)
        end
        
        rootpath = PodBuilder::git_rootpath
        file_hashes = []
        Dir.glob("#{item_path}/**/*", File::FNM_DOTMATCH) do |path|
          unless File.file?(path)
            next
          end
          
          path = File.expand_path(path)
          rel_path = path.gsub(rootpath, "")[1..]
          unless exclude_files.include?(rel_path)
            file_hashes.push(Digest::MD5.hexdigest(File.read(path)))
          end
        end
        
        return Digest::MD5.hexdigest(file_hashes.join)
      else
        # Pod folder might be under .gitignore
        item_path = "#{Configuration.build_path}/Pods/#{podfile_item.root_name}"
        return `find '#{item_path}' -type f -print0 | sort -z | xargs -0 shasum | shasum | cut -d' ' -f1`.strip()
      end
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

    def self.splitted_pod(podfile_item, podfile_items)
      splitted_pods = podfile_items.select { |t| t.root_name == podfile_item.root_name && Configuration.subspecs_to_split.include?(t.name) }

      if splitted_pods.count == 1
        return splitted_pods[0]
      else
        return nil
      end
    end
  end
end
