module Kontena::Workers
  class StatsWorker
    include Celluloid
    include Celluloid::Notifications
    include Kontena::Logging

    attr_reader :queue, :statsd, :node_name

    ##
    # @param [Queue] queue
    # @param [Boolean] autostart
    def initialize(queue, autostart = true)
      @queue = queue
      @statsd = nil
      @node_name = nil
      info 'initialized'
      subscribe('agent:node_info', :on_node_info)
      async.start if autostart
    end

    # @param [String] topic
    # @param [Hash] info
    def on_node_info(topic, info)
      @node_name = info['name']
      statsd_conf = info.dig('grid', 'stats', 'statsd')
      if statsd_conf
        debug "exporting stats via statsd to udp://#{statsd_conf['server']}:#{statsd_conf['port']}"
        @statsd = Statsd.new(
          statsd_conf['server'], statsd_conf['port'].to_i || 8125
        ).tap{|sd| sd.namespace = info.dig('grid', 'name')}
      else
        @statsd = nil
      end
    end

    def start
      debug 'waiting for cadvisor'
      sleep 1 until cadvisor_running?
      debug 'cadvisor is running, starting stats loop'
      last_collected = Time.now.to_i
      loop do
        sleep 1 until last_collected < (Time.now.to_i - 60)
        self.collect_stats
        last_collected = Time.now.to_i
      end
    end

    def collect_stats
      debug 'starting collection'
      begin
        Docker::Container.all.each do |container|
          if container.running?
            data = self.collect_container_stats(container.id)
            send_container_stats(data) if data
            sleep 0.5
          end
        end
      rescue => exc
        error "error on stats fetching: #{exc.message}"
        error exc.backtrace.join("\n")
      end
    end


    def collect_container_stats(container_id)
      retries = 3
      begin
        response = client.get(:path => "/api/v1.2/docker/#{container_id}")
        if response.status == 200
          JSON.parse(response.body, symbolize_names: true) rescue nil
        else
          error "failed to fetch cadvisor stats: #{response.status} #{response.body}"
          nil
        end
      rescue => exc
        retries -= 1
        if retries > 0
          retry
        end
        error "error getting container(#{container_id}) stats. #{exc.class.name}: #{exc.message}"
        nil
      end
    end

    ##
    # @param [Hash] container
    def send_container_stats(container)
      # when single container stats are used cadvisor "prefixes" all the data with some stupid system slice sutff
      slice_key = container.keys[0]

      prev_stat = container.dig(slice_key, :stats)[-2] if container
      return if prev_stat.nil?

      current_stat = container.dig(slice_key, :stats, -1)
      # Need to default to something usable in calculations
      cpu_usages = current_stat.dig(:cpu, :usage, :per_cpu_usage)
      num_cores = cpu_usages ? cpu_usages.count : 1
      raw_cpu_usage = current_stat.dig(:cpu, :usage, :total) - prev_stat.dig(:cpu, :usage, :total)
      interval_in_ns = get_interval(current_stat.dig(:timestamp), prev_stat.dig(:timestamp))

      event = {
        event: 'container:stats'.freeze,
        data: {
          id: container.dig(slice_key, :aliases, 1),
          spec: container.dig(slice_key, :spec),
          cpu: {
            usage: raw_cpu_usage,
            usage_pct: (((raw_cpu_usage / interval_in_ns ) / num_cores ) * 100).round(2)
          },
          memory: {
            usage: current_stat.dig(:memory, :usage),
            working_set: current_stat.dig(:memory, :working_set)
          },
          filesystem: current_stat[:filesystem],
          diskio: current_stat[:diskio],
          network: current_stat[:network]
        }
      }
      self.queue << event
      send_statsd_metrics(container.dig(slice_key, :aliases, 0), event[:data])
    end

    def client
      if @client.nil?
        @client = Excon.new("http://127.0.0.1:8989/api/v1.2/docker/")
      end
      @client
    end

    # @param [String] current
    # @param [String] previous
    def get_interval(current, previous)
      cur  = Time.parse(current).to_f
      prev = Time.parse(previous).to_f

      # to nano seconds
      (cur - prev) * 1000000000
    end

    # @return [Boolean]
    def cadvisor_running?
      cadvisor = Docker::Container.get('kontena-cadvisor') rescue nil
      return false if cadvisor.nil?
      cadvisor.info['State']['Running'] == true
    end

    # @param [String] name
    # @param [Hash] event
    def send_statsd_metrics(name, event)
      return unless statsd
      labels = event[:spec][:labels]
      if labels && labels[:'io.kontena.service.name']
        key_base = "services.#{name}"
      else
        key_base = "#{node_name}.containers.#{name}"
      end
      statsd.gauge("#{key_base}.cpu.usage", event[:cpu][:usage_pct])
      statsd.gauge("#{key_base}.memory.usage", event[:memory][:usage])
      interfaces = event.dig(:network, :interfaces) || []
      interfaces.each do |iface|
        [:rx_bytes, :tx_bytes].each do |metric|
          statsd.gauge("#{key_base}.network.iface.#{iface[:name]}.#{metric}", iface[metric])
        end
      end
    rescue => exc
      error "#{exc.class.name}: #{exc.message}"
      error exc.backtrace.join("\n")
    end
  end
end
