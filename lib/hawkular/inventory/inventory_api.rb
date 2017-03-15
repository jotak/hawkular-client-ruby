require 'hawkular/base_client'
require 'websocket-client-simple'
require 'json'

require 'hawkular/inventory/entities'

# Inventory module provides access to the Hawkular Inventory REST API.
# @see http://www.hawkular.org/docs/rest/rest-inventory.html
#
# @note While Inventory supports 'environments', they are not used currently
#   and thus set to 'test' as default value.
module Hawkular::Inventory
  # Client class to interact with Hawkular Inventory
  class Client < Hawkular::BaseClient
    attr_reader :version

    # Create a new Inventory Client
    # @param entrypoint [String] base url of Hawkular-inventory - e.g
    #   http://localhost:8080/hawkular/inventory
    # @param credentials [Hash{String=>String}] Hash of username, password, token(optional)
    # @param options [Hash{String=>String}] Additional rest client options
    def initialize(entrypoint = nil, credentials = {}, options = {})
      entrypoint = normalize_entrypoint_url entrypoint, 'hawkular/metrics'
      @entrypoint = entrypoint
      super(entrypoint, credentials, options)
      version = fetch_version_and_status['Implementation-Version']
      @version = version.scan(/\d+/).map(&:to_i)
    end

    # Creates a new Inventory Client
    # @param hash [Hash{String=>Object}] a hash containing base url of Hawkular-inventory - e.g
    #   entrypoint: http://localhost:8080/hawkular/inventory
    # and another sub-hash containing the hash with username[String], password[String], token(optional)
    def self.create(hash)
      fail 'no parameter ":entrypoint" given' if hash[:entrypoint].nil?
      hash[:credentials] ||= {}
      hash[:options] ||= {}
      Client.new(hash[:entrypoint], hash[:credentials], hash[:options])
    end

    # List feeds in the system
    # @return [Array<String>] List of feed ids
    def list_feeds
      ret = http_get('/strings/tags/module:inventory,feed:*')
      ret['feed']
    end

    # List resource types. If no feed_id is given all types are listed
    # @param [String] feed_id The id of the feed the type lives under. Can be nil for feedless types
    # @return [Array<ResourceType>] List of types, that can be empty
    def list_resource_types(feed_id)
      fail 'Feed id must be given' unless feed_id
      the_feed = hawk_escape_id feed_id
      ret = http_post(
        '/strings/raw/query',
        fromEarliest: true,
        limit: 1,
        order: 'DESC',
        tags: "module:inventory,type:rt,feed:#{the_feed}")
      ret.map do |rt|
        json = extract_metric_json(rt)
        unless json.nil?
          root_hash = extract_entity_hash("/f;#{feed_id}", json['type'], json, false)
          ResourceType.new(root_hash)
        end
      end
    end

    # Return all resources for a feed
    # @param [String] feed_id Id of the feed that hosts the resources
    # @param [Boolean] fetch_properties Should the config data be fetched too
    # @return [Array<Resource>] List of resources, which can be empty.
    def list_resources_for_feed(feed_id, fetch_properties = false, filter = {})
      fail 'Feed id must be given' unless feed_id
      the_feed = hawk_escape_id feed_id
      ret = http_post(
        '/strings/raw/query',
        fromEarliest: true,
        limit: 1,
        order: 'DESC',
        tags: "module:inventory,type:r,feed:#{the_feed}"
      )
      to_filter = ret.map do |r|
        json = extract_metric_json(r)
        unless json.nil?
          root_hash = extract_entity_hash("/f;#{feed_id}", json['type'], json, fetch_properties)
          Resource.new(root_hash)
        end
      end
      filter_entities(to_filter, filter)
    end

    # List the resources for the passed resource type. The representation for
    # resources under a feed are sparse and additional data must be retrieved separately.
    # It is possible though to also obtain runtime properties by setting #fetch_properties to true.
    # @param [String] resource_type_path Canonical path of the resource type. Can be obtained from {ResourceType}.path.
    #   Must not be nil. The tenant_id in the canonical path doesn't have to be there.
    # @param [Boolean] fetch_properties Shall additional runtime properties be fetched?
    # @return [Array<Resource>] List of resources. Can be empty
    def list_resources_for_type(resource_type_path, fetch_properties = false)
      path = resource_type_path.is_a?(CanonicalPath) ? resource_type_path : CanonicalPath.parse(resource_type_path)
      resource_type_id = path.resource_type_id
      feed_id = path.feed_id
      fail 'Feed id must be given' unless feed_id
      fail 'Resource type must be given' unless resource_type_id
      # First step: get all resource paths for given type. This call returns metric definitions
      ret = http_get("/metrics?type=string&tags=module:inventory,type:r,feed:#{feed_id},rt.#{resource_type_id}:^$")
      unless ret.empty?
        ret = http_post(
          '/strings/raw/query',
          fromEarliest: true,
          limit: 1,
          order: 'DESC',
          ids: ret.map { |m| m['id'] }
        )
      end
      ret.map do |r|
        json = extract_metric_json(r)
        unless json.nil?
          root_hash = extract_entity_hash("/f;#{feed_id}", json['type'], json, fetch_properties)
          Resource.new(root_hash)
        end
      end
    end

    # Obtain the child resources of the passed resource. In case of a WildFly server,
    # those would be Datasources, Deployments and so on.
    # @param [String] parent_res_path Canonical path of the resource to obtain children from.
    # @param [Boolean] recursive Whether to fetch also all the children of children of ...
    # @return [Array<Resource>] List of resources that are children of the given parent resource.
    #   Can be empty
    def list_child_resources(parent_res_path, recursive = false)
      path = parent_res_path.is_a?(CanonicalPath) ? parent_res_path : CanonicalPath.parse(parent_res_path)
      feed_id = path.feed_id
      fail 'Feed id must be given' unless feed_id
      entity_hash = get_raw_entity_hash(path)
      extract_child_resources([], path.to_s, entity_hash, recursive)
    end

    # Return the resource object for the passed path
    # @param [String] resource_path Canonical path of the resource to fetch.
    # @param [Boolean] fetch_properties Should the resource config data be fetched?
    def get_resource(resource_path, fetch_properties = true)
      path = resource_path.is_a?(CanonicalPath) ? resource_path : CanonicalPath.parse(resource_path)
      raw_hash = get_raw_entity_hash(path)
      return if raw_hash.nil?
      entity_hash = extract_entity_hash(path.up, 'resource', raw_hash, fetch_properties)
      Resource.new(entity_hash)
    end

    # Return version and status information for the used version of Hawkular-Inventory
    # @return [Hash{String=>String}]
    #         ('Implementation-Version', 'Built-From-Git-SHA1', 'Status')
    def fetch_version_and_status
      http_get('/status')
    end

    private

    def filter_entities(entities, filter)
      entities.select do |entity|
        found = true
        if filter.empty?
          found = true
        else
          found = false unless filter[:type] == (entity.type) || filter[:type].nil?
          found = false unless filter[:match].nil? || entity.id.include?(filter[:match])
        end
        found
      end
    end

    def extract_metric_json(metric)
      extract_datapoints_json(metric['data'])
    end

    def extract_datapoints_json(datapoints)
      JSON.parse(datapoints[0]['value']) unless (datapoints.empty?) || (datapoints[0]['value'].empty?)
    end

    def extract_entity_hash(parent_path, type, json, fetch_properties)
      data = json['data']
      type = shorten_resource_type(type)
      data['path'] = "#{parent_path}/#{type};#{data['id']}"
      if fetch_properties
        props = fetch_properties(json)
        data['properties'].merge! props unless props.nil?
      end
      # Evict children
      data.delete('children') unless data.key? 'children'
      data
    end

    def fetch_properties(json)
      return unless (json.key? 'children') && (json['children'].key? 'dataEntity')
      config = json['children']['dataEntity'].find { |d| d['data']['id'] == 'configuration' }
      config['data']['value'] unless config.nil?
    end

    def shorten_resource_type(resource_type)
      # cf InventoryStructure.class$EntityType
      case resource_type
      when 'feed'
        'f'
      when 'resourceType'
        'rt'
      when 'metricType'
        'mt'
      when 'operationType'
        'ot'
      when 'metric'
        'm'
      when 'resource'
        'r'
      when 'dataEntity'
        'd'
      else
        fail "Unknown type #{resource_type}"
      end
    end

    def get_raw_entity_hash(path)
      c_path = path.is_a?(CanonicalPath) ? path : CanonicalPath.parse(path)
      id = ERB::Util.url_encode c_path.to_metric_name
      raw = http_get("/strings/#{id}/raw?limit=1&order=DESC&fromEarliest=true")
      entity = extract_datapoints_json(raw)
      unless c_path.resource_ids.nil?
        relative = c_path.resource_ids.drop(1)
        relative.each do |child|
          if (entity.key? 'children') && (entity['children'].key? 'resource')
            entity = entity['children']['resource'].find { |r| r['data']['id'] == child }
          else
            entity = nil
            break
          end
        end
      end
      entity
    end

    def extract_child_resources(arr, path, parent_hash, recursive)
      if (parent_hash.key? 'children') && (parent_hash['children'].key? 'resource')
        parent_hash['children']['resource'].each do |r|
          entity = extract_entity_hash(path, 'resource', r, false)
          arr.push(Resource.new(entity))
          extract_child_resources(arr, entity['path'], r, true) if recursive
        end
      end
      arr
    end
  end

  InventoryClient = Client
  deprecate_constant :InventoryClient if self.respond_to? :deprecate_constant
end
