# TODO: Add support when building without use_frameworks!

require 'fourflusher'
require 'colored'

module PodBuilder
  def self.build_for_iosish_platform(sandbox, build_dir, target, device, simulator, configuration, deterministic_build, build_for_apple_silicon)
    raise "\n\nApple silicon hardware still unsupported since it requires to migrate to xcframeworks".red if build_for_apple_silicon

    deployment_target = target.platform_deployment_target
    target_label = target.cocoapods_target_label

    xcodebuild(sandbox, target_label, device, deployment_target, configuration, deterministic_build, [])
    excluded_archs = build_for_apple_silicon ? [] : ["arm64"]
    xcodebuild(sandbox, target_label, simulator, deployment_target, configuration, deterministic_build, excluded_archs)

    spec_names = target.specs.map { |spec| [spec.root.name, spec.root.module_name] }.uniq
    spec_names.each do |root_name, module_name|
      device_lib = "#{build_dir}/#{configuration}-#{device}/#{root_name}/#{module_name}.framework/#{module_name}"
      device_framework_lib = File.dirname(device_lib)
      device_swift_header_path = "#{device_framework_lib}/Headers/#{module_name}-Swift.h"

      simulator_lib = "#{build_dir}/#{configuration}-#{simulator}/#{root_name}/#{module_name}.framework/#{module_name}"
      simulator_framework_lib = File.dirname(simulator_lib)
      simulator_swift_header_path = "#{simulator_framework_lib}/Headers/#{module_name}-Swift.h"

      next unless File.file?(device_lib) && File.file?(simulator_lib)
      
      # Starting with Xcode 12b3 the simulator binary contains an arm64 slice as well which conflict with the one in the device_lib
      # when creating the fat library. A naive workaround is to remove the arm64 from the simulator_lib however this is wrong because 
      # we might actually need to have 2 separated arm64 slices, one for simulator and one for device each built with different
      # compile time directives (e.g #if targetEnvironment(simulator))
      #
      # For the time being we remove the arm64 slice bacause otherwise the `xcrun lipo -create -output ...` would fail.
      if `xcrun lipo -info #{simulator_lib}`.include?("arm64")
       `xcrun lipo -remove arm64 #{simulator_lib} -o #{simulator_lib}`
      end

      raise "Lipo failed on #{device_lib}" unless system("xcrun lipo -create -output #{device_lib} #{device_lib} #{simulator_lib}")

      # Merge swift headers as per Xcode 10.2 release notes
      if File.exist?(device_swift_header_path) && File.exist?(simulator_swift_header_path)
        device_content = File.read(device_swift_header_path)
        simulator_content = File.read(simulator_swift_header_path)
        merged_content = %{
#if TARGET_OS_SIMULATOR
#{simulator_content}
#else
#{device_content}
#endif
}        
        File.write(device_swift_header_path, merged_content)
      end

      # Merge device framework into simulator framework (so that e.g swift Module folder is merged) 
      # letting device framework files overwrite simulator ones
      FileUtils.cp_r(File.join(device_framework_lib, "."), simulator_framework_lib) 
      source_lib = File.dirname(simulator_framework_lib)

      FileUtils.mv source_lib, build_dir, :force => true
    end

    FileUtils.rm_rf("#{build_dir}/#{configuration}-#{device}")
    FileUtils.rm_rf("#{build_dir}/#{configuration}-#{simulator}")
  end

  def self.xcodebuild(sandbox, target, sdk='macosx', deployment_target=nil, configuration, deterministic_build, exclude_archs)
    args = %W(-project #{sandbox.project_path.realdirpath} -scheme #{target} -configuration #{configuration} -sdk #{sdk})
    supported_platforms = { 'iphonesimulator' => 'iOS', 'appletvsimulator' => 'tvOS', 'watchsimulator' => 'watchOS' }
    if platform = supported_platforms[sdk]
      args += Fourflusher::SimControl.new.destination(:oldest, platform, deployment_target) unless platform.nil?
    end

    xcodebuild_version = `xcodebuild -version | head -n1 | awk '{print $2}'`.strip().to_f
    if exclude_archs.count > 0 && xcodebuild_version >= 12.0
      args += ["EXCLUDED_ARCHS=#{exclude_archs.join(" ")}"]
    end

    environmental_variables = {}
    if deterministic_build
      environmental_variables["ZERO_AR_DATE"] = "1"
    end

    execute_command 'xcodebuild', args, true, environmental_variables
  end

  # Copy paste implementation from CocoaPods internals to be able to call poopen3 passing environmental variables
  def self.execute_command(executable, command, raise_on_failure = true, environmental_variables = {})
    bin = Pod::Executable.which!(executable)

    command = command.map(&:to_s)
    full_command = "#{bin} #{command.join(' ')}"

    stdout = Pod::Executable::Indenter.new
    stderr = Pod::Executable::Indenter.new

    status = popen3(bin, command, stdout, stderr, environmental_variables)
    stdout = stdout.join
    stderr = stderr.join
    output = stdout + stderr
    unless status.success?
      if raise_on_failure
        raise "#{full_command}\n\n#{output}"
      else
        UI.message("[!] Failed: #{full_command}".red)
      end
    end

    output
  end

  def self.popen3(bin, command, stdout, stderr, environmental_variables)
    require 'open3'
    Open3.popen3(environmental_variables, bin, *command) do |i, o, e, t|
      Pod::Executable::reader(o, stdout)
      Pod::Executable::reader(e, stderr)
      i.close

      status = t.value

      o.flush
      e.flush
      sleep(0.01)

      status
    end
  end

  def self.enable_debug_information(project_path, configuration)
    project = Xcodeproj::Project.open(project_path)
    project.targets.each do |target|
      config = target.build_configurations.find { |config| config.name.eql? configuration }
      config.build_settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf-with-dsym'
      config.build_settings['ONLY_ACTIVE_ARCH'] = 'NO'
    end
    project.save
  end

  def self.copy_dsym_files(dsym_destination, configuration)
    dsym_destination.rmtree if dsym_destination.directory?

    platforms = Configuration.supported_platforms
    platforms.each do |platform|
      dsym = Pathname.glob("build/#{configuration}-#{platform}/**/*.dSYM")
      dsym.each do |dsym|
        destination = dsym_destination + platform
        FileUtils.mkdir_p destination
        FileUtils.cp_r dsym, destination, :remove_destination => true
      end
    end
  end
end

Pod::HooksManager.register('podbuilder-rome', :post_install) do |installer_context, user_options|
  enable_dsym = user_options.fetch('dsym', true)
  configuration = user_options.fetch('configuration', 'Debug')
  if user_options["pre_compile"]
    user_options["pre_compile"].call(installer_context)
  end

  sandbox_root = Pathname(installer_context.sandbox_root)
  sandbox = Pod::Sandbox.new(sandbox_root)

  PodBuilder::enable_debug_information(sandbox.project_path, configuration)

  build_dir = sandbox_root.parent + 'build'
  base_destination = sandbox_root.parent + 'Prebuilt'

  build_dir.rmtree if build_dir.directory?
  targets = installer_context.umbrella_targets.select { |t| t.specs.any? }
  targets.each do |target|
    case target.platform_name
    when :ios then PodBuilder::build_for_iosish_platform(sandbox, build_dir, target, 'iphoneos', 'iphonesimulator', configuration, PodBuilder::Configuration.deterministic_build, PodBuilder::Configuration.build_for_apple_silicon)
    when :osx then PodBuilder::xcodebuild(sandbox, target.cocoapods_target_label, configuration, PodBuilder::Configuration.deterministic_build, PodBuilder::Configuration.build_for_apple_silicon)
    when :tvos then PodBuilder::build_for_iosish_platform(sandbox, build_dir, target, 'appletvos', 'appletvsimulator', configuration, PodBuilder::Configuration.deterministic_build, PodBuilder::Configuration.build_for_apple_silicon)
    when :watchos then PodBuilder::build_for_iosish_platform(sandbox, build_dir, target, 'watchos', 'watchsimulator', configuration, PodBuilder::Configuration.deterministic_build, PodBuilder::Configuration.build_for_apple_silicon)
    else raise "\n\nUnknown platform '#{target.platform_name}'".red end
  end

  raise Pod::Informative, 'The build directory was not found in the expected location.' unless build_dir.directory?
  
  built_count = installer_context.umbrella_targets.map { |t| t.specs.map(&:name) }.flatten.map { |t| t.split("/").first }.uniq.count
  Pod::UI.puts "Built #{built_count} #{'items'.pluralize(built_count)}, copying..."

  base_destination.rmtree if base_destination.directory?

  installer_context.umbrella_targets.each do |umbrella|
    umbrella.specs.each do |spec|
      root_name = spec.name.split("/").first
      # Make sure the device target overwrites anything in the simulator build, otherwise iTunesConnect
      # can get upset about Info.plist containing references to the simulator SDK
      frameworks = Pathname.glob("build/#{root_name}/*.framework").reject { |f| f.to_s =~ /Pods[^.]+\.framework/ }

      consumer = spec.consumer(umbrella.platform_name)
      file_accessor = Pod::Sandbox::FileAccessor.new(sandbox.pod_dir(spec.root.name), consumer)
      frameworks += file_accessor.vendored_libraries
      frameworks += file_accessor.vendored_frameworks
      resources = file_accessor.resources

      destination = File.join(base_destination, root_name)
      FileUtils.mkdir_p(destination)

      files = frameworks + resources
      files.each do |file|
        FileUtils.cp_r file, destination
      end    
    end
  end

  # Depending on the resource it may happen that it is present twice, both in the .framework and in the parent folder
  Dir.glob("#{base_destination}/*") do |path|
    unless File.directory?(path)
      return
    end

    files = Dir.glob("#{path}/*")
    framework_files = Dir.glob("#{path}/*.framework/**/*").map { |t| File.basename(t) }

    files.each do |file|
      filename = File.basename(file.gsub(/\.xib$/, ".nib"))
      if framework_files.include?(filename)
        FileUtils.rm_rf(file)
      end
    end
  end

  if enable_dsym
    PodBuilder::copy_dsym_files(sandbox_root.parent + 'dSYM', configuration)
  else
    raise "Not implemented"
  end

  build_dir.rmtree if build_dir.directory?

  if user_options["post_compile"]
    user_options["post_compile"].call(installer_context)
  end
end
