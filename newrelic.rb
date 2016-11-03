#!/usr/bin/env ruby

require 'json'
require 'pp'
require 'rest-client'

module NewRelic

  class AlertPolicy
    attr_reader :id, :name, :incident_preference, :created_at, :updated_at

    def initialize(conf={})
      @id = conf['id']
      @name = conf['name']
      @incident_preference = conf['incident_preference']
      @created_at = milliseconds_to_date(conf['created_at'])
      @updated_at = milliseconds_to_date(conf['updated_at'])
    end

  private
    def milliseconds_to_date(milliseconds)
      sec = (milliseconds.to_f / 1000).to_s
      Date.strptime(sec, '%s')
    end
  end

  class Server

    attr_reader :id, :account_id, :name, :host, :reporting, :last_reported_at, :summary

    def initialize(conf={})
      @id = conf['id']
      @account_id = conf['account_id']
      @name = conf['name']
      @host = conf['host']
      @reporting = conf['reporting'] || false
      @last_reported_at = conf.has_key?('last_reported_at') ?
                            Date.rfc3339(conf['last_reported_at']) : 
                            nil
      @summary = conf['summary'] ? conf['summary'].dup : {}
    end

  end

  class Condition
    attr_reader :id, :type, :name, :enabled, :entities, :metric, :terms

    class Term
      attr_reader :duration, :operator, :priority, :threshold, :time_function
      def initialize(conf={})
        @duration = conf['duration']
        @operator = conf['operator']
        @priority = conf['priority']
        @threshold = conf['threshold']
        @time_function = conf['time_function']
      end
    end

    def initialize(conf={})
      @id = conf['id']
      @type = conf['type']
      @name = conf['name']
      @enabled = conf['enabled']
      @entities = conf['entities']
      @metric = conf['metric']

      @terms = []
      conf['terms'].each { |jterm|
        @terms << Term.new(jterm)
      }
    end
  end

  class NewRelic
    def initialize
    end

    def servers
      unless @servers
        @servers = []
        page = 1
        loop do
          result = RestClient.get "https://api.newrelic.com/v2/servers.json?page=#{page}", {'X-Api-Key': api_key}
          json = JSON.parse(result.body)

          json_servers = json['servers']
          break if json_servers.size < 1
          json_servers.each { |s|
            @servers << Server.new(s)
          }
          page = page + 1
        end 
      end

      @servers
    end

    def stale_servers
      not_reporting = []

      servers.each { |s|
        server = Server.new s
        not_reporting << server unless server.reporting
      }

      not_reporting.sort! { |a,b| a.last_reported_at <=> b.last_reported_at }
    end

    def delete_server(server_id)
      result = RestClient::Request.execute(method: :delete,
                  url: "https://api.newrelic.com/v2/servers/#{server_id}.json",
                  headers: {'X-Api-Key': api_key})
    end

    def conditions_for_policy(policy_id)
      result = RestClient::Request.execute(method: :get,
                  url: 'https://api.newrelic.com/v2/alerts_conditions.json',
                  headers: {params: {policy_id: policy_id}, 'X-Api-Key': api_key})
      json = JSON.parse(result.body)
      conditions = []
      json['conditions'].each { |condition|
        conditions << Condition.new(condition)
      }
      conditions
    end

    def alert_policies
      result = RestClient.get 'https://api.newrelic.com/v2/alerts_policies.json', {'X-Api-Key': api_key}
      policies = JSON.parse(result.body)
      puts policies.inspect
      @alert_policies = []
      policies['policies'].each { |policy|
        @alert_policies << AlertPolicy.new(policy)
      }
      @alert_policies
    end

    def alert_policy(name)
      result = RestClient::Request.execute(method: :get,
                  url: 'https://api.newrelic.com/v2/alerts_policies.json',
                  headers: {params: {'filter[name]': name}, 'X-Api-Key': api_key})
      json = JSON.parse(result.body)
      policies = json['policies']
      size = policies.size
      raise "ambiguous result finding policy with name #{name}" if size > 1
      size == 1 ? AlertPolicy.new(policies.first) : nil
    end

  private

    def api_key
      @api_key ||= begin
        keyfile = "#{ENV['HOME']}/.newrelic/api.key"
        #raise "Cannot read #{keyfile}" unless File.readable?(keyfile)
        File.read(keyfile)
      rescue Exception => e
        fail "Error processing #{keyfile}"
      end
    end
  end

end

if __FILE__ == $0

  nr = NewRelic::NewRelic.new

  policy = nr.alert_policy('General Server Health')
  puts policy.name
  conditions = nr.conditions_for_policy(policy.id)
  puts conditions.map {|condition| condition.name}.join(',')
end
