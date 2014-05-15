# Encoding: utf-8
# Cloud Foundry Java Buildpack
# Copyright (c) 2013 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'java_buildpack/container'
require 'java_buildpack/container/container_utils'
require 'java_buildpack/util/format_duration'
require 'java_buildpack/util/java_main_utils'
require 'java_buildpack/component/versioned_dependency_component'
require 'java_buildpack/component/java_opts'
require 'java_buildpack/container/wls/service_bindings_reader'
require 'yaml'
require 'tmpdir'

module JavaBuildpack::Container

  # Encapsulates the detect, compile, and release functionality for WebLogic Server (WLS) based
  # applications on Cloud Foundry.
  class Weblogic < JavaBuildpack::Component::VersionedDependencyComponent
    include JavaBuildpack::Util

    def initialize(context)
      super(context)

      if supports?
        @wls_version, @wls_uri = JavaBuildpack::Repository::ConfiguredItem
        .find_item(@component_name, @configuration) { |candidate_version| candidate_version.check_size(3) }


        @preferAppConfig = @configuration[PREFER_APP_CONFIG]
        @startInWlxMode  = @configuration[START_IN_WLX_MODE]

        @wlsSandboxRoot           = @droplet.sandbox
        @wlsDomainPath            = @wlsSandboxRoot + WLS_DOMAIN_PATH
        @appConfigCacheRoot       = @application.root + APP_WLS_CONFIG_CACHE_DIR
        @appServicesConfig        = @application.services

        # Root of Buildpack bundled config cache - points to <weblogic-buildpack>/resources/wls
        @buildpackConfigCacheRoot = BUILDPACK_WLS_CONFIG_CACHE_DIR

        load()

      else
        @wls_version, @wls_uri       = nil, nil

      end

    end


    # @macro base_component_detect
    def detect
      if @wls_version
        [wls_id(@wls_version)]
      else
        nil
      end
    end

    def compile1

       testServiceBindingParsing()
    end

    # @macro base_component_compile
    def compile

      download_and_install_wls
      configure
      link_to(@application.root.children, root)
      #@droplet.additional_libraries.link_to web_inf_lib
      create_dodeploy
    end

    def release

      setupJvmArgs
      createSetupEnvAndLinksScript

      [
          @droplet.java_home.as_env_var,
          "USER_MEM_ARGS=\"#{@droplet.java_opts.join(' ')}\"",
          "/bin/sh ./#{SETUP_ENV_AND_LINKS_SCRIPT}; #{@domainHome}/startWebLogic.sh"
      ].flatten.compact.join(' ')
    end


    protected

    # The unique identifier of the component, incorporating the version of the dependency (e.g. +wls=12.1.2+)
    #
    # @param [String] version the version of the dependency
    # @return [String] the unique identifier of the component
    def wls_id(version)
      "#{Weblogic.to_s.dash_case}=#{version}"
    end

    # The unique identifier of the component, incorporating the version of the dependency (e.g. +wls-buildpack-support=12.1.2+)
    #
    # @param [String] version the version of the dependency
    # @return [String] the unique identifier of the component
    def support_id(version)
      "wls-buildpack-support=#{version}"
    end

    # Whether or not this component supports this application
    #
    # @return [Boolean] whether or not this component supports this application
    def supports?
      wls? && !JavaBuildpack::Util::JavaMainUtils.main_class(@application)
    end

    private


    # Expect to see a '.wls' folder containing domain configurations and script to create the domain within the App bits
    APP_WLS_CONFIG_CACHE_DIR       = '.wls'.freeze

    # Default WebLogic Configurations packaged within the buildpack
    BUILDPACK_WLS_CONFIG_CACHE_DIR = Pathname.new(File.expand_path('../../../resources/wls', File.dirname(__FILE__))).freeze

    # Prefer App Bundled Config or Buildpack bundled Config
    PREFER_APP_CONFIG           = 'preferAppConfig'.freeze

    # Prefer App Bundled Config or Buildpack bundled Config
    START_IN_WLX_MODE           = 'startInWlxMode'.freeze

    # Following are relative to the .wls folder all under the APP ROOT
    WLS_SCRIPT_CACHE_DIR        = 'script'.freeze
    WLS_JVM_CONFIG_DIR          = 'jvm'.freeze
    WLS_JMS_CONFIG_DIR          = 'jms'.freeze
    WLS_JDBC_CONFIG_DIR         = 'jdbc'.freeze
    WLS_FOREIGN_JMS_CONFIG_DIR  = 'foreignjms'.freeze
    WLS_PRE_JARS_CACHE_DIR      = 'preJars'.freeze
    WLS_POST_JARS_CACHE_DIR     = 'postJars'.freeze

    # Files required for installing from a jar in silent mode
    ORA_INSTALL_INVENTORY_FILE  = 'oraInst.loc'.freeze
    WLS_INSTALL_RESPONSE_FILE   = 'installResponseFile'.freeze

    # keyword to change to point to actual wlsInstall in response file
    WLS_INSTALL_PATH_TEMPLATE   = 'WEBLOGIC_INSTALL_PATH'.freeze
    WLS_ORA_INVENTORY_TEMPLATE  = 'ORACLE_INVENTORY_INSTALL_PATH'.freeze
    WLS_ORA_INV_INSTALL_PATH    = '/tmp/wlsOraInstallInventory'.freeze

    # Parent Location to save/store the application during deployment
    DOMAIN_APPS_FOLDER             = 'apps'.freeze

    WLS_SERVER_START_SCRIPT     = 'startWebLogic.sh'.freeze
    WLS_COMMON_ENV_SCRIPT       = 'commEnv.sh'.freeze
    WLS_CONFIGURE_SCRIPT        = 'configure.sh'.freeze
    WLS_HOME_DIR                = 'wlserver'.freeze

    WLS_SERVER_START_TOKEN      = '\${DOMAIN_HOME}/bin/startWebLogic.sh \$*'.freeze
    SETUP_ENV_AND_LINKS_SCRIPT  = 'setupPathsAndEnv.sh'.freeze

    # WLS_DOMAIN_PATH is relative to sandbox
    WLS_DOMAIN_PATH          = 'domains/'.freeze

    # Other constants
    SERVER_VM                = '-server'.freeze
    CLIENT_VM                = '-client'.freeze
    BEA_HOME_TEMPLATE        = 'BEA_HOME="\$MW_HOME"'
    MW_HOME_TEMPLATE         = 'MW_HOME="\$MW_HOME"'

    # WLS Domain Template jar
    WLS_DOMAIN_TEMPLATE      = 'wls.jar'.freeze

    WEB_INF_DIRECTORY        = 'WEB-INF'.freeze
    JAVA_BINARY              = 'java'.freeze

    APP_NAME                 = 'ROOT'.freeze


    # @return [Hash] the configuration or an empty hash if the configuration file does not exist
    def load(should_log = true)

      # Determine the configs that should be used to drive the domain creation.
      # Can be the App bundled configs
      # or the buildpack bundled configs

      # During development when the domain structure is still in flux, use App bundled config to test/tweak the domain.
      # Once the domain structure is finalized, save the configs as part of the buildpack and then only pass along the bare bones domain config and jvm config.
      # Ignore the rest of the app configs.

      configCacheRoot = determineConfigCacheLocation

      @wlsDomainYamlConfigFile  = Dir.glob("#{@appConfigCacheRoot}/*.yml")[0]

      # If there is no Domain Config yaml file, copy over the buildpack bundled basic domain configs.
      # Create the appConfigCacheRoot '.wls' directory under the App Root as needed
      if (@wlsDomainYamlConfigFile.nil?)
        system "mkdir #{@appConfigCacheRoot} 2>/dev/null; cp  #{@buildpackConfigCacheRoot}/*.yml #{@appConfigCacheRoot}"
        @wlsDomainYamlConfigFile  = Dir.glob("#{@appConfigCacheRoot}/*.yml")[0]
        logger.debug { "No Domain Configuration yml file found, creating one from the buildpack bundled template!!" }
      end

      domainConfiguration       = YAML.load_file(@wlsDomainYamlConfigFile)
      logger.debug { "WLS Domain Configuration: #{@wlsDomainYamlConfigFile}: #{domainConfiguration}" }

      @domainConfig  = domainConfiguration["Domain"]
      @domainName    = @domainConfig['domainName']
      @domainHome    = @wlsDomainPath + @domainName
      @domainAppsDir = @domainHome + DOMAIN_APPS_FOLDER

      # There can be multiple service definitions (for JDBC, JMS, Foreign JMS services)
      # Based on chosen config location, load the related files

      wlsJmsConfigFiles        = Dir.glob("#{configCacheRoot}/#{WLS_JMS_CONFIG_DIR}/*.yml")
      wlsJdbcConfigFiles       = Dir.glob("#{configCacheRoot}/#{WLS_JDBC_CONFIG_DIR}/*.yml")
      wlsForeignJmsConfigFile  = Dir.glob("#{configCacheRoot}/#{WLS_FOREIGN_JMS_CONFIG_DIR}/*.yml")

      @wlsCompleteDomainConfigsYml = [ @wlsDomainYamlConfigFile ]
      @wlsCompleteDomainConfigsYml +=  wlsJdbcConfigFiles + wlsJmsConfigFiles + wlsForeignJmsConfigFile

      logger.debug { "Configuration files used for Domain creation: #{@wlsCompleteDomainConfigsYml}" }

      # Filtered Pathname has a problem with non-existing files
      # It checks for their existence. So, get the path as string and add the props file name for the output file
      @wlsCompleteDomainConfigsProps     = @wlsDomainYamlConfigFile.to_s.sub(".yml", ".props")

      # For now, expecting only one script to be run to create the domain
      @wlsDomainConfigScript    = Dir.glob("#{configCacheRoot}/#{WLS_SCRIPT_CACHE_DIR}/*.py")[0]

      # If there is no Domain Script, use the buildpack bundled script.
      if (@wlsDomainConfigScript.nil?)
        @wlsDomainConfigScript  = Dir.glob("#{@buildpackConfigCacheRoot}/#{WLS_SCRIPT_CACHE_DIR}/*.py")[0]
        logger.debug { "No Domain creation script found, reusing one from the buildpack bundled template!!" }
      end


      logger.debug { "Configurations for WLS Domain" }
      logger.debug { "--------------------------------------" }
      logger.debug { "  Domain Name                : #{@domainName}" }
      logger.debug { "  Domain Location            : #{@domainHome}" }
      logger.debug { "  Apps Directory             : #{@domainAppsDir}" }
      logger.debug { "  Using App bundled Config?  : #{@domainAppsDir}" }

      logger.debug { "  Domain creation script     : #{@wlsDomainConfigScript}" }
      logger.debug { "  Input WLS Yaml Configs     : #{@wlsCompleteDomainConfigsYml}" }
      logger.debug { "--------------------------------------" }

      domainConfiguration || {}
    end

    # Load the app bundled configurations and re-configure as needed the JVM parameters for the Server VM
    # @return [Hash] the configuration or an empty hash if the configuration file does not exist
    def setupJvmArgs

      # Go with some defaults
      minPermSize = 128
      maxPermSize = 256
      minHeapSize = 512
      maxHeapSize = 1024
      otherJvmOpts = " -verbose:gc -Xloggc:gc.log -XX:+PrintGCDetails -XX:+PrintGCTimeStamps "

      # Expect only one server instance to run, so there can be only one jvm config
      @wlsJvmConfigFile         = Dir.glob("#{@appConfigCacheRoot}/#{WLS_JVM_CONFIG_DIR}/*.yml")[0]

      # If there is no Domain Script, use the buildpack bundled script.
      if (@wlsJvmConfigFile.nil?)
        @wlsJvmConfigFile = Dir.glob("#{@buildpackConfigCacheRoot}/#{WLS_JVM_CONFIG_DIR}/*.yml")[0]
      end

      if !@wlsJvmConfigFile.nil?

        jvmConfiguration = YAML.load_file(@wlsJvmConfigFile)
        logger.debug { "WLS JVM Configuration: #{@wlsJvmConfigFile}: contents #{jvmConfiguration}" }

        @jvmConfig    = jvmConfiguration["JVM"]

        minPermSize = @jvmConfig['minPerm']
        maxPermSize = @jvmConfig['maxPerm']
        logger.debug { "JVM config passed with App: #{@jvmConfig.to_s}" }

        # Set Default Min and Max Heap Size for WLS
        minHeapSize  = @jvmConfig['minHeap']
        maxHeapSize  = @jvmConfig['maxHeap']
        otherJvmOpts = @jvmConfig['otherJvmOpts']

      end

      logger.debug { "JVM config passed via droplet java_opts : #{@droplet.java_opts.to_s}" }
      javaOptTokens = @droplet.java_opts.join(' ').split

      javaOptTokens.each { |token|

        intValueInMB =  token[/[0-9]+/].to_i
        # The values incoming can be in MB or KB
        # Anything over 61440 is atleast in KB and needs to be converted to MB
        intValueInMB = (intValueInMB / 1024) if (intValueInMB > 61440)

        if token[/-XX:PermSize/]
          minPermSize = intValueInMB
          minPermSize = 128 if (minPermSize < 128)

        elsif token[/-XX:MaxPermSize/]
          maxPermSize = intValueInMB
          maxPermSize = 256 if (maxPermSize < 128)

        elsif token[/-Xms/]
          minHeapSize = intValueInMB
        elsif token[/-Xmx/]
          maxHeapSize = intValueInMB
        else
          otherJvmOpts = otherJvmOpts + " " + token
        end

      }

      @droplet.java_opts.clear()

      @droplet.java_opts << "-Xms#{minHeapSize}m"
      @droplet.java_opts << "-Xmx#{maxHeapSize}m"
      @droplet.java_opts << "-XX:PermSize=#{minPermSize}m"
      @droplet.java_opts << "-XX:MaxPermSize=#{maxPermSize}m"

      @droplet.java_opts << otherJvmOpts

      # Set the server listen port using the $PORT argument set by the warden container
      @droplet.java_opts.add_system_property 'weblogic.ListenPort', '$PORT'

      # Check whether to start in Wlx Mode that would disable JMS, EJB and JCA
      if @startInWlxMode
        @droplet.java_opts.add_system_property 'serverType', 'wlx'
      end

      logger.debug { "Consolidated Java Options for Server: #{@droplet.java_opts.join(' ')}" }

    end


    # Create a setup script that would recreate staging env's path structure inside the actual DEA runtime env and also embed additional jvm arguments at server startup
    def createSetupEnvAndLinksScript

      # The Java Buildpack for WLS creates the complete domain structure and other linkages during staging. The directory used for staging is at /tmp/staged/app
      # But the actual DEA execution occurs at /home/vcap/app. This discrepancy can result in broken paths and non-startup of the server.
      # So create linkage from /tmp/staged/app to actual environment of /home/vcap/app when things run in real execution
      # Also, this script needs to be invoked before starting the server as it will create the links and also tweak the server args (to listen on correct port, use user supplied jvm args)
      File.open(@application.root.to_s + "/" + SETUP_ENV_AND_LINKS_SCRIPT, 'w') do |f|

        f.puts "#!/bin/sh"
        f.puts "# The Java Buildpack for WLS creates complete domain structure and other linkages during staging at /tmp/staged/app location"
        f.puts "# But the actual DEA execution occurs at /home/vcap/app. This discrepancy can result in broken paths and non-startup of the server."
        f.puts "# So create linkage from /tmp/staged/app to actual environment of /home/vcap/app when things run in real execution"
        f.puts "# Create paths that match the staging env as scripts will break otherwise"
        f.puts ""
        f.puts "if [ ! -d \"/tmp/staged\" ]; then"
        f.puts "   /bin/mkdir /tmp/staged"
        f.puts "fi;"
        f.puts "if [ ! -d \"/tmp/staged/app\" ]; then"
        f.puts "   /bin/ln -s `pwd` /tmp/staged/app"
        f.puts "fi;"
        f.puts ""

        wlsPreClasspath  = "export PRE_CLASSPATH=\"#{@domainHome}/#{WLS_PRE_JARS_CACHE_DIR}/*\""
        wlsPostClasspath = "export POST_CLASSPATH=\"#{@domainHome}/#{WLS_POST_JARS_CACHE_DIR}/*\""

        f.puts "#Export User defined memory, jvm settings, pre/post classpaths inside the startWebLogic.sh"
        f.puts "/bin/sed -i.bak 's#^DOMAIN_HOME#export USER_MEM_ARGS=\"#{@droplet.java_opts.join(' ')} \";\\n#{wlsPreClasspath}\\n#{wlsPostClasspath}\\n&#1' #{@domainHome}/startWebLogic.sh"

      end

    end

    def link_application
      FileUtils.rm_rf root
      FileUtils.mkdir_p root
      @application.children.each { |child| FileUtils.cp_r child, root }
    end

    def install(inputFile)
      expand_start_time = Time.now


      FileUtils.rm_rf @wlsSandboxRoot
      FileUtils.mkdir_p @wlsSandboxRoot

      inputFilePath = File::absolute_path(inputFile.path)

      print "-----> Installing WebLogic to #{@droplet.sandbox.relative_path_from(@droplet.root)} using downloaded file: #{inputFilePath}\n"

      if inputFilePath[/\.zip/]
        installUsingZip(inputFilePath)
      else
        installUsingJarOrBinary(inputFilePath)
      end

      #rescue => e
      #  logger.debug { "Problem with install: check install log under #{@wlsSandboxRoot}" }
      #  print "       Problem with install: check install log under #{@wlsSandboxRoot}"
      #  system "/bin/cat  #{@wlsSandboxRoot}/install.log"
      #  raise RuntimeError, "WebLogicBuildpack-Install, error: #{e.message}", e.backtrace
      #end

      puts "(#{(Time.now - expand_start_time).duration})"
    end

    def installUsingZip(zipFile)

      print "       Installing WebLogic from downloaded zip file using config script\n"
      logger.debug { "Installing WebLogic from downloaded zip file using config script" }

      system "/usr/bin/unzip #{zipFile} -d #{@wlsSandboxRoot} >/dev/null"


      javaBinary      = Dir.glob("#{@wlsSandboxRoot}" + "/../**/" + JAVA_BINARY)[0]
      configureScript = Dir.glob("#{@wlsSandboxRoot}" + "/**/" + WLS_CONFIGURE_SCRIPT)[0]

      @javaHome = File.dirname(javaBinary) + "/.."
      @wlsInstall = File.dirname(configureScript)

      system "/bin/chmod +x #{configureScript}"

      # Run configure.sh so the actual files are unpacked fully and paths are configured correctly
      # Need to use pipeline as we need to provide inputs to scripts downstream

      logger.debug { "Running wls config script!!" }

      # Use this while running on Mac to pick the correct JDK location
      if !linux?

        print "       Warning!!! Running on Mac, cannot use linux java binaries downloaded earlier...!!\n"
        print "       Trying to find local java instance on Mac\n"

        logger.debug { "Warning!!! Running on Mac, cannot use linux java binaries downloaded earlier...!!" }
        logger.debug { "Trying to find local java instance on Mac" }

        javaBinaryLocations = Dir.glob("/Library/Java/JavaVirtualMachines/**/" + JAVA_BINARY)
        javaBinaryLocations.each { |javaBinaryCandidate|

          # The full installs have $JAVA_HOME/jre/bin/java path
          @javaHome =  File.dirname(javaBinaryCandidate) + "/.." if javaBinaryCandidate[/jdk1.7/]
        }
        print "       Warning!!! Using JAVA_HOME at #{@javaHome} \n"
        logger.debug { "Warning!!! Using JAVA_HOME at #{@javaHome}" }

      end

      print "       Starting WebLogic Install\n"
      logger.debug { "Starting WebLogic Install" }

      setMiddlewareHomeInConfigureScript(configureScript)
      system "export JAVA_HOME=#{@javaHome}; export MW_HOME=#{@wlsInstall}; echo no |  #{configureScript} > #{@wlsSandboxRoot}/install.log"

      print "       Finished running install, output saved at: #{@wlsSandboxRoot}/install.log"
      logger.debug { "Finished running install, output saved at: #{@wlsSandboxRoot}/install.log" }

    end

    def installUsingJarOrBinary(installBinaryFile)

      print "      Installing WebLogic from Jar or Binary downloaded file in silent mode\n"
      logger.debug { "Installing WebLogic from Jar or Binary downloaded file in silent mode" }

      print "      WARNING!! Installation of WebLogic Server from Jar or Binary image requires complete JDK. If install fails with JRE binary, please change buildpack to refer to full JDK installation rather than JRE and retry!!.\n"
      logger.debug { "WARNING!! Installation of WebLogic Server from Jar or Binary image requires complete JDK. If install fails with JRE binary, please change buildpack to refer to full JDK installation rather than JRE and retry!!" }

      javaBinary      = Dir.glob("#{@wlsSandboxRoot}" + "/../**/" + JAVA_BINARY)[0]
      @javaHome = File.dirname(javaBinary) + "/.."

      oraInstallInventorySrc    = @buildpackConfigCacheRoot + ORA_INSTALL_INVENTORY_FILE
      oraInstallInventoryTarget    = "/tmp/" + ORA_INSTALL_INVENTORY_FILE

      wlsInstallResponseFileSrc    = @buildpackConfigCacheRoot + WLS_INSTALL_RESPONSE_FILE
      wlsInstallResponseFileTarget = "/tmp/" + WLS_INSTALL_RESPONSE_FILE

      # Unfortunately the jar install of weblogic does not like hidden directories in its install path like .java-buildpack
      ## [VALIDATION] [ERROR]:INST-07004: Oracle Home location contains one or more invalid characters
      ## [VALIDATION] [SUGGESTION]:The directory name may only contain alphanumeric, underscore (_), hyphen (-) , or dot (.) characters, and it must begin with an alphanumeric character.
      ## Provide a different directory name.
      ## installation Failed. Exiting installation due to data validation failure.
      ## The Oracle Universal Installer failed.  Exiting.
      # So, the <APP>/.java-buildpack/weblogic/wlsInstall path wont work here
      # Have to create the wlsInstall outside of the .java-buildpack, just under the app location.
      @wlsInstall = File::absolute_path("#{@wlsSandboxRoot}/../../wlsInstall")

      puts "       Installing WebLogic at : #{@wlsInstall}"
      logger.debug { "Installing WebLogic at : #{@wlsInstall}" }

      system "rm -rf #{WLS_ORA_INV_INSTALL_PATH} 2>/dev/null"
      system "rm -rf #{@wlsInstall} 2>/dev/null"
      system "/bin/cp #{oraInstallInventorySrc} /tmp"
      system "/bin/cp #{wlsInstallResponseFileSrc} /tmp;"

      original = File.open(wlsInstallResponseFileTarget, 'r') { |f| f.read }
      modified = original.gsub(/#{WLS_INSTALL_PATH_TEMPLATE}/, @wlsInstall )
      File.open(wlsInstallResponseFileTarget, 'w') { |f| f.write modified }

      original = File.open(oraInstallInventoryTarget, 'r') { |f| f.read }
      modified = original.gsub(/#{WLS_ORA_INVENTORY_TEMPLATE}/, WLS_ORA_INV_INSTALL_PATH )
      File.open(oraInstallInventoryTarget, 'w') { |f| f.write modified }


      # Use this while running on Mac to pick the correct JDK location
      if !linux?

        print "       Warning!!! Running on Mac or other non-linux flavor, cannot use linux java binaries downloaded earlier...!!\n"
        print "       Trying to find local java instance on machine\n"

        logger.debug { "Warning!!! Running on Mac or other non-linux flavor, cannot use linux java binaries downloaded earlier...!!" }
        logger.debug { "Trying to find local java instance on Mac" }

        javaBinaryLocations = Dir.glob("/Library/Java/JavaVirtualMachines/**/" + JAVA_BINARY)
        javaBinaryLocations.each { |javaBinaryCandidate|

          # The full installs have $JAVA_HOME/jre/bin/java path
          @javaHome =  File.dirname(javaBinaryCandidate) + "/.." if javaBinaryCandidate[/jdk1.7/]
        }
        print "       Warning!!! Using JAVA_HOME at #{@javaHome} \n"
        logger.debug { "Warning!!! Using JAVA_HOME at #{@javaHome}" }

        javaBinary = "#{@javaHome}/bin/java"

      end

      # There appears to be a problem running the java -jar on the cached jar file with java being unable to get to the manifest correctly for some strange reason
      # Seems to fail with file name http:%2F%2F12.1.1.1:7777%2Ffileserver%2Fwls%2Fwls_121200.jar.cached but works fine if its foo.jar or anything simpler.
      # So, create a temporary link to the jar with a simpler name and then run the install..

      if (installBinaryFile[/\.jar/])
        newBinaryPath="/tmp/wls_tmp_installer.jar"
        installCommand = "export JAVA_HOME=#{@javaHome}; rm #{newBinaryPath} 2>/dev/null; ln -s #{installBinaryFile} #{newBinaryPath}; mkdir #{@wlsInstall}; #{javaBinary} -Djava.security.egd=file:/dev/./urandom -jar #{newBinaryPath} -silent -responseFile #{wlsInstallResponseFileTarget} -invPtrLoc #{oraInstallInventoryTarget}"
      else
        newBinaryPath="/tmp/wls_tmp_installer.bin"
        installCommand = "export JAVA_HOME=#{@javaHome}; rm #{newBinaryPath}; ln -s #{installBinaryFile} #{newBinaryPath}; mkdir #{@wlsInstall}; chmod +x #{newBinaryPath}; #{newBinaryPath} -J-Djava.security.egd=file:/dev/./urandom -silent -responseFile #{wlsInstallResponseFileTarget} -invPtrLoc #{oraInstallInventoryTarget}"
      end

      print "       Starting WebLogic Install with command:  #{installCommand}\n"
      logger.debug { "Starting WebLogic Install with command:  #{installCommand}" }

      system "#{installCommand} > #{@wlsSandboxRoot}/install.log"
      logger.debug { "Finished running install, output saved at: #{@wlsSandboxRoot}/install.log" }


    end

    def configure()
      configure_start_time = Time.now

      print "-----> Configuring WebLogic domain under #{@wlsSandboxRoot.relative_path_from(@droplet.root)}\n"

      @wlsHome = File.dirname(Dir.glob("#{@wlsInstall}/**/weblogic.jar")[0]) + "/../.."
      if (@wlsHome.nil?)
        logger.debug { "Problem with install, check captured install log output at #{@wlsInstall}/install.log" }
        print " Problem with install, check captured install log output at #{@wlsInstall}/install.log"
      end

      # Modify WLS commEnv Script to use -server rather than -client
      modifyJvmTypeInCommEnv()

      logger.debug { "WebLogic install is located at : #{@wlsInstall}" }
      logger.debug { "Application is located at : #{@application.root}" }

      # Save the location of the WLS Domain template jar file - this varies across releases
      # 10.3.6 - under ./wlserver/common/templates/domains/wls.jar
      # 12.1.2 - under ./wlserver/common/templates/wls/wls.jar
      @wlsDomainTemplateJar = Dir.glob("#{@wlsInstall}/**/wls.jar")[0]

      # Now add or update the Domain path and Wls Home inside the wlsDomainYamlConfigFile
      updateDomainConfigFile(@wlsDomainYamlConfigFile)

      logger.debug { "Configurations for Java WLS Buildpack" }
      logger.debug { "--------------------------------------" }
      logger.debug { "  Sandbox Root  : #{@wlsSandboxRoot} " }
      logger.debug { "  JAVA_HOME     : #{@javaHome} " }
      logger.debug { "  WLS_INSTALL   : #{@wlsInstall} "}
      logger.debug { "  WLS_HOME      : #{@wlsHome}" }
      logger.debug { "  DOMAIN HOME   : #{@domainHome}" }
      logger.debug { "--------------------------------------" }


      # Determine the configs that should be used to drive the domain creation.
      # Is it the App bundled configs or the buildpack bundled configs
      # The JVM and Domain configs of the App would always be used for domain/server names and startup arguments
      configCacheRoot = determineConfigCacheLocation

      # Consolidate all the user defined service definitions provided via the app,
      # Consolidate all the user defined service definitions provided via the app,
      # along with anything else that comes via the Service Bindings via the environment (VCAP_SERVICES) during staging/execution of the droplet.

      system "/bin/rm  #{@wlsCompleteDomainConfigsProps} 2>/dev/null"

      JavaBuildpack::Container::Wls::ServiceBindingsReader.createServiceDefinitionsFromFileSet(@wlsCompleteDomainConfigsYml, configCacheRoot, @wlsCompleteDomainConfigsProps)
      JavaBuildpack::Container::Wls::ServiceBindingsReader.createServiceDefinitionsFromBindings(@appServicesConfig, @wlsCompleteDomainConfigsProps)

      logger.debug { "Done generating Domain Configuration Property file for WLST: #{@wlsCompleteDomainConfigsProps}" }
      logger.debug { "--------------------------------------" }

      logger.debug { "Configurations for WLS Domain Creation" }
      logger.debug { "--------------------------------------" }
      logger.debug { "  Domain Name                : #{@domainName}" }
      logger.debug { "  Domain Location            : #{@domainHome}" }
      logger.debug { "  App Deployment Name        : #{APP_NAME}" }
      logger.debug { "  Domain Apps Directory      : #{@domainAppsDir}" }
      logger.debug { "  Using App bundled Config?  : #{@preferAppConfig}" }
      logger.debug { "  Domain creation script     : #{@wlsDomainConfigScript}" }
      logger.debug { "  WLST Input Config          : #{@wlsCompleteDomainConfigsProps}" }
      logger.debug { "--------------------------------------" }


      # Modify WLS commEnv Script to set MW_HOME variable as this is used in 10.3.x but not set within it.
      setMiddlewareHomeInCommEnv()

      # Run wlst.sh to generate the domain as per the requested configurations

      wlstScript = Dir.glob("#{@wlsInstall}" + "/**/wlst.sh")[0]
      system "/bin/chmod +x #{wlstScript}; export JAVA_HOME=#{@javaHome}; export MW_HOME=#{@wlsInstall}; #{wlstScript}  #{@wlsDomainConfigScript} #{@wlsCompleteDomainConfigsProps} > #{@wlsSandboxRoot}/wlstDomainCreation.log"

      logger.debug { "WLST finished generating domain under #{@domainHome}. WLST log saved at: #{@wlsSandboxRoot}/wlstDomainCreation.log" }

      linkJarsToDomain

      print "-----> Finished configuring WebLogic Domain under #{@domainHome.relative_path_from(@droplet.root)}.\n"
      print "       WLST log saved at: #{@wlsSandboxRoot}/wlstDomainCreation.log\n"

      wlsDomainConfig = Dir.glob("#{@domainHome}/**/config.xml")[0]
      if (wlsDomainConfig.nil?)
        logger.debug { "Problem with domain creation!!" }
        print " Problem with domain creation!!"

        system "/bin/cat #{@wlsSandboxRoot}/wlstDomainCreation.log"
      end

      puts "(#{(Time.now - configure_start_time).duration})"

    #rescue => e
    #  logger.debug { "Problem with configure: check configure log under #{@wlsSandboxRoot}" }
    #  print "       Problem with configure: check configure log under #{@wlsSandboxRoot}"
    #  system "/bin/cat  #{@wlsSandboxRoot}/configure.log"
    #  raise RuntimeError, "WebLogicBuildpack-Configure, error: #{e.message}", e.backtrace
    end


    # Generate the property file based on app bundled configs for test against WLST
    def testServiceBindingParsing()

      configCacheRoot = determineConfigCacheLocation

      JavaBuildpack::Container::Wls::ServiceBindingsReader.createServiceDefinitionsFromFileSet(@wlsCompleteDomainConfigsYml, configCacheRoot, @wlsCompleteDomainConfigsProps)
      JavaBuildpack::Container::Wls::ServiceBindingsReader.createServiceDefinitionsFromBindings(@appServicesConfig, @wlsCompleteDomainConfigsProps)
      logger.debug { "Done generating Domain Configuration Property file for WLST: #{@wlsCompleteDomainConfigsProps}" }
      logger.debug { "--------------------------------------" }

    end


    def download_and_install_wls
      download(@wls_version, @wls_uri) { |file| install file }
    end

    def link_to(source, destination)
      FileUtils.mkdir_p destination
      source.each { |path|
        # Ignore the .java-buildpack log and .java-buildpack subdirectory containing the app server bits
        next if path.to_s[/\.java-buildpack/]
        next if path.to_s[/\.wls/]
        next if path.to_s[/\wlsInstall/]
        (destination + path.basename).make_symlink(path.relative_path_from(destination))
      }
    end

    def wlsDomain
      @domainHome
    end

    def wlsDomainlib
      @domainHome + 'lib'
    end

    def webapps
      @domainAppsDir
    end

    def root
      webapps + APP_NAME
    end

    def web_inf_lib
      @application.root + 'WEB-INF/lib'
    end

    def web_inf?
      (@application.root + 'WEB-INF').exist?
    end

    def wls?
      searchPath = (@application.root).to_s + "/**/weblogic*xml"
      wlsConfigPresent = Dir.glob(searchPath).length > 0

      appWlsConfigCacheExists = (@application.root + APP_WLS_CONFIG_CACHE_DIR).exist?
      isBaseWebApp = web_inf?

      logger.debug { "Running Detection on App: #{@application.root}" }
      logger.debug { "  Checking for presence of #{APP_WLS_CONFIG_CACHE_DIR} folder under root of the App or weblogic deployment descriptors within App" }
      logger.debug { "  Does #{APP_WLS_CONFIG_CACHE_DIR} folder exist under root of the App? : #{appWlsConfigCacheExists}" }
      logger.debug { "  Does  weblogic deployment descriptors exist within App? : #{wlsConfigPresent}" }
      logger.debug { "  Or is it a simple Web Application with WEB-INF folder? : " + isBaseWebApp.to_s }

      (appWlsConfigCacheExists || wlsConfigPresent || web_inf?)
    end

    # Determine which configurations should be used for driving the domain creation - App or buildpack bundled configuration
    def determineConfigCacheLocation

      if (@preferAppConfig)

        # Use the app bundled configuration and domain creation scripts.
        @appConfigCacheRoot

      else

        # Use the buidlpack's bundled configuration and domain creation scripts (under resources/wls)
        # But the jvm and domain configuration files from the app bundle will be used, rather than the buildpack version.
        @buildpackConfigCacheRoot

      end

    end


    def updateDomainConfigFile(wlsDomainConfigFile)


      original = File.open(wlsDomainConfigFile, 'r') { |f| f.read }

      # Remove any existing references to wlsHome or domainPath
      modified = original.gsub(/  wlsHome:.*$\n/, "")
      modified = original.gsub(/  wlsDomainTemplateJar:.*$\n/, "")
      modified = modified.gsub(/  domainPath:.*$\n/, "")
      modified = modified.gsub(/  appName:.*$\n/, "")
      modified = modified.gsub(/  appSrcPath:.*$\n/, "")

      # Add new references to wlsHome and domainPath
      modified << "  wlsHome: #{@wlsHome.to_s}\n"
      modified << "  wlsDomainTemplateJar: #{@wlsDomainTemplateJar.to_s}\n"
      modified << "  domainPath: #{@wlsDomainPath.to_s}\n"
      modified << "  appName: #{APP_NAME}\n"
      modified << "  appSrcPath: #{@domainAppsDir.to_s + "/#{APP_NAME}"}\n"

      File.open(wlsDomainConfigFile, 'w') { |f| f.write modified }

      logger.debug { "Added entry for WLS_HOME to point to #{@wlsHome} in domain config file" }
      logger.debug { "Added entry for DOMAIN_PATH to point to #{@wlsDomainPath} in domain config file" }

    end

    def customizeWLSServerStart(startServerScript, additionalParams)

      withAdditionalEntries = additionalParams + "\r\n" + WLS_SERVER_START_TOKEN
      original = File.open(startServerScript, 'r') { |f| f.read }
      modified = original.gsub(/WLS_SERVER_START_TOKEN/, withAdditionalEntries)
      File.open(startServerScript, 'w') { |f| f.write modified }

      logger.debug { "Modified #{startServerScript} with additional parameters: #{additionalParams} " }

    end

    def modifyJvmTypeInCommEnv()

      Dir.glob("#{@wlsInstall}/**/commEnv.sh").each { |commEnvScript|

        original = File.open(commEnvScript, 'r') { |f| f.read }
        modified = original.gsub(/#{CLIENT_VM}/, SERVER_VM)
        File.open(commEnvScript, 'w') { |f| f.write modified }
      }

      logger.debug { "Modified commEnv.sh files to use '-server' vm from the default '-client' vm!!" }

    end

    def setMiddlewareHomeInConfigureScript(configureScript)

      original = File.open(configureScript, 'r') { |f| f.read }

      updatedJavaHomeEntry        = "JAVA_HOME=\"#{@javaHome}\""
      updatedBeaHomeEntry        = "BEA_HOME=\"#{@wlsInstall}\""
      updatedMiddlewareHomeEntry = "MW_HOME=\"#{@wlsInstall}\""

      # Switch to Bash as script execution fails for those with if [[ ...]] conditions
      # when conigure.sh script tries to check for MW_HOME/BEA_HOME...
      shell_script_begin_marker = "#!/bin/sh"
      bash_shell_script_marker = "#!/bin/bash"

      newVariablesInsert = "#{bash_shell_script_marker}\n#{updatedJavaHomeEntry}\n#{updatedBeaHomeEntry}\n#{updatedMiddlewareHomeEntry}\n"

      modified = original.gsub(/#{shell_script_begin_marker}/, newVariablesInsert)

      File.open(configureScript, 'w') { |f| f.write modified }
      logger.debug { "Modified #{configureScript} to set MW_HOME variable!!" }

    end

    def setMiddlewareHomeInCommEnv()

      Dir.glob("#{@wlsInstall}/**/commEnv.sh").each { |commEnvScript|

        original = File.open(commEnvScript, 'r') { |f| f.read }

        updatedBeaHomeEntry        = "BEA_HOME=\"#{@wlsInstall}\""
        updatedMiddlewareHomeEntry = "MW_HOME=\"#{@wlsInstall}\""

        modified = original.gsub(/#{BEA_HOME_TEMPLATE}/, updatedBeaHomeEntry)
        modified = modified.gsub(/#{MW_HOME_TEMPLATE}/, updatedMiddlewareHomeEntry)

        File.open(commEnvScript, 'w') { |f| f.write modified }
      }

      logger.debug { "Modified commEnv.sh files to set MW_HOME variable!!" }

    end

    def linkJarsToDomain()

      @wlsPreClasspathJars         = Dir.glob("#{@appConfigCacheRoot}/#{WLS_PRE_JARS_CACHE_DIR}/*")
      @wlsPostClasspathJars        = Dir.glob("#{@appConfigCacheRoot}/#{WLS_POST_JARS_CACHE_DIR}/*")

      logger.debug { "Linking pre and post jar directories relative to the Domain" }

      system "/bin/ln -s #{@appConfigCacheRoot}/#{WLS_PRE_JARS_CACHE_DIR} #{@domainHome}/#{WLS_PRE_JARS_CACHE_DIR} 2>/dev/null"
      system "/bin/ln -s #{@appConfigCacheRoot}/#{WLS_POST_JARS_CACHE_DIR} #{@domainHome}/#{WLS_POST_JARS_CACHE_DIR} 2>/dev/null"

    end

    def logger
      JavaBuildpack::Logging::LoggerFactory.get_logger Weblogic
    end

    def create_dodeploy
      FileUtils.touch(webapps + 'REDEPLOY')
    end

    def parameterize_http_port
      #standalone_config = "#{wls_home}/standalone/configuration/standalone.xml"
      #original = File.open(standalone_config, 'r') { |f| f.read }
      #modified = original.gsub(/<socket-binding name="http" port="8080"\/>/, '<socket-binding name="http" port="${http.port}"/>')
      #File.open(standalone_config, 'w') { |f| f.write modified }
    end

    def disable_welcome_root
      #standalone_config = "#{wls_home}/standalone/configuration/standalone.xml"
      #original = File.open(standalone_config, 'r') { |f| f.read }
      #modified = original.gsub(/<virtual-server name="default-host" enable-welcome-root="true">/, '<virtual-server name="default-host" enable-welcome-root="false">')
      #File.open(standalone_config, 'w') { |f| f.write modified }
    end

    def disable_console
      #standalone_config = "#{wls_home}/standalone/configuration/standalone.xml"
      #original = File.open(standalone_config, 'r') { |f| f.read }
      #modified = original.gsub(/<virtual-server name="default-host" enable-welcome-root="true">/, '<virtual-server name="default-host" enable-welcome-root="false">')
      #File.open(standalone_config, 'w') { |f| f.write modified }
    end

    def windows?
      (/cygwin|mswin|mingw|bccwin|wince|emx/ =~ RbConfig::CONFIG['host_os']) != nil
    end

    def mac?
      (/darwin/ =~ RbConfig::CONFIG['host_os']) != nil
    end

    def sun?
      (/sunos|solaris/ =~ RbConfig::CONFIG['host_os']) != nil
    end

    def unix?
      !windows?
    end

    def linux?
      unix? and not mac? and not solaris?
    end

  end

end

