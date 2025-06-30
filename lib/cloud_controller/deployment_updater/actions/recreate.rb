require 'cloud_controller/deployment_updater/actions/scale_down_canceled_processes'
require 'cloud_controller/diego/constants'

module VCAP::CloudController
  module DeploymentUpdater
    module Actions
      class Recreate
        attr_reader :deployment, :logger, :app, :target_total_instance_count

        def initialize(deployment, logger, target_total_instance_count)
          @deployment = deployment
          @logger = logger
          @app = deployment.app
          @target_total_instance_count = target_total_instance_count
        end

        def call
          deployment.db.transaction do
            return unless [DeploymentModel::DEPLOYING_STATE].include?(deployment.lock!.state)
            
            deployment.update(
              status_value: DeploymentModel::ACTIVE_STATUS_VALUE,
              status_reason: DeploymentModel::DEPLOYING_STATUS_REASON,
              error: nil
            )
            
            non_deploying_web_processes.each do |process|
              ScaleDownOldProcess.new(deployment, process,0).call
            end

            ScaleDownCanceledProcesses.new(deployment).call

            return true if finished_scaling?

            deploying_web_process.update(instances: target_total_instance_count)
            deployment.update(last_healthy_at: Time.now)
          end
          false
        rescue CloudController::Errors::ApiError # the instances_reporter re-raises InstancesUnavailable as ApiError
          logger.info("skipping-deployment-update-for-#{deployment.guid}")
          false
        end

        private

        def finished_scaling?
          deploying_web_process.instances >= @target_total_instance_count && instance_count_summary.routable_instances_count >= @target_total_instance_count
        end

        def non_deploying_web_processes
          app.web_processes.reject { |process| process.guid == deployment.deploying_web_process.guid }.sort_by { |p| [p.created_at, p.id] }
        end

        def instance_count_summary
          @instance_count_summary ||= instance_reporters.instance_count_summary(deploying_web_process)
        end

        def deploying_web_process
          @deploying_web_process ||= deployment.deploying_web_process
        end

        def instance_reporters
          CloudController::DependencyLocator.instance.instances_reporters
        end
      end
    end
  end
end
