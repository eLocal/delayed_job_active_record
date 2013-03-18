require 'active_record/version'
module Delayed
  module Backend
    module ActiveRecord
      # A job object that is persisted to the database.
      # Contains the work object as a YAML field.
      class Job < ::ActiveRecord::Base
        include Delayed::Backend::Base

        scope :by_priority, lambda { order('priority ASC, run_at ASC') }

        before_save :set_default_run_at

        def self.set_delayed_job_table_name
          delayed_job_table_name = "#{::ActiveRecord::Base.table_name_prefix}delayed_jobs"
          self.table_name = delayed_job_table_name
        end

        self.set_delayed_job_table_name

        def self.ready_to_run(worker_name, max_run_time)
          where('(run_at <= ? AND (locked_at IS NULL OR locked_at < ?) OR locked_by = ?) AND failed_at IS NULL', db_time_now, db_time_now - max_run_time, worker_name)
        end

        def self.before_fork
          ::ActiveRecord::Base.clear_all_connections!
        end

        def self.after_fork
          ::ActiveRecord::Base.establish_connection
        end

        # When a worker is exiting, make sure we don't have any locked jobs.
        def self.clear_locks!(worker_name)
          where(:locked_by => worker_name).update_all(:locked_by => nil, :locked_at => nil)
        end

        def self.reserve(worker, max_run_time = Worker.max_run_time)
          # scope to filter to records that are "ready to run"
          readyScope = self.ready_to_run(worker.name, max_run_time)

          # scope to filter to the single next eligible job
          readyScope = readyScope.where('priority >= ?', Worker.min_priority) if Worker.min_priority
          readyScope = readyScope.where('priority <= ?', Worker.max_priority) if Worker.max_priority
          readyScope = readyScope.where(:queue => Worker.queues) if Worker.queues.any?
          job = readyScope.by_priority.first

          now = self.db_time_now

          return unless job
          begin
            job.with_lock do
              job.locked_at = now
              job.locked_by = worker.name
              job.save!
            end  
          rescue ::ActiveRecord::RecordNotFound => e
            warn "Proflem locking Job: #{e.inspect}"
            # This can happen if in between the time when we look up the job 
            # and when we try to get the exclusive lock, the job is deleted.  
            # While rare, we should ignore this job and move on to the next one.
            return
          end
          job
        end

        # Lock this job for this worker.
        # Returns true if we have the lock, false otherwise.
        def lock_exclusively!(max_run_time, worker)
          now = self.class.db_time_now
          affected_rows = if locked_by != worker
            # We don't own this job so we will update the locked_by name and the locked_at
            self.class.update_all(["locked_at = ?, locked_by = ?", now, worker], ["id = ? and (locked_at is null or locked_at < ?) and (run_at <= ?)", id, (now - max_run_time.to_i), now])
          else
            # We already own this job, this may happen if the job queue crashes.
            # Simply resume and update the locked_at
            self.class.update_all(["locked_at = ?", now], ["id = ? and locked_by = ?", id, worker])
          end
          if affected_rows == 1
            self.locked_at = now
            self.locked_by = worker
            self.changed_attributes.clear
            return true
          else
            return false
          end
        end

        # Get the current time (GMT or local depending on DB)
        # Note: This does not ping the DB to get the time, so all your clients
        # must have syncronized clocks.
        def self.db_time_now
          if Time.zone
            Time.zone.now
          elsif ::ActiveRecord::Base.default_timezone == :utc
            Time.now.utc
          else
            Time.now
          end
        end

        def reload(*args)
          reset
          super
        end
      end
    end
  end
end
