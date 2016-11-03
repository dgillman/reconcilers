#!/usr/bin/env ruby

require 'aws-sdk'
require 'chef-api'
require 'inifile'
require 'json'

class Reconciler
  def initialize(conf = {})
    @ec2_conns = {}
    config_aws conf
    config_chef conf
  end

  def ec2(account, region)
    key = account + '_' + region
    params = @aws_params[account]
    unless @ec2_conns.has_key?(key)
      @ec2_conns[key] = Aws::EC2::Client.new(
        region: region,
	      credentials: Aws::Credentials.new(params['aws_access_key_id'], params['aws_secret_access_key']),
        ssl_verify_peer: false
      )
    end
    @ec2_conns[key]
  end

  def chef
    if @chef.nil?
      @chef = ChefAPI::Connection.new
    end
    @chef
  end

  def reconcile(environment)
    puts "reconciling #{environment} and #{aws_region}\n\n"
    e = chef.environments.fetch(environment)
    nodes = {}
    e.nodes.each do |node|
      nodes[node.name] = node
    end
    instance_query = {
      filters: [
        {
          name: 'private-dns-name',
          values: nodes.keys
        }
      ]
    }

    @aws_accounts.each { |aws|
      ec2 = aws["region"]["ec2"]
      result = ec2.describe_instances(instance_query)
      result.reservations.each do |resv|
        nodes.delete(resv.instances.first.private_dns_name)
      end
    }


    if nodes.size > 0
      nodes.each do |k, v|
        puts "Missing instance for #{k}"
      end
    else
      puts "No missing instances"
    end
  end

  def self.error(msg)
    $stderr.puts(msg)
  end

  def self.usage
    puts "Usage: #{__FILE__} aws_account chef_environment aws_region"
  end

  def self.configure(json_path='./env/default.json')
    unless File.readable?(json_path)
      error "cannot read configuration file #{json_path}. supply or correct the config file parameter"
      usage
      exit 1
    end

    json = JSON.parse(File.read(json_path))
    Reconciler.new(json)
  end

private
  def config_aws(conf = {})
    @awspath = conf.fetch(:awspath, ENV['HOME'] + '/.aws/credentials')
    @awsini = IniFile.load(@awspath)
    @aws_params = {}
    @aws_accounts = {}
    conf['aws']['accounts'].each { |account|
      @aws_params[account['id']].merge!(@awsini['global'])
      @aws_params[account['id']].merge!(@awsini[account['id']])

      acct_detail = {
        "id" => account["id"],
        "regions" = {}
      }
      account["regions"].each { |region|
        acct_detail[region] = {
          "ec2" = ec2(account["id"], region)
        }
      }
      @aws_accounts << acct_detail
    }
  end

  def config_chef(conf = {})
    chef_conf = conf["chef"]
    @chefpath = chef_conf.fetch(:chefpath, ENV['HOME'] + '/.chef/knife.ini')
    @chefini = IniFile.load(@chefpath)
    @chefsection = chef_conf.fetch(:chefsection, 'global')
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

  if ARGV.length < 3
    $stderr.puts 'ERROR: not enough params'
    Reconciler.usage
    exit 1
  end
  aws_account = ARGV[0]
  chef_environment = ARGV[1]
  aws_region = ARGV[2]

  conf = {
    awssection: aws_account
  }

  r = Reconciler.new conf
  r.reconcile(chef_environment, aws_region)

end
