# SDK and version configuration for the foo_component_updater_mac build.
#
# The foobar2000 SDK is NOT part of the repository. Download SDK-2026-10-01 from
# foobar2000.org, build its five static libraries in Release, and either extract it
# next to this repository as SDK-2026-10-01/ or point FB2K_SDK_PATH at it:
#
#   export FB2K_SDK_PATH="/path/to/SDK-2026-10-01"

module Fb2kSdk
  DEFAULT_SDK_DIR = "SDK-2026-10-01"

  # Absolute path of the SDK directory.
  def self.path
    if ENV['FB2K_SDK_PATH'] && !ENV['FB2K_SDK_PATH'].empty?
      File.expand_path(ENV['FB2K_SDK_PATH'])
    else
      File.expand_path("../#{DEFAULT_SDK_DIR}", __dir__)
    end
  end

  def self.validate!
    sdk_path = path
    unless File.directory?(sdk_path)
      puts "ERROR: SDK not found at: #{sdk_path}"
      puts ""
      puts "Download the foobar2000 SDK from foobar2000.org and extract it to:"
      puts "  #{sdk_path}"
      puts ""
      puts "Or set the FB2K_SDK_PATH environment variable:"
      puts "  export FB2K_SDK_PATH=\"/path/to/your/SDK\""
      exit 1
    end

    sdk_lib = File.join(sdk_path, "foobar2000/SDK/build/Release/libfoobar2000_SDK.a")
    unless File.exist?(sdk_lib)
      puts "WARNING: SDK libraries not built. Build the SDK projects in Release first:"
      puts "  #{sdk_path}/foobar2000/SDK, helpers, foobar2000_component_client, shared and #{sdk_path}/pfc"
    end

    sdk_path
  end
end

# The version lives in src/version.h (FCU_VERSION), the single source of truth.
module Fb2kVersions
  def self.get
    version_file = File.expand_path("../src/version.h", __dir__)
    match = File.read(version_file).match(/#define\s+FCU_VERSION\s+"([^"]+)"/)
    unless match
      puts "ERROR: FCU_VERSION not found in #{version_file}"
      exit 1
    end
    match[1]
  end

  # "0.1.0" => 100, "1.2.3" => 10203
  def self.get_build_number
    major, minor, patch = get.split('.').map(&:to_i)
    major * 10_000 + minor * 100 + patch.to_i
  end
end
