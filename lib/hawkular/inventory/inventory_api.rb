require 'hawkular/base_client'
require 'websocket-client-simple'
require 'json'
require 'zlib'
require 'stringio'

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
      fail 'no parameter ":entrypoint" given' unless hash[:entrypoint]
      hash[:credentials] ||= {}
      hash[:options] ||= {}
      Client.new(hash[:entrypoint], hash[:credentials], hash[:options])
    end

    # List feeds in the system
    # @return [Array<String>] List of feed ids
    def list_feeds
      ret = http_get('/strings/tags/module:inventory,feed:*')
      return [] unless ret.key? 'feed'
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
      feed_path = CanonicalPath.from_feed(feed_id)
      ret.map do |rt|
        json = extract_metric_json(rt)
        if json
          root_hash = entity_json_to_hash(-> (id) { feed_path.rt(id) }, json, false)
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
      feed_path = CanonicalPath.from_feed(feed_id)
      to_filter = ret.map do |r|
        json = extract_metric_json(r)
        if json
          root_hash = entity_json_to_hash(-> (id) { feed_path.down(id) }, json, fetch_properties)
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
      tag_name = "rt.#{resource_type_id}"
      ret = http_get("/metrics?type=string&tags=module:inventory,type:r,feed:#{feed_id},#{tag_name}:*")
      return [] if ret.empty?
      child_resources_names = {}
      ret.each { |metric| child_resources_names[metric['id']] = metric['tags'][URI.decode(tag_name)] }

      # Second step: get content for all metrics that we've found
      ret = http_post(
        '/strings/raw/query',
        fromEarliest: true,
        limit: 1,
        order: 'DESC',
        ids: child_resources_names.keys
      )

      # Third step: in each json blob returned, find the resources having the type we want
      # We already have their relative path in child_resources_names hash
      extract_child_from_paths(feed_id, child_resources_names, ret, fetch_properties)
    end

    # Retrieve runtime properties for the passed resource
    # @param [String] resource_path Canonical path of the resource to read properties from.
    # @return [Hash<String,Object] Hash with additional data
    def get_config_data_for_resource(resource_path)
      path = resource_path.is_a?(CanonicalPath) ? resource_path : CanonicalPath.parse(resource_path)
      raw_hash = get_raw_entity_hash(path)
      { 'value' => fetch_properties(raw_hash) } if raw_hash
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
      extract_child_resources([], path.to_s, entity_hash, recursive) if entity_hash
    end

    # List metric (definitions) for the passed resource. It is possible to filter down the
    #   result by a filter to only return a subset. The
    # @param [String] resource_path Canonical path of the resource.
    # @param [Hash{Symbol=>String}] filter for 'type' and 'match'
    #   Metric type can be one of 'GAUGE', 'COUNTER', 'AVAILABILITY'. If a key is missing
    #   it will not be used for filtering
    # @return [Array<Metric>] List of metrics that can be empty.
    # @example
    #    # Filter by type and match on metrics id
    #    client.list_metrics_for_resource(wild_fly, type: 'GAUGE', match: 'Metrics~Heap')
    #    # Filter by type only
    #    client.list_metrics_for_resource(wild_fly, type: 'COUNTER')
    #    # Don't filter, return all metric definitions
    #    client.list_metrics_for_resource(wild_fly)
    def list_metrics_for_resource(resource_path, filter = {})
      path = resource_path.is_a?(CanonicalPath) ? resource_path : CanonicalPath.parse(resource_path)
      raw_hash = get_raw_entity_hash(path)
      return [] unless raw_hash
      to_filter = []
      if (raw_hash.key? 'children') && (raw_hash['children'].key? 'metric') && !raw_hash['children']['metric'].empty?
        metric_type_ids = raw_hash['children']['metric'].map do |m|
          decoded = URI.unescape(m['data']['metricTypePath'])
          type_id = CanonicalPath.parse(decoded).to_metric_name
          m['type_id'] = type_id
        end
        metric_type_hashes = fetch_metric_types(metric_type_ids)
        to_filter = raw_hash['children']['metric'].map do |m|
          metric_data = m['data']
          metric_type = metric_type_hashes[m['type_id']]
          metric_data['path'] = "#{path}/m;#{metric_data['id']}"
          Metric.new(metric_data, metric_type) if metric_type
        end
      end
      filter_entities(to_filter, filter)
    end

    # Fetch metric types for the passed list of paths
    # @param [Array<String>] metric_type_ids list of metric type ids to fetch
    # @return [Hash{String,Hash{String,Object}}] Properties hashes for each metric type path
    def fetch_metric_types(metric_type_ids)
      raw = http_post(
        '/strings/raw/query',
        fromEarliest: true,
        limit: 1,
        order: 'DESC',
        ids: metric_type_ids
      )
      ret = {}
      raw.each do |mt|
        json = extract_metric_json(mt)
        ret[mt['id']] = json['data'] if json
      end
      ret
    end

    # Return the resource object for the passed path
    # @param [String] resource_path Canonical path of the resource to fetch.
    # @param [Boolean] fetch_properties Should the resource config data be fetched?
    def get_resource(resource_path, fetch_properties = true)
      path = resource_path.is_a?(CanonicalPath) ? resource_path : CanonicalPath.parse(resource_path)
      raw_hash = get_raw_entity_hash(path)
      return unless raw_hash
      entity_hash = entity_json_to_hash(-> (_) { path }, raw_hash, fetch_properties)
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
      return if (datapoints.empty?) || (datapoints[0]['value'].empty?)
      decoded = Base64.decode64(datapoints[0]['value'])
      gz = Zlib::GzipReader.new(StringIO.new(decoded))
      JSON.parse(gz.read)
    end

    # def entity_json_to_hash(parent_path, type, json, fetch_properties)
    #   data = json['data']
    #   type = shorten_resource_type(type)
    #   data['path'] = "#{parent_path}/#{type};#{hawk_escape_id data['id']}"
    #   if fetch_properties
    #     props = fetch_properties(json)
    #     data['properties'].merge! props if props
    #   end
    #   # Evict children
    #   data.delete('children') unless data.key? 'children'
    #   data
    # end

    def entity_json_to_hash(path_getter, json, fetch_properties)
      data = json['data']
      data['path'] = path_getter.call(data['id']).to_s
      if fetch_properties
        props = fetch_properties(json)
        data['properties'].merge! props if props
      end
      # Evict children
      data.delete('children') unless data.key? 'children'
      data
    end

    def fetch_properties(json)
      return unless (json.key? 'children') && (json['children'].key? 'dataEntity')
      config = json['children']['dataEntity'].find { |d| d['data']['id'] == 'configuration' }
      config['data']['value'] if config
    end

    def get_raw_entity_hash(path)
      c_path = path.is_a?(CanonicalPath) ? path : CanonicalPath.parse(path)
      id = ERB::Util.url_encode c_path.to_metric_name
      raw = http_get("/strings/#{id}/raw?limit=1&order=DESC&fromEarliest=true")
      entity = extract_datapoints_json(raw)
      extract_entity_json(c_path, entity)
    end

    def extract_entity_json(fullpath, json_root)
      entity = json_root
      if fullpath.resource_ids
        relative = fullpath.resource_ids.drop(1)
        relative.each do |child|
          if (entity.key? 'children') && (entity['children'].key? 'resource')
            unescaped = URI.unescape(child)
            entity = entity['children']['resource'].find { |r| r['data']['id'] == unescaped }
          else
            entity = nil
            break
          end
        end
      end
      entity
    end

    def extract_child_resources(arr, path, parent_hash, recursive)
      c_path = path.is_a?(CanonicalPath) ? path : CanonicalPath.parse(path)
      if (parent_hash.key? 'children') && (parent_hash['children'].key? 'resource')
        parent_hash['children']['resource'].each do |r|
          entity = entity_json_to_hash(-> (id) { c_path.down(id) }, r, false)
          arr.push(Resource.new(entity))
          extract_child_resources(arr, entity['path'], r, true) if recursive
        end
      end
      arr
    end

    def extract_child_from_paths(feed_id, child_resources, json_blobs, fetch_properties)
      # in each json blob, find the resources having the type we want
      # We already have their relative path in child_resources_names hash
      resources = []
      json_blobs.each do |r|
        json = extract_metric_json(r)
        next unless json
        feed_path = CanonicalPath.from_feed(feed_id)
        root_path = feed_path.down(json['data']['id'])
        names = child_resources[r['id']]
        relative_paths = names.split(',', -1)
        # "".split(',') returns [] whereas we'd expect [""]
        relative_paths.push('') if names.empty?
        relative_paths.each do |relative_path|
          if relative_path.empty?
            # Root resource
            resource = entity_json_to_hash(-> (id) { feed_path.down(id) }, json, fetch_properties)
            resources.push(Resource.new(resource))
          else
            # Search for child
            fullpath = CanonicalPath.parse("#{root_path}/#{relative_path}")
            resource_json = extract_entity_json(fullpath, json)
            if resource_json
              resource = entity_json_to_hash(-> (id) { root_path.down(id) }, resource_json, fetch_properties)
              resources.push(Resource.new(resource))
            end
          end
        end
      end
      resources
    end
  end

  InventoryClient = Client
  deprecate_constant :InventoryClient if self.respond_to? :deprecate_constant
end
