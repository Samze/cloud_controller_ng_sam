module VCAP::CloudController
  module DeploymentUpdater
    class Updater
      attr_reader :deployment, :logger

      def initialize(deployment, logger)
        @deployment = deployment
        @logger = logger
      end

      def scale
        with_error_logging('error-scaling-deployment') do
          scale_deployment
          logger.info("ran-deployment-update-for-#{deployment.guid}")
        end
      end

      def canary
        with_error_logging('error-canarying-deployment') do
          canary_deployment
          logger.info("ran-canarying-deployment-for-#{deployment.guid}")
        end
      end

      def cancel
        with_error_logging('error-canceling-deployment') do
          cancel_deployment
          logger.info("ran-cancel-deployment-for-#{deployment.guid}")
        end
      end

      private

      def with_error_logging(error_message)
        yield
      rescue StandardError => e
        error_name = e.is_a?(CloudController::Errors::ApiError) ? e.name : e.class.name
        logger.error(
          error_message,
          deployment_guid: deployment.guid,
          error: error_name,
          error_message: e.message,
          backtrace: e.backtrace.join("\n")
        )
      end

      def cancel_deployment
        deployment.db.transaction do
          app.lock!
          return unless deployment.lock!.state == DeploymentModel::CANCELING_STATE

          deploying_web_process.lock!

          prior_web_process = interim_web_process || app.oldest_web_process
          prior_web_process.lock!

          prior_web_process.update(instances: deployment.original_web_process_instance_count, type: ProcessTypes::WEB)

          cleanup_web_processes_except(prior_web_process)

          deployment.update(
            state: DeploymentModel::CANCELED_STATE,
            status_value: DeploymentModel::FINALIZED_STATUS_VALUE,
            status_reason: DeploymentModel::CANCELED_STATUS_REASON
          )
        end
      end

      def canary_deployment
        deployment.db.transaction do
          deployment.lock!
          return unless deployment.state == DeploymentModel::PREPAUSED_STATE

          scale_canceled_web_processes_to_zero

          if canary_ready?
            deployment.update(
              last_healthy_at: Time.now,
              state: DeploymentModel::PAUSED_STATE,
              status_value: DeploymentModel::ACTIVE_STATUS_VALUE,
              status_reason: DeploymentModel::PAUSED_STATUS_REASON
            )
            logger.info("paused-canary-deployment-for-#{deployment.guid}")
          end
        end
      end

      def scale_deployment
        deployment.db.transaction do
          app.lock!
          return unless deployment.lock!.state == DeploymentModel::DEPLOYING_STATE

          scale_canceled_web_processes_to_zero

          oldest_web_process_with_instances.lock!
          deploying_web_process.lock!

          scale_up_to = instances_to_scale_up
          scale_down_to = instances_to_scale_down

          # binding.pry
          # scale_by = instances_to_scale
          # return unless scale_by > 0

          # todo, only change this when something new has become healthy
          deployment.update(
            last_healthy_at: Time.now,
            state: DeploymentModel::DEPLOYING_STATE,
            status_value: DeploymentModel::ACTIVE_STATUS_VALUE,
            status_reason: DeploymentModel::DEPLOYING_STATUS_REASON
          )

          scale_down_oldest_web_process_with_instances_2(scale_down_to)
          scale_up_new_web_process_instances_2(scale_up_to)

          if deploying_web_process.instances >= deployment.original_web_process_instance_count && all_instances_ready?
            binding.pry
            finalize_deployment
            return
          end
        end
      end

      def app
        @app ||= deployment.app
      end

      def deploying_web_process
        @deploying_web_process ||= deployment.deploying_web_process
      end

      def oldest_web_process_with_instances
        @oldest_web_process_with_instances ||= app.web_processes.select { |process| process.instances > 0 }.min_by(&:created_at)
      end

      def interim_web_process
        # Find newest interim web process that (a) belongs to a SUPERSEDED (DEPLOYED) deployment and (b) has at least
        # one running instance.
        app.web_processes_dataset.
          qualify.
          join(:deployments, deploying_web_process_guid: :guid).
          where(deployments__state: DeploymentModel::DEPLOYED_STATE).
          where(deployments__status_reason: DeploymentModel::SUPERSEDED_STATUS_REASON).
          order(Sequel.desc(:created_at), Sequel.desc(:id)).
          find { |p| running_instance?(p) }
      end

      def is_original_web_process?(process)
        process == app.oldest_web_process
      end

      def is_interim_process?(process)
        !is_original_web_process?(process)
      end

      def scale_canceled_web_processes_to_zero
        # Find interim web processes that (a) belong to a SUPERSEDED (CANCELED) deployment and (b) have instances
        # and scale them to zero.
        app.web_processes_dataset.
          qualify.
          join(:deployments, deploying_web_process_guid: :guid).
          where(deployments__state: DeploymentModel::CANCELED_STATE).
          where(deployments__status_reason: DeploymentModel::SUPERSEDED_STATUS_REASON).
          where(Sequel[:processes__instances] > 0).
          each { |p| p.lock!.update(instances: 0) }
      end

      def scale_down_oldest_web_process_with_instances_2(scale_to)
        process = oldest_web_process_with_instances

        if scale_to == 0 && is_interim_process?(process)
          process.destroy
          return
        end

        process.update(instances: scale_to)
      end

      def scale_down_oldest_web_process_with_instances(scale_by)
        process = oldest_web_process_with_instances

        if process.instances <= deployment.max_in_flight && is_interim_process?(process)
          process.destroy
          return
        end

        process.update(instances: [(process.instances - scale_by), 0].max)
      end

      def scale_up_new_web_process_instances_2(scale_to)
        deploying_web_process.update(instances: scale_to)
      end

      def scale_up_new_web_process_instances(scale_by)
        deploying_web_process.update(instances: [deploying_web_process.instances + scale_by, deployment.original_web_process_instance_count].min)
      end

      def finalize_deployment
        promote_deploying_web_process

        cleanup_web_processes_except(deploying_web_process)

        update_non_web_processes
        restart_non_web_processes
        deployment.update(
          state: DeploymentModel::DEPLOYED_STATE,
          status_value: DeploymentModel::FINALIZED_STATUS_VALUE,
          status_reason: DeploymentModel::DEPLOYED_STATUS_REASON
        )
      end

      def promote_deploying_web_process
        deploying_web_process.update(type: ProcessTypes::WEB)
      end

      def cleanup_web_processes_except(protected_process)
        app.web_processes.
          reject { |p| p.guid == protected_process.guid }.
          map(&:destroy)
      end

      def restart_non_web_processes
        app.processes.reject(&:web?).each do |process|
          VCAP::CloudController::ProcessRestart.restart(
            process: process,
            config: Config.config,
            stop_in_runtime: true,
            revision: deploying_web_process.revision
          )
        end
      end

      def update_non_web_processes
        return if deploying_web_process.revision.nil?

        app.processes.reject(&:web?).each do |process|
          process.update(command: deploying_web_process.revision.commands_by_process_type[process.type])
        end
      end

      def canary_ready?
        instances_ready_count >= 1
      end

      def instances_to_scale
        return deployment.max_in_flight - (deployment.deploying_web_process.instances - instances_ready_count)
      end

      def instances_to_scale_up
        left_to_scale = deployment.original_web_process_instance_count - deployment.deploying_web_process.instances
        
        max_scale = [deployment.max_in_flight - (deployment.deploying_web_process.instances - instances_ready_count), 0].max

        return deployment.deploying_web_process.instances + [max_scale, left_to_scale].min
      end

      def instances_to_scale_down
        target_scale = deployment.original_web_process_instance_count

        new_processes_running = instances_ready_count

        scale_down = target_scale - new_processes_running

        # ensure we don't scale up incase we have more processes running than we should
        new_scale = [scale_down, oldest_web_process_with_instances.instances].min

        return [new_scale, 0].max
      end

      def instances_ready_count
        instances = instance_reporters.all_instances_for_app(deployment.deploying_web_process)
        instances.count { |_, val| val[:state] == VCAP::CloudController::Diego::LRP_RUNNING && val[:routable] }
      end

      def all_instances_ready?
        instances = instance_reporters.all_instances_for_app(deployment.deploying_web_process)
        instances.all? { |_, val| val[:state] == VCAP::CloudController::Diego::LRP_RUNNING && val[:routable] }
      rescue CloudController::Errors::ApiError # the instances_reporter re-raises InstancesUnavailable as ApiError
        false
      end
      
      def running_instance?(process)
        instances = instance_reporters.all_instances_for_app(process)
        instances.any? { |_, val| val[:state] == VCAP::CloudController::Diego::LRP_RUNNING }
      rescue CloudController::Errors::ApiError # the instances_reporter re-raises InstancesUnavailable as ApiError
        false
      end

      def instance_reporters
        CloudController::DependencyLocator.instance.instances_reporters
      end
    end
  end
end
