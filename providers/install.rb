#
# Cookbook Name:: redisio
# Provider::install
#
# Copyright 2012, Brian Bianco <brian.bianco@gmail.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

action :run do
  @tarball = "#{new_resource.base_name}#{new_resource.version}.#{new_resource.artifact_type}"

  unless ( current_resource.version == new_resource.version || (redis_exists? && new_resource.safe_install) )
    Chef::Log.info("Installing Redis #{new_resource.version} from source")
    download
    unpack
    build
    install
  end
  configure
end

def download
  Chef::Log.info("Downloading redis tarball from #{new_resource.download_url}")
  remote_file "#{new_resource.download_dir}/#{@tarball}" do
    source new_resource.download_url
  end
end

def unpack
  case new_resource.artifact_type
    when "tar.gz",".tgz"
      execute "cd #{new_resource.download_dir} && tar zxf #{@tarball}"
    else
      raise Chef::Exceptions::UnsupportedAction, "Current package type #{new_resource.artifact_type} is unsupported"
  end
end

def build
  execute"cd #{new_resource.download_dir}/#{new_resource.base_name}#{new_resource.version} && make clean && make"
end

def install
  execute "cd #{new_resource.download_dir}/#{new_resource.base_name}#{new_resource.version} && make install"

  if node["platform"] == "smartos"
    %w[redis-benchmark redis-check-aof redis-check-dump redis-cli redis-server].each do |cmd|
      link "/opt/local/bin/#{cmd}" do
        to "/usr/local/bin/#{cmd}"
      end
    end
  end

  new_resource.updated_by_last_action(true)
end

def configure
  base_piddir = new_resource.base_piddir
  version_hash = RedisioHelper.version_to_hash(new_resource.version)

  #Setup a configuration file and init script for each configuration provided
  new_resource.servers.each do |current_instance|

    #Retrieve the default settings hash and the current server setups settings hash.
    current_instance_hash = current_instance.to_hash
    current_defaults_hash = new_resource.default_settings.to_hash

    #Merge the configuration defaults with the provided array of configurations provided
    current = current_defaults_hash.merge(current_instance_hash)
    #Name of the service and all config files
    current_server_id      = RedisioHelper.redis_server_id(current)
    current_service_name   = RedisioHelper.redis_service_name(current)

    recipe_eval do
      piddir = "#{base_piddir}/#{current_server_id}"
      aof_file = "#{current['datadir']}/appendonly-#{current_server_id}.aof"
      rdb_file = "#{current['datadir']}/dump-#{current_server_id}.rdb"

      #Create the owner of the redis data directory
      user current['user'] do
        comment 'Redis service account'
        supports :manage_home => true
        home current['homedir']
        shell current['shell']
      end
      #Create the redis configuration directory
      directory current['configdir'] do
        owner 'root'
        group 'root'
        mode '0755'
        recursive true
        action :create
      end
      #Create the instance data directory
      directory current['datadir'] do
        owner current['user']
        group current['group']
        mode '0775'
        recursive true
        action :create
      end
      #Create the pid file directory
      directory piddir do
        owner current['user']
        group current['group']
        mode '0755'
        recursive true
        action :create
      end
      #Create the log directory if syslog is not being used
      directory ::File.dirname("#{current['logfile']}") do
        owner current['user']
        group current['group']
        mode '0755'
        recursive true
        action :create
        only_if { current['syslogenabled'] != 'yes' && current['logfile'] && current['logfile'] != 'stdout' }
      end
      #Create the log file is syslog is not being used
      if current['logfile']
        file current['logfile'] do
          owner current['user']
          group current['group']
          mode '0644'
          backup false
          action :touch
          only_if { current['logfile'] != 'stdout' }
        end
      end
      #Set proper permissions on the AOF or RDB files
      file aof_file do 
        owner current['user']
        group current['group']
        mode '0644'
        only_if { current['backuptype'] == 'aof' || current['backuptype'] == 'both' }
        only_if { ::File.exists?(aof_file) }
      end
      file rdb_file  do
        owner current['user']
        group current['group']
        mode '0644'
        only_if { current['backuptype'] == 'rdb' || current['backuptype'] == 'both' }
        only_if { ::File.exists?(rdb_file) }
      end
      #Lay down the configuration files for the current instance
      template "#{current['configdir']}/#{current_server_id}.conf" do
        source 'redis.conf.erb'
        cookbook 'redisio'
        owner current['user']
        group current['group']
        mode '0644'
        variables({
          :version                => version_hash,
          :piddir                 => piddir,
          :port                   => current['port'],
          :address                => current['address'],
          :databases              => current['databases'],
          :backuptype             => current['backuptype'],
          :backupprefix           => current['backupprefix'],
          :dbfilename             => RedisioHelper.dbfilename(current),
          :datadir                => current['datadir'],
          :timeout                => current['timeout'],
          :loglevel               => current['loglevel'],
          :logfile                => current['logfile'],
          :syslogenabled          => current['syslogenabled'],
          :syslogfacility         => current['syslogfacility'],
          :save                   => current['save'],
          :slaveof                => current['slaveof'],
          :masterauth             => current['masterauth'],
          :slaveservestaledata    => current['slaveservestaledata'], 
          :replpingslaveperiod    => current['replpingslaveperiod'],
          :repltimeout            => current['repltimeout'],
          :requirepass            => current['requirepass'],
          :maxclients             => current['maxclients'],
          :maxmemory              => current['maxmemory'],
          :maxmemorypolicy        => current['maxmemorypolicy'],
          :maxmemorysamples       => current['maxmemorysamples'],
          :appendfsync            => current['appendfsync'],
          :noappendfsynconrewrite => current['noappendfsynconrewrite'],
          :aofrewritepercentage   => current['aofrewritepercentage'] ,
          :aofrewriteminsize      => current['aofrewriteminsize'],
          :includes               => current['includes'],
          :redis_server_id        => RedisioHelper.redis_server_id(current),
          :hashmaxziplistentries  => current['hashmaxziplistentries'],
          :zsetmaxziplistentries  => current['zsetmaxziplistentries']
        })
      end


      case node['redisio']['init_type']
      when 'init'
        template "/etc/init.d/#{current_service_name}" do
          source 'redis.init.erb'
          cookbook 'redisio'
          owner 'root'
          group 'root'
          mode '0755'
          variables({
            :port => current['port'],
            :address => current['address'],
            :user => current['user'],
            :configdir => current['configdir'],
            :piddir => piddir,
            :requirepass => current['requirepass'],
            :platform => node['platform']
          })
        end
      when 'smf'
        smf current_service_name do
          user 'root'
          group 'root'
          project current['smf_project']

          dependencies current['smf_dependencies']

          start_command "/usr/local/bin/redis-server #{current['configdir']}/#{current_server_id}.conf &"
          start_timeout 60
          stop_command ':kill' # redis will issue a synchronous save before shutting down
          stop_timeout 300

          working_directory current['configdir']
        end
      end
    end
  end # servers each loop
end

def redis_exists?
  exists = Chef::ShellOut.new("which redis-server")
  exists.run_command
  exists.exitstatus == 0 ? true : false 
end

def version
  if redis_exists?
    redis_version = Chef::ShellOut.new("redis-server -v")
    redis_version.run_command
    version = redis_version.stdout[/version (\d*.\d*.\d*)/,1] || redis_version.stdout[/v=(\d*.\d*.\d*)/,1]
    Chef::Log.info("The Redis server version is: #{version}")
    return version.gsub("\n",'')
  end
  nil
end

def load_current_resource
  @current_resource = Chef::Resource::RedisioInstall.new(new_resource.name)
  @current_resource.version(version)
  @current_resource
end
