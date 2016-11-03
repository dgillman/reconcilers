#!/usr/bin/env ruby

require 'chef-api'
require 'inifile'
require 'pp'

class Chef
  def initialize(conf = {})
    @nodes = {}
    config_chef conf
  end

  def chef
    unless @chef
      @chef = ChefAPI::Connection.new
    end
    @chef
  end

  def environments
    chef.environments.map { |environment| environment.name }
  end

  def node(id)
    chef.nodes.fetch(id)
  end

  def nodes(environment)
    unless @nodes[environment]
      e = chef.environments.fetch(environment)
      @nodes[environment] = e.nodes
    end
    @nodes[environment]
  end

  def delete_node(id)
    chef.nodes.delete(id)
  end

  def self.usage
    puts "Usage: #{__FILE__} chef_environment"
  end

private

  def config_chef(conf = {})
    @chefpath = conf.fetch(:chefpath, ENV['HOME'] + '/.chef/knife.ini')
    @chefini = IniFile.load(@chefpath)
    @chefsection = conf.fetch(:chefsection, 'global')
    fail "config file #{@chefpath} does not have a section '#{@chefsection}'" unless @chefini.has_section?(@chefsection)

    @chef_params = @chefini[@chefsection]
    ChefAPI.configure do |config|
      config.endpoint = @chef_params['chef_server_url']

      config.flavor = :enterprise
      config.client = @chef_params['node_name']
      config.key    = @chef_params['client_key']

      config.ssl_verify = false
      config.log_level = :error
    end
  end
end

if __FILE__ == $0


end
