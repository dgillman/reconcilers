#!/usr/bin/env ruby

require './aws.rb'
require './chef.rb'
require './newrelic.rb'
require 'date'
require 'logger'
require 'pp'

class AwsReconciler

  attr_reader :servers, :log, :instance_ids

  def initialize(conf = {})
    @log = Logger.new(conf.fetch('logfile', './reconciler.log'))
    @log.level = conf.fetch('loglevel', Logger::WARN)
    @chef = Chef.new
    @newrelic = NewRelic::NewRelic.new
    @conf = conf
    @servers = {}
    @hosts = {}
    @invalid_chef_nodes = []
    @instance_ids = {}
    ec2_data
    chef_data
    newrelic_data
  end

  def server(ip)
    raise "ip cannot be nil" unless ip
    unless @servers.has_key?(ip)
      @log.debug "creating server record for #{ip}"
      @servers[ip] = {'ip' => ip}
    end
    @servers[ip]
  end

private
  def ec2_data
    @conf['aws']['accounts'].each { |account_conf|
      account = account_conf['id']
      account_conf['regions'].each { |region|
        @log.debug "querying instances in #{account} in #{region}"
        ec2 = EC2.client(account, region)
        ec2.instances.each { |instance|
          next if instance.state.name.eql?('terminated')
          aws_data = {
            'account' => account,
            'region' => region,
            'instance_id' => instance.instance_id
          }
          @instance_ids[instance.instance_id] = aws_data
          ip = instance.private_ip_address

          if ip.nil?
            @log.error "IP not found for instance:\n#{instance.inspect}"
            next
          end
          @log.debug "processing AWS instance with IP: #{ip}"
          server(ip)['aws'] = aws_data
          hostname = instance.private_dns_name
          if hostname
            hostname = hostname.split('.')[0]
            @log.debug "hostname: #{hostname}"
            @log.error "duplicate hostname - old entry points to #{@hosts[hostname][ip]}" if @hosts[hostname]
            @hosts[hostname] = server(ip)
          end
        }
      }
    }
  end

  def chef_data
    orphans = []
    environments = (@conf['chef']['environments'] if @conf.has_key?('chef')) || @chef.environments
    environments.each { |env|
      @log.debug "querying nodes in environment #{env}"
      nodes = @chef.nodes(env)
      nodes.each { |node|
        unless validate_chef_node(node)
          @log.warn "invalid node will be deleted from Chef"
          orphans << node
          next
        end
        chef_data = {
          'name' => node.name,
          'environment' => env,
          'run_list' => node.run_list
        }
        ip = node.automatic['ipaddress']
        @log.debug "processing chef node with IP: #{ip}"
        server(ip)['chef'] = chef_data
        fail "assignment issue" if server(ip)['chef'] != chef_data 
        host = node.name.split('.')[0]
        @hosts[host] = server(ip)
      }
    }
    File.open('chef_orphans.csv','w') { |io|
      io.puts "'name','host','instance_id','environment','run_list','checkin'"
      orphans.each { |orphan|
        name = orphan.name
        host = ''
        instance_id=''
        environment = ''
        run_list = ''
        checkin = ''
        if orphan.automatic.size > 0
          host = orphan.automatic['hostname']
          if orphan.automatic['ec2']
            instance_id = orphan.automatic['ec2']['instance_id']
            if @instance_ids[instance_id]
              @log.error "failed to match chef node with existing instance: #{instance_id} - skipping orphaned chef node"
              next
            end
          end
          environment = orphan.chef_environment
          run_list = orphan.run_list
          checkin = Time.at(orphan.automatic['ohai_time'])
        end
        io.puts "'#{name}','#{host}','#{instance_id}','#{environment}','#{run_list}','#{checkin}'"
        #@chef.delete_node(orphan.id)
      }
    }
  end

  def validate_chef_node(node)
    if node.automatic && node.automatic['ipaddress']
      updated = Time.at(node.automatic['ohai_time'])
      expiry = Time.now - (45 * 24 * 60 * 60)
      if updated < expiry
        @log.error "#{node.name} has not been updated in over 45 days"
        if node.automatic['ec2'] && @instance_ids.has_key?(node.automatic['ec2']['instance_id'])
          msg = "#{node.name} is a valid AWS instance and is not running chef-client"
          $stderr.puts msg
          @log.error msg
          true
        else
          false
        end
      else
        true
      end
    else
      @log.error "#{node.name} never checked in"
      false
    end
  end

  def newrelic_data
    nr_servers = @newrelic.servers
    orphans = []
    nr_servers.each { |nr_server|
      hostname = nr_server.host
      unless hostname
        @log.error "server has no host name: #{nr_server.inspect}"
        next
      end

      hostname = hostname.split('.')[0]
      server_record = @hosts[hostname]

      unless server_record
        @log.error "no server record matches NewRelic server #{hostname}"
        orphans << nr_server
        next
      end

      @log.debug "#{nr_server.host} is #{server_record['ip']}"
      nr_data = {
        'id' => nr_server.id,
        'account_id' => nr_server.account_id,
        'name' => nr_server.name,
        'host' => nr_server.host,
        'reporting' => nr_server.reporting,
        'last_reported_at' => nr_server.last_reported_at
      }

      server_record['newrelic'] = nr_data
    }

    expiry = Date.today - 45
    File.open('./newrelic_orphans.csv', 'w') { |io|
      io.puts "'id','host','reporting','last report'"
      orphans.each { |orphan|
        if orphan.reporting
          $stderr.puts "#{orphan.id}(#{orphan.host}) is running but failed to match AWS servers"
          next
        end
        if orphan.last_reported_at > expiry
          $stderr.puts "#{orphan.host} has reported within 45 days"
          next
        end
        @log.debug "removing server #{orphan.id}"
        @newrelic.delete_server(orphan.id)
        io.puts "'#{orphan.id}','#{orphan.host}','#{orphan.reporting}','#{orphan.last_reported_at}'"
      }
    }
  end

end

if __FILE__ == $0

  r = AwsReconciler.new(
    'aws' => {
      'accounts' => [
        { 'id' => 'acme', 'regions' => ['us-west-1'] }
      ]
    },
    'loglevel' => Logger::DEBUG)

  servers = r.servers

  File.open('./cloud_assets.log', 'w') { |io|
    io.puts "'ip','chef name','chef run_list','aws account','aws instance','newrelic server id'"
    ips = servers.keys.sort
    servers.each { |ip, server|
      chef_name = ''
      chef_run_list = ''
      aws_account = ''
      aws_instance_id = ''
      newrelic_id = ''
      if server.has_key?('chef')
        chef_name = server['chef']['name']
        chef_run_list = server['chef']['run_list']
      else
        r.log.error "#{ip} has no chef info"
      end
      if server.has_key?('aws')
        aws_account = server['aws']['account']
        aws_instance_id = server['aws']['instance_id']
      else
        r.log.error "#{ip} has no aws info"
      end
      if server.has_key?('newrelic')
        newrelic_id = server['newrelic']['id']
      else
        r.log.error "#{ip} has no newrelic info"
      end
      io.puts "'#{ip}','#{chef_name}','#{chef_run_list}','#{aws_account}','#{aws_instance_id}','#{newrelic_id}'"
    }
  }

end
