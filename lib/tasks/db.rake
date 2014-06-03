namespace :db do
  desc "Create a Sequel migration in ./db/migrate"
  task :create_migration do
    name = ENV["NAME"]
    abort("no NAME specified. use `rake db:create_migration NAME=add_users`") if !name

    migrations_dir = File.join("db", "migrations")

    version = ENV["VERSION"] || Time.now.utc.strftime("%Y%m%d%H%M%S")
    filename = "#{version}_#{name}.rb"
    FileUtils.mkdir_p(migrations_dir)

    open(File.join(migrations_dir, filename), "w") do |f|
      f.write <<-Ruby
Sequel.migration do
  change do
  end
end
      Ruby
    end
  end

  desc "Perform Sequel migration to database"
  task :migrate do
    Steno.init(Steno::Config.new(sinks: [Steno::Sink::IO.new(STDOUT)]))
    db_logger = Steno.logger("cc.db.migrations")
    DBMigrator.from_config(config, db_logger).apply_migrations
  end

  desc "Rollback a single migration to the database"
  task :rollback do
    Steno.init(Steno::Config.new(sinks: [Steno::Sink::IO.new(STDOUT)]))
    db_logger = Steno.logger("cc.db.migrations")
    DBMigrator.from_config(config, db_logger).rollback(number_to_rollback=1)
  end

  namespace :migrate do
    desc "Rollback the most recent migration and remigrate to current"
    task :redo => [:rollback, :migrate]
  end

  task :pick do
    ENV["DB"] ||= %w[sqlite mysql postgres].sample
    puts "Using #{ENV["DB"]}"
  end

  task create: :pick do
    case ENV["DB"]
      when "postgres"
        sh "psql -U postgres -c 'create database cc_test_;'"
      when "mysql"
        if ENV["TRAVIS"] == "true"
          sh "mysql -e 'create database cc_test_;'"
        else
          sh "mysql -e 'create database cc_test_;' -u root --password=password"
        end
    end
  end

  task drop: :pick do
    case ENV["DB"]
      when "postgres"
        sh "psql -U postgres -c 'drop database if exists cc_test_;'"
      when "mysql"
        if ENV["TRAVIS"] == "true"
          sh "mysql -e 'drop database if exists cc_test_;'"
        else
          sh "mysql -e 'drop database if exists cc_test_;' -u root --password=password"
        end
    end
  end

  task recreate: %w[drop create]
end
