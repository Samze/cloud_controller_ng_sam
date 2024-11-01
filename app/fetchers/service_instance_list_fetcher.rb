require 'fetchers/base_list_fetcher'
require 'fetchers/label_selector_query_generator'

module VCAP::CloudController
  class ServiceInstanceListFetcher < BaseListFetcher
    class << self
      def fetch(message, omniscient: false, readable_spaces_dataset: nil, eager_loaded_associations: [])
        dataset = ServiceInstance.dataset.eager(eager_loaded_associations)
        
        # unless omniscient
        #   dataset = dataset.where do
        #     (Sequel[:spaces][:guid] =~ readable_spaces_dataset) |
        #       (Sequel[:service_instance_shares][:target_space_guid] =~ readable_spaces_dataset)
        #   end
        # end

        if message.requested?(:service_plan_names) || message.requested?(:service_plan_guids)
          dataset = dataset.left_join(:service_plans,
                                      id: Sequel[:service_instances][:service_plan_id])
        end

        # TODO: resolve omniscient
        filter(dataset, message, readable_spaces_dataset).
          select_all(:service_instances).
          distinct
      end

      private

      def filter(dataset, message, readable_spaces_dataset)
        # no test for readable_spaces_dataset AND message space filter (?)

        # TODO: can we use interect here for the readable_spaces_dataset??

        readable_union = nil
        if readable_spaces_dataset
          spaces_dataset = ServiceInstance.dataset.join(:spaces, id: Sequel[:service_instances][:space_id])
          spaces_dataset = spaces_dataset.where Sequel[:spaces][:guid] =~ readable_spaces_dataset

          share_dataset = ServiceInstance.dataset.join(:service_instance_shares, service_instance_guid: Sequel[:service_instances][:guid])
          share_dataset = share_dataset.where Sequel[:service_instance_shares][:target_space_guid] =~ readable_spaces_dataset

          spaces_dataset = spaces_dataset.select(Sequel[:service_instances][:id])
          share_dataset = share_dataset.select(Sequel[:service_instances][:id])

          readable_union = spaces_dataset.union(share_dataset, from_self: false)

          dataset = dataset.join_table(
            :inner,
            readable_union.as(:tmp_spaces_spaces_readable_table),
            Sequel[:service_instances][:id] => Sequel[:tmp_spaces_spaces_readable_table][:id]
          )
        end

        # probably dont want to map here
        space_filter = []

        # binding.pry
        # Q: What stops you requesting both organization_guids that you dont have access to?
        if message.requested?(:organization_guids)
          space_filter += Space.dataset.select(:spaces__guid).
                          join(:organizations, id: Sequel[:spaces][:organization_id]).
                          where(Sequel[:organizations][:guid] =~ message.organization_guids).map(:guid)

          # dataset = dataset.where do
          #   (Sequel[:spaces][:guid] =~ spaces_in_orgs) |
          #     (Sequel[:service_instance_shares][:target_space_guid] =~ spaces_in_orgs)
          # end
        end

        # Q: What stops you requesting both organization_guids that you dont have access to?
        if message.requested?(:space_guids)
          space_filter += message.space_guids

          # dataset = dataset.where do
          #   (Sequel[:spaces][:guid] =~ message.space_guids) |
          #     (Sequel[:service_instance_shares][:target_space_guid] =~ message.space_guids)
          # end
        end

        # admin
        #   select spaces
        #   union
        #   select shareed

        # user
        #  select spaces
        #    union
        #    select shareed
        #  intersect(
        #    select spaces
        #    union
        #    select shareed
        #  )
        #

        if space_filter.any?
          spaces_dataset = ServiceInstance.dataset.join(:spaces, id: Sequel[:service_instances][:space_id])
          spaces_dataset = spaces_dataset.where Sequel[:spaces][:guid] =~ space_filter

          share_dataset = ServiceInstance.dataset.left_join(:service_instance_shares, service_instance_guid: Sequel[:service_instances][:guid])
          share_dataset = share_dataset.where Sequel[:service_instance_shares][:target_space_guid] =~ space_filter

          spaces_dataset = spaces_dataset.select(Sequel[:service_instances][:id])
          share_dataset = share_dataset.select(Sequel[:service_instances][:id])

          unioned_dataset = spaces_dataset.union(share_dataset, from_self: false)


          # if readable_union
          #   # mysql does not support intersect
          #   unioned_dataset = readable_union.join_table(
          #     :inner,
          #     unioned_dataset.as(:tmp_perm_spaces_shares_table),
          #     Sequel[:tmp_perm_spaces_shares_table][:id] => Sequel[:service_instances][:id]
          #   ).distinct

          #   # binding.pry
          # end

          dataset = dataset.join_table(
            :inner,
            unioned_dataset.as(:tmp_spaces_shares_table),
            Sequel[:service_instances][:id] => Sequel[:tmp_spaces_shares_table][:id]
          ).distinct
          # binding.pry
        # elsif readable_union
        #   dataset = dataset.join_table(
        #     :inner,
        #     readable_union.as(:tmp_spaces_shares_table),
        #     Sequel[:service_instances][:id] => Sequel[:tmp_spaces_shares_table][:id]
        #   )
        end

        # binding.pry


        dataset = dataset.where(service_instances__name: message.names) if message.requested?(:names)

        if message.requested?(:type)
          dataset = case message.type
                    when 'managed'
                      dataset.where { (Sequel[:service_instances][:is_gateway_service] =~ true) }
                    when 'user-provided'
                      dataset.where { (Sequel[:service_instances][:is_gateway_service] =~ false) }
                    end
        end

        dataset = dataset.where { Sequel[:service_plans][:guid] =~ message.service_plan_guids } if message.requested?(:service_plan_guids)

        dataset = dataset.where { Sequel[:service_plans][:name] =~ message.service_plan_names } if message.requested?(:service_plan_names)

        if message.requested?(:label_selector)
          dataset = LabelSelectorQueryGenerator.add_selector_queries(
            label_klass: ServiceInstanceLabelModel,
            resource_dataset: dataset,
            requirements: message.requirements,
            resource_klass: ServiceInstance
          )
        end

        super(message, dataset, ServiceInstance)
      end
    end
  end
end
