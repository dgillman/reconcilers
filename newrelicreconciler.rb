#!/usr/bin/env ruby

require './chef.rb'
require './newrelic.rb'

class NewRelicReconciler
  def initialize(conf = {})
    @chef = Chef.new
    @newrelic = NewRelic::NewRelic.new
  end

  def monitored_servers(chef_environment)
    chef_nodes = @chef.nodes(chef_environment)
    puts "chef nodes: #{chef_nodes.size}"
    nr_servers = @newrelic.servers
    puts "newrelic servers: #{nr_servers.size}"
    nr_by_host = {}
    nr_servers.each { |server|
      nr_by_host[server.host] = server
    }
    chef_nodes.each { |cs|
      hostname = cs.automatic['hostname']
      if nr_by_host.has_key?(hostname)
        nr_server = nr_by_host[hostname]
        puts "#{cs.name} is NewRelic ##{nr_server.id}"
      else
        puts "#{cs.name} has no NewRelic server"
      end
    }
  end
end

if __FILE__ == $0

  r = NewRelicReconciler.new
  r.monitored_servers('production')

end
