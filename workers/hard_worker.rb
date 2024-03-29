require 'slack-ruby-bot'
require 'sidekiq'
require 'pry'
require 'httparty'

require 'rufus-scheduler'
require 'chronic'

require './webhooks_slack/slack_sender'
require './jenkins/jenkins_script.rb'
require './db/models.rb'

module Worker

  class StatusWorker
    include Sidekiq::Worker
    include SlackSender

    def perform(project_name, user_name_slack)
      way_project = search_way_project_in_db(project_name, user_name_slack)
      message= jenkins_status_project(way_project, project_name)
      send_jenkins_message_to_slack(message)
    end

    private

    def search_way_project_in_db(project_name, user_name_slack)
      Project.new.search_way_project(project_name, user_name_slack) # way_project = "DevopsTest/job/GradleUnitTest" in BD
    end

    def jenkins_status_project(way_project, project_name)
      ProjectJenkins.new.jenkins_status_project(way_project, project_name)
    end
  end

  class BuildWorker
    include Sidekiq::Worker
    include SlackSender

    def perform(project_name, user_name_slack)
      way_project = search_way_project_in_db(project_name, user_name_slack) # way_project = "DevopsTest/job/GradleUnitTest" in BD
      if way_project.nil?
        send_jenkins_message_to_slack("Sorry i can not find #{project_name}")
      else
        text = jenkins_build_job(way_project, project_name)
        send_jenkins_message_to_slack(text)
        jenkins_status_build = ProjectJenkins.new.jenkins_status_build(way_project)

        unless jenkins_status_build == 'running'
          scheduler = Rufus::Scheduler.new
          scheduler.every '10s', :first_in => '30s' do
            jenkins_status_build = ProjectJenkins.new.jenkins_status_build(way_project)
            if  ['success', 'failure'].include?(jenkins_status_build)    # running, success, failure
              message = ProjectJenkins.new.jenkins_status_project(way_project, project_name)
              send_jenkins_message_to_slack(message)
              scheduler.shutdown #(:terminate) # (:terminate or :kill (or nothing))
            end
          end
          scheduler.join
        end

      end

    end

    private

    def search_way_project_in_db(project_name, user_name_slack)
      Project.new.search_way_project(project_name, user_name_slack) # way_project = "DevopsTest/job/GradleUnitTest" in BD
    end

    def jenkins_build_job(way_project, project_name)
      ProjectJenkins.new.jenkins_build_job(way_project, project_name)
    end
  end

  class MonitoringAddressWorker
    include Sidekiq::Worker
    include SlackSender

    def perform(user_name_slack, project_url_monitoring, project_name)
      Project.new.user_add_project_monitoring(user_name_slack, project_url_monitoring, project_name)
      project = Project.new.get_project(user_name_slack, project_name)
      project_url_monitoring = project.projects_url_monitoring # IN db "https://example.com/posts/rails-eto-prosto-ruby"
      project_name = project.projects_name # IN db OnlineShopJSFinal
      project_way = project.project_way # IN db DevopsTest/job/GradleUnitTest
      monitoring(project_url_monitoring, project_way,  project_name)
    end

    private

    def monitoring(project_url_monitoring, project_way, project_name )
      # status = get_status(project_url_monitoring)
      if get_status(project_url_monitoring).nil?
        send_jenkins_message_to_slack('Maybe entered your site address incorrectly')
      else
        send_jenkins_message_to_slack("Ok, i will keep an eye on it #{project_name}")
        scheduler = Rufus::Scheduler.new
        scheduler.every '1m', :first_in => Time.now + 10.seconds do
          status_http = get_status(project_url_monitoring)
          unless [200, 502].include?(status_http)
            status_jenkins = ProjectJenkins.new.monitoring_status(project_way)
            send_jenkins_message_to_slack("I can`t reach #{project_url_monitoring}, status jenkins #{status_jenkins} but it`s not building, maybe i need to rebuild it?")
            scheduler.shutdown #(:terminate) # (:terminate or :kill (or nothing))
          end
        end
        scheduler.join

        # send_jenkins_message_to_slack("Ok, i will keep an eye on it #{project_name}")
        # while [200, 502].include?(status)
        #   sleep *60 # every one minute
        #   p status = get_status(project_url_monitoring)
        # end
        # status_jenkins = ProjectJenkins.new.monitoring_status(project_way)
        # send_jenkins_message_to_slack("I can`t reach #{project_url_monitoring}, but it`s not building, maybe i need to rebuild it?")

      end
    end

    def get_status(project_url_monitoring)
      HTTParty.get(project_url_monitoring).code
    rescue
      nil
    end

  end

  class ReminderWorker
    include Sidekiq::Worker
    include SlackSender

    def perform(user_name_slack, name_user_for_reminder, reminder_text, reminder_time_chronic, reminder_time)
      @object_remind  = create_reminder_db(user_name_slack, name_user_for_reminder, reminder_text, reminder_time_chronic, reminder_time, self.jid)

      if @object_remind.reminder_time.include?(' every')
        if @object_remind.reminder_time.include?(' days') # Jean, can you remind me about SOME TEXT at => at 10:00 every 2 days, at 10:00 every 3 days
          remind_every_days(user_name_slack, reminder_time, reminder_text)
        elsif @object_remind.reminder_time.include?(' day') # Jean, can you remind me about SOME TEXT at 13:25 every day
          remind_every_day(user_name_slack, reminder_time, reminder_text, reminder_time_chronic)
        else # Jean, can you remind me about SOME TEXT at => at 10:00 every monday, at 10:00 every tuesday
          remind_every_weekday(user_name_slack, reminder_time, reminder_text, reminder_time_chronic)
        end
      else # Jean, can you remind @dname_user about SOME TEXT at => at Sunday 12:00,  at today 13:00,  at tomorrow 13:00, at 16:00
        remind_once(user_name_slack, name_user_for_reminder, reminder_time, reminder_text, reminder_time_chronic)
      end
    end

    private

    def remind_every_days(user_name_slack, reminder_time, reminder_text)
      begin
        after_days_number = /(\d+)\sdays?\z/.match(reminder_time)[1] # reminder_time => '9:00 every 5 days'  => "5"
        time = /([^\s]+)\s/.match(reminder_time)[1] # reminder_time => '9:00 every 5 days' => "9:00"
        time_chronic = Chronic.parse(time)
        first_in = time_chronic + after_days_number.to_i * 24 * 3600

        send_reminder_message_to_slack("Ok, i will remind, first time in\"#{first_in}\" ")
        scheduler = Rufus::Scheduler.new
        scheduler.every "#{after_days_number}d", :first_in => first_in do
          status_reminder =  Reminder.new.get_status_reminder(user_name_slack, reminder_time)
          if status_reminder == true # on(excluded) remind
            send_reminder_message_to_slack("Remind \"#{reminder_text}\" ")
          else
            scheduler.shutdown #(:terminate) # (:terminate or :kill (or nothing))
          end
        end
        scheduler.join
      rescue
        send_reminder_message_to_slack("You may have entered something wrong, please check and enter again")
      end
    end

    def remind_every_day(user_name_slack, reminder_time, reminder_text, reminder_time_chronic)
      begin
        if reminder_time_chronic < Time.now
          reminder_time_chronic = Chronic.parse(reminder_time) + 1.day
        end
        send_reminder_message_to_slack("Ok, i will remind, first time in\"#{reminder_time_chronic}\"")
        scheduler = Rufus::Scheduler.new
        scheduler.every '1d', :first_in => reminder_time_chronic do
          status_reminder =  Reminder.new.get_status_reminder(user_name_slack, reminder_time)
          if status_reminder == true # on(excluded) remind
            send_reminder_message_to_slack("Remind \"#{reminder_text}\" ")
          else
            scheduler.shutdown #(:terminate) # (:terminate or :kill (or nothing))
          end
        end
        scheduler.join
      rescue
        send_reminder_message_to_slack("You may have entered something wrong, please check and enter again")
      end
    end

    def remind_every_weekday(user_name_slack, reminder_time, reminder_text, reminder_time_chronic)
      begin
        send_reminder_message_to_slack("Ok, i will remind, first time in\"#{reminder_time_chronic}\"")
        scheduler = Rufus::Scheduler.new
        scheduler.every '7d', :first_in => reminder_time_chronic do
          status_reminder =  Reminder.new.get_status_reminder(user_name_slack, reminder_time)
          if status_reminder == true # on(excluded) remind
            send_reminder_message_to_slack("Remind \"#{reminder_text}\" ")
          else
            scheduler.shutdown #(:terminate) # (:terminate or :kill (or nothing))
          end
        end
        scheduler.join
      rescue
        send_reminder_message_to_slack("You may have entered something wrong, please check and enter again")
      end

    end

    def remind_once(user_name_slack, name_user_for_reminder, reminder_time, reminder_text, reminder_time_chronic)
      begin
        if wrong_time(reminder_time_chronic) == true
          send_reminder_message_to_slack(" You entered the wrong date \"#{reminder_time}\" ")
        else
          send_reminder_message_to_slack(" Ok, i will remind #{user_reminded(user_name_slack, name_user_for_reminder)} #{reminder_time_chronic} ")
          scheduler = Rufus::Scheduler.new
          scheduler.at reminder_time_chronic do
            status_reminder =  Reminder.new.get_status_reminder(user_name_slack, reminder_time)
            if status_reminder == true # on(excluded) reminder
              send_reminder_message_to_slack("<@#{user_name_slack}>,#{user_reminded(user_name_slack, name_user_for_reminder)} ask to remind you \"#{reminder_text}\" ")
              scheduler.shutdown #(:terminate) # (:terminate or :kill (or nothing))
            else
              scheduler.shutdown #(:terminate) # (:terminate or :kill (or nothing))
            end
          end
          scheduler.join
        end
      rescue
        send_reminder_message_to_slack("You may have entered something wrong, please check and enter again")
      end
    end

    def user_reminded(user_name_slack, name_user_for_reminder)
      if user_name_slack ==  name_user_for_reminder
        nil
      else
        "<@#{name_user_for_reminder}>"
      end
    end

    def create_reminder_db(user_name_slack, name_user_for_reminder, reminder_text, reminder_time_chronic, reminder_time, jid)
      Reminder.new.create_reminder_db(user_name_slack, name_user_for_reminder, reminder_text, reminder_time_chronic, reminder_time, jid)
    end

    def wrong_time(reminder_time_chronic)
      if reminder_time_chronic.nil? || reminder_time_chronic < Time.now
        true
      else
        false
      end
    end

  end

  class DeleteWorker
    include Sidekiq::Worker
    include SlackSender

    def perform(name_user_for_reminder, user_name_slack, reminder_time)
      result = Reminder.new.disable_reminder(user_name_slack, reminder_time)
      if result == nil
        send_reminder_message_to_slack("Sorry, i don`t remind you at that time.")
      else
        send_reminder_message_to_slack("Ok, no problem")
      end
    end

  end

end































