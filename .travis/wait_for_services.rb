#!/usr/bin/env ruby
require 'net/http'
require 'json'

services = {
  'hawkular-services' => {
    url: 'http://localhost:8080/hawkular/status',
    is_ready: -> (response) { response.code == '200' }
  },
  'metrics' => {
    url: 'http://localhost:8080/hawkular/metrics/status',
    is_ready: -> (response) { response.code == '200' && JSON.parse(response.body)['MetricsService'] == 'STARTED' }
  },
  'alerts' => {
    url: 'http://localhost:8080/hawkular/alerts/status',
    is_ready: -> (response) { response.code == '200' && JSON.parse(response.body)['status'] == 'STARTED' }
  }
}

services.each do |name, service|
  loop do
    uri = URI(service[:url])
    begin
      response = Net::HTTP.get_response(uri)
      break if service[:is_ready].call(response)
      puts "Waiting for: #{name}"
    rescue
      puts 'Waiting for Hawkular-Services to accept connections'
    end
    sleep 5
  end
end
puts 'Waiting 2 minutes for agent to complete it\'s first round...'
sleep 120
puts 'Hawkular-services started successfully... '