module VCAP::CloudController
  module Repositories
    module Runtime
      class ProcessEventRepository
        def self.record_create(process, user_guid, user_name)
          Loggregator.emit(process.app.guid, "Added process: \"#{process.type}\"")

          create_event(
            process:   process,
            type:      'audit.app.process.create',
            user_guid: user_guid,
            user_name: user_name,
            metadata:  {
              process_guid: process.guid,
              process_type: process.type
            }
          )
        end

        def self.record_delete(process, user_guid, user_name)
          Loggregator.emit(process.app.guid, "Deleting process: \"#{process.type}\"")

          create_event(
            process:   process,
            type:      'audit.app.process.delete',
            user_guid: user_guid,
            user_name: user_name,
            metadata:  {
              process_guid: process.guid,
              process_type: process.type
            }
          )
        end

        class << self
          private

          def create_event(process:, type:, user_guid:, user_name:, metadata:)
            app = process.app
            Event.create(
              type:       type,
              actee:      app.guid,
              actee_type: 'v3-app',
              actee_name: app.name,
              actor:      user_guid,
              actor_type: 'user',
              actor_name: user_name,
              timestamp:  Sequel::CURRENT_TIMESTAMP,
              space:      process.space,
              metadata:   metadata
            )
          end
        end
      end
    end
  end
end
