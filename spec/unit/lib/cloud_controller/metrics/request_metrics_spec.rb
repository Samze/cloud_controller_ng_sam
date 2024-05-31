require 'spec_helper'
require 'cloud_controller/metrics/request_metrics'

module VCAP::CloudController::Metrics
  RSpec.describe RequestMetrics do
    let(:statsd_client) { double(:statsd_client) }
    let(:prometheus_client) { double(:prometheus_client) }
    let(:store) { double(:store) }
    let(:request_metrics) { RequestMetrics.new(statsd_client, prometheus_client) }

    before do
      allow(prometheus_client).to receive(:update_gauge_metric)
      allow(prometheus_client).to receive(:decrement_gauge_metric)
      allow(prometheus_client).to receive(:increment_gauge_metric)
      allow(prometheus_client).to receive(:increment_counter_metric)
    end

    describe '#start_request' do
      before do
        allow(statsd_client).to receive(:increment)
        allow(statsd_client).to receive(:gauge)
        allow(request_metrics).to receive(:store).and_return(store)
        allow(store).to receive(:increment).and_return(4)
      end

      it 'increments outstanding requests for statsd' do
        request_metrics.start_request

        expect(store).to have_received(:increment)
        expect(statsd_client).to have_received(:gauge).with('cc.requests.outstanding.gauge', 4)
        expect(statsd_client).to have_received(:increment).with('cc.requests.outstanding')
      end

      it 'increments outstanding requests for prometheus' do
        request_metrics.start_request

        expect(prometheus_client).to have_received(:increment_gauge_metric).with(:cc_requests_outstanding_total)
      end
    end

    describe '#complete_request' do
      let(:batch) { double(:batch) }
      let(:status) { 204 }

      before do
        allow(statsd_client).to receive(:batch).and_yield(batch)
        allow(statsd_client).to receive(:gauge)
        allow(batch).to receive(:increment)
        allow(batch).to receive(:decrement)
        allow(request_metrics).to receive(:store).and_return(store)
        allow(store).to receive(:decrement).and_return(5)
      end

      it 'increments completed, decrements outstanding, increments status for statsd' do
        request_metrics.complete_request(status)

        expect(store).to have_received(:decrement)
        expect(statsd_client).to have_received(:gauge).with('cc.requests.outstanding.gauge', 5)
        expect(batch).to have_received(:decrement).with('cc.requests.outstanding')
        expect(batch).to have_received(:increment).with('cc.requests.completed')
        expect(batch).to have_received(:increment).with('cc.http_status.2XX')
      end

      it 'increments completed and decrements outstanding for prometheus' do
        request_metrics.complete_request(status)

        expect(prometheus_client).to have_received(:decrement_gauge_metric).with(:cc_requests_outstanding_total)
        expect(prometheus_client).to have_received(:increment_counter_metric).with(:cc_requests_completed_total)
      end

      it 'normalizes http status codes in statsd' do
        request_metrics.complete_request(200)
        expect(batch).to have_received(:increment).with('cc.http_status.2XX')

        request_metrics.complete_request(300)
        expect(batch).to have_received(:increment).with('cc.http_status.3XX')

        request_metrics.complete_request(400)
        expect(batch).to have_received(:increment).with('cc.http_status.4XX')
      end
    end

    describe '#store' do
      context 'when redis socket is not configured' do
        before do
          allow(VCAP::CloudController::Config).to receive_message_chain(:config, :get).with(:redis, :socket).and_return(nil)
        end

        it 'returns an instance of InMemoryStore' do
          store = request_metrics.send(:store)
          expect(store).to be_an_instance_of(RequestMetrics::InMemoryStore)
        end
      end

      context 'when redis socket is configured' do
        let(:redis_socket) { 'redis.sock' }

        before do
          allow(VCAP::CloudController::Config).to receive_message_chain(:config, :get).with(:redis, :socket).and_return(redis_socket)
          allow(VCAP::CloudController::Config).to receive_message_chain(:config, :get).with(:puma, :max_threads).and_return(nil)
        end

        it 'returns an instance of RedisStore' do
          expect(ConnectionPool::Wrapper).to receive(:new).with(size: 1).and_call_original
          store = request_metrics.send(:store)
          expect(store).to be_an_instance_of(RequestMetrics::RedisStore)
        end

        context 'when puma max threads is set' do 
          let(:pool_size) { 10 }
          before do
            allow(VCAP::CloudController::Config).to receive_message_chain(:config, :get).with(:redis, :socket).and_return(redis_socket)
            allow(VCAP::CloudController::Config).to receive_message_chain(:config, :get).with(:puma, :max_threads).and_return(pool_size)
          end

          it 'passes the connection pool size to RedisStore' do
            expect(ConnectionPool::Wrapper).to receive(:new).with(size: pool_size).and_call_original
            store = request_metrics.send(:store)            
          end
        end
      end
    end 

    describe RequestMetrics::InMemoryStore do
      let(:store) { RequestMetrics::InMemoryStore.new }

      it 'increments the counter' do
        expect(store.increment).to eq(1)
        expect(store.increment).to eq(2)
        expect(store.increment).to eq(3)
      end

      it 'decrements the counter' do
        expect(store.decrement).to eq(-1)
        expect(store.decrement).to eq(-2)
        expect(store.decrement).to eq(-3)
      end
    end

    describe RequestMetrics::RedisStore do
      let(:redis_socket) { 'redis.sock' }
      let(:connection_pool_size) { 5 }
      let(:redis_store) { RequestMetrics::RedisStore.new(redis_socket, connection_pool_size) }
      let(:redis) { instance_double('Redis') }

      before do
        allow(ConnectionPool::Wrapper).to receive(:new).and_return(redis)
        allow(redis).to receive(:set)
      end

      describe 'initialization' do  
        it 'clears cc.requests.outstanding.gauge' do
          expect(redis).to receive(:set).with("cc.requests.outstanding.gauge", 0)
          RequestMetrics::RedisStore.new(redis_socket, connection_pool_size)
        end

        it 'configures a Redis connection pool with specified size' do
          expect(ConnectionPool::Wrapper).to receive(:new).with(size: connection_pool_size).and_call_original
          RequestMetrics::RedisStore.new(redis_socket, connection_pool_size)
        end

        context 'when the connection pool size is not provided' do
          it 'uses a default connection pool size of 1' do
            expect(ConnectionPool::Wrapper).to receive(:new).with(size: 1).and_call_original
            RequestMetrics::RedisStore.new(redis_socket, nil)
          end

          context 'when puma max threads is set' do
            before do
              allow(VCAP::CloudController::Config).to receive_message_chain(:config, :get).with(:puma, :max_threads).and_return(10)
            end

            it 'uses puma max threads' do
              expect(ConnectionPool::Wrapper).to receive(:new).with(size: 10).and_call_original
              RequestMetrics::RedisStore.new(redis_socket, nil)
            end
          end
        end
      end

      it 'increments the gauge in Redis' do
        allow(redis).to receive(:incr).and_return(1)
        expect(redis_store.increment).to eq(1)
      end

      it 'decrements the gauge in Redis' do
        allow(redis).to receive(:decr).and_return(-1)
        expect(redis_store.decrement).to eq(-1)
      end
    end
  end
end
