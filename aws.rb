#!/usr/bin/env ruby

require 'aws-sdk'
require 'json'
require 'pp'

class EC2
  @@clients = {}

  attr_reader :profile, :region, :client

  def initialize(profile, region)
    @profile = profile
    @region = region
    @client = Aws::EC2::Client.new(
      profile: profile,
      region: region,
      ssl_verify_peer: false
    )
  end

  def instances
    instances = []
    result = @client.describe_instances
    result.reservations.each { |resv|
      resv.instances.each { |instance|
        instances << instance
      }
    }
    instances
  end

  def self.client(profile, region)
    key = profile + '_' + region
    unless @@clients.has_key?(key)
      @@clients[key] = EC2.new(profile, region) 
    end
    @@clients[key]
  end

end

if __FILE__ == $0

  ec2 = EC2.client('acme', 'us-west-1')

  pp ec2.instances

end
