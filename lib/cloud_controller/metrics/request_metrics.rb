require 'statsd'

module VCAP::CloudController
  module Metrics
    class RequestMetrics
      def initialize(statsd=CloudController::DependencyLocator.instance.statsd_client, prometheus_updater=CloudController::DependencyLocator.instance.prometheus_updater)
        @mutex = Mutex.new
        @counter = 0
        @statsd = statsd
        @prometheus_updater = prometheus_updater
      end

      def start_request
        @statsd.increment 'cc.requests.outstanding'
        increment_outstanding_gauge
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

        decrement_outstanding_gauge
      end

      private

      def increment_outstanding_gauge
        @prometheus_updater.increment_gauge_metric(:cc_requests_outstanding_total)
        set_statsd_outstanding_gauge(1)
      end

      def decrement_outstanding_gauge
        @prometheus_updater.decrement_gauge_metric(:cc_requests_outstanding_total)
        set_statsd_outstanding_gauge(-1)
      end

      def set_statsd_outstanding_gauge(val)
        if VCAP::CloudController::Config.config.get(:webserver) == 'puma'
          gauge = @prometheus_updater.get_gauge_metric_value(:cc_requests_outstanding_total)
        else
          @mutex.synchronize do
            @counter += val
          end
          gauge = @counter
        end
        @statsd.gauge('cc.requests.outstanding.gauge', gauge)
      end
    end
  end
end
