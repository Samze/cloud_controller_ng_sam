require 'statsd'

module VCAP::CloudController
  module Metrics
    class RequestMetrics
      def initialize(statsd=CloudController::DependencyLocator.instance.statsd_client, prometheus_updater=CloudController::DependencyLocator.instance.prometheus_updater, redis_connection_pool_size: nil)
        @mutex = Mutex.new
        @statsd = statsd
        @prometheus_updater = prometheus_updater
      end

      def start_request
        @statsd.increment 'cc.requests.outstanding'
        @prometheus_updater.increment_gauge_metric(:cc_requests_outstanding_total)
        gauge = store.increment
        @statsd.gauge('cc.requests.outstanding.gauge', gauge)
      end

      def complete_request(status)
        http_status_code = "#{status.to_s[0]}XX"
        http_status_metric = "cc.http_status.#{http_status_code}"
        @statsd.batch do |batch|
          batch.decrement 'cc.requests.outstanding'
          batch.increment 'cc.requests.completed'
          batch.increment http_status_metric
        end

        @prometheus_updater.increment_counter_metric(:cc_requests_completed_total)
        @prometheus_updater.decrement_gauge_metric(:cc_requests_outstanding_total)

        gauge = store.decrement
        @statsd.gauge('cc.requests.outstanding.gauge', gauge)
      end

      private

      def store
        return @store if defined?(@store)

        redis_socket = VCAP::CloudController::Config.config.get(:redis, :socket)
        @store = redis_socket.nil? ? InMemoryStore.new : RedisStore.new(redis_socket, @redis_connection_pool_size)
      end

      class InMemoryStore
        def initialize
          @mutex = Mutex.new
          @counter = 0
        end

        def increment
          @mutex.synchronize do
            @counter += 1
          end
        end

        def decrement
          @mutex.synchronize do
            @counter -= 1
          end
        end
      end

      class RedisStore
        def initialize(socket, connection_pool_size)
          connection_pool_size ||= VCAP::CloudController::Config.config.get(:puma, :max_threads) || 1
          @redis = ConnectionPool::Wrapper.new(size: connection_pool_size) do
            Redis.new(timeout: 1, path: socket)
          end
          @redis.set("cc.requests.outstanding.gauge", 0)
        end

        def increment
          @redis.incr("cc.requests.outstanding.gauge")
        end

        def decrement
          @redis.decr("cc.requests.outstanding.gauge")
        end
      end
    end
  end
end
