require 'slackbot_frd'
require 'securerandom'

require_relative '../lib/jira/search'
require_relative '../lib/gerrit/change'
require_relative './gerrit-jira-translator'

require_relative '../lib/gerrit-jira-translator/data'

class TicketStatusReport < SlackbotFrd::Bot
  GERRIT_ID_FIELD = "customfield_10403"
  FEEDBACK_REGEX = /!feedback\s+(.+)$/i
  QA_REGEX = /!qa\s+(.+)$/i

  def contains_feedback_trigger?(message)
    message =~ /(!feedback)/i
  end

  def contains_qa_trigger?(message)
    message =~ /(!qa)/i
  end

  def jql(project, status = 'Feedback')
    "project = #{project} AND status = '#{status}' ORDER BY updated ASC"
  end

  def add_callbacks(slack_connection)
    slack_connection.on_message do |user:, channel:, message:, timestamp:, thread_ts:|
      if message && user != 'angel' && timestamp != thread_ts &&
        ((feedback = contains_feedback_trigger?(message)) || (qa = contains_qa_trigger?(message)))
          handle_jiras(slack_connection, user, channel, message, thread_ts, is_feedback: feedback, is_qa: qa)
      end
    end
  end

  def handle_jiras(slack_connection, user, channel, message, thread_ts, is_feedback:, is_qa:)
    parser = GerritJiraTranslator.new
    search_api = Jira::Search.new(
      username: $slackbotfrd_conf['jira_username'],
      password: $slackbotfrd_conf['jira_password']
    )

    (is_feedback ? FEEDBACK_REGEX : QA_REGEX).match(message) do |matches|
      matches[1].split.each do |project|
        project.gsub!(/[^\w\s]/, '')
        if project =~ /#{parser.whitelisted_prefixes}/i
          issues = search_api.get (is_feedback ? jql(project, "Feedback") : jql(project, "QA Ready"))
          slack_connection.send_message(
            channel: channel,
            message: parse_issues(issues, project, (is_feedback ? "feedback" : "QA")),
            parse: 'none',
            thread_ts: thread_ts
          )
        end
      end
    end
  end

  def parse_issues(issues_json, project, status)
    parser = GerritJiraTranslator.new
    messages = []
    issues = issues_json["issues"] || []
    SlackbotFrd::Log.info("Parsing #{issues_json} for #{status}:")
    SlackbotFrd::Log.info(issues)
    issues.each do |issue|
      SlackbotFrd::Log.info("Parsing issue:")
      SlackbotFrd::Log.info(issue)
      f = issue["fields"]
      if (gerrit_field = f[GERRIT_ID_FIELD])
        gerrits = gerrit_field
                  .split
                  .select {|s| s =~ /http/}
                  .map {|url| url.split("/").last}
      end
      jira = {prefix: issue["key"].split("-").first, number: issue["key"].split("-").last}
      messages << "#{parser.priority_str(issue)} #{parser.jira_link(jira)} - #{f["summary"]}"
      messages << "*Assigned to*: #{parser.assigned_to_str(issue)}"
      if gerrit_field
        gerrits.each do |gerrit|
          messages << ":gerrit: :  <#{parser.gerrit_url(gerrit)}|g/#{gerrit}> : <#{parser.gerrit_mobile_url(gerrit)}|:iphone:>"
        end
      end
      messages << "\n"
    end
    messages << "No issues awaiting #{status} found for #{project}" if issues.empty?
    messages.join("\n")
  end
end
