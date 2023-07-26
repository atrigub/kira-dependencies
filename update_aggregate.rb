# This script is designed to loop through all dependencies in a GHE or GitLab
# project, creating PRs where necessary.
#
# It is intended to be used as a stop-gap until Dependabot's hosted instance
# supports GitHub Enterprise and GitLab (coming soon!)

require "json"
require "dependabot/file_fetchers"
require "dependabot/file_parsers"
require "dependabot/update_checkers"
require "dependabot/file_updaters"
require "dependabot/pull_request_creator"
require "dependabot/pull_request_updater"
require "dependabot/omnibus"
require "gitlab"

gitlab_hostname = ENV["GITLAB_HOSTNAME"] || "gitlab.com"
credentials = [
  {
    "type" => "git_source",
    "host" => "github.com",
    "username" => "x-access-token",
    "password" => ENV["KIRA_GITHUB_PERSONAL_TOKEN"] || nil
  }
]

credentials << {
  "type" => "git_source",
  "host" => gitlab_hostname,
  "username" => "x-access-token",
  # A GitLab access token with API permission
  "password" => ENV["KIRA_GITLAB_PERSONAL_TOKEN"]
}

json_credentials = ENV['DEPENDABOT_EXTRA_CREDENTIALS'] || ""
unless json_credentials.to_s.strip.empty?
  json_credentials = JSON.parse(json_credentials)
  credentials.push(*json_credentials)
end

# expected format is {"vendor/package": [">0.1.0", ">0.2.0"]}
ignored_versions_json = ENV["DEPENDABOT_IGNORED_VERSIONS"] || ""
ignored_versions = {}
unless ignored_versions_json.to_s.strip.empty?
  ignored_versions = JSON.parse(ignored_versions_json)
end

# Full name of the repo you want to create pull requests for.
repo_name = ENV["DEPENDABOT_PROJECT_PATH"] # namespace/project

# Directory where the base dependency files are.
directory = ENV["DEPENDABOT_DIRECTORY"] || "/"

# See lists of update strategies here:
# https://github.com/wemake-services/kira-dependencies/issues/39
update_strategy = ENV['DEPENDABOT_UPDATE_STRATEGY']&.to_sym || nil

# See description of requirements here:
# https://github.com/dependabot/dependabot-core/issues/600#issuecomment-407808103
excluded_requirements = ENV['DEPENDABOT_EXCLUDE_REQUIREMENTS_TO_UNLOCK']&.split(" ")&.map(&:to_sym) || []

# stop the job if an exception occurs
fail_on_exception = ENV['KIRA_FAIL_ON_EXCEPTION'] == "true"

# Assignee to be set for this merge request.
# Works best with marge-bot:
# https://github.com/smarkets/marge-bot
assignees = [ENV["DEPENDABOT_ASSIGNEE_GITLAB_ID"]].compact
assignees = nil if assignees.empty?

package_manager = ENV["PACKAGE_MANAGER"] || "bundler"

# Source branch for merge requests
source_branch = ENV["DEPENDABOT_SOURCE_BRANCH"] || nil

source = Dependabot::Source.new(
  provider: "gitlab",
  hostname: gitlab_hostname,
  api_endpoint: "https://#{gitlab_hostname}/api/v4",
  repo: repo_name,
  directory: directory,
  branch: source_branch,
)

##############################
# Fetch the dependency files #
##############################
puts "Fetching #{package_manager} dependency files for #{repo_name}"
fetcher = Dependabot::FileFetchers.for_package_manager(package_manager).new(
  source: source,
  credentials: credentials,
)

files = fetcher.files
commit = fetcher.commit

dependenciesOptions = ENV["DEPENDENCIES"] || 'ft,phplib,ecom'
unless dependenciesOptions.nil?
    dependenciesOptions = dependenciesOptions.split(",").map { |o| o.strip.downcase }
end

##############################
# Parse the dependency files #
##############################
puts "Parsing dependencies information"
parser = Dependabot::FileParsers.for_package_manager(package_manager).new(
  dependency_files: files,
  source: source,
  credentials: credentials,
)

dependencies = parser.parse

if dependenciesOptions.nil?
  dependencies.select!(&:top_level?)
else
  dependencies.select! do |d|
    dependenciesOptions.any? { |s| d.name.downcase.include?(s) }
  end
end

opened_merge_requests = 0
updated_deps = []
dependencies.each do |dep|

  begin

    #########################################
    # Get update details for the dependency #
    #########################################
    checker = Dependabot::UpdateCheckers.for_package_manager(package_manager).new(
      dependency: dep,
      dependency_files: files,
      credentials: credentials,
      requirements_update_strategy: update_strategy,
      ignored_versions: ignored_versions[dep.name] || []
    )

    next if checker.up_to_date?

    requirements_to_unlock =
      if !checker.requirements_unlocked_or_can_be?
        if !excluded_requirements.include?(:none) && checker.can_update?(requirements_to_unlock: :none) then :none
        else :update_not_possible
        end
      elsif !excluded_requirements.include?(:own) && checker.can_update?(requirements_to_unlock: :own) then :own
      elsif !excluded_requirements.include?(:all) && checker.can_update?(requirements_to_unlock: :all) then :all
      else :update_not_possible
      end

    next if requirements_to_unlock == :update_not_possible

    deps = checker.updated_dependencies(
      requirements_to_unlock: requirements_to_unlock
    )

    updated_deps.concat(deps)

  rescue StandardError => e
    raise e if fail_on_exception
    puts "error updating #{dep.name} (continuing)"
    puts e.full_message
  end
end

unless updated_deps.empty?
    begin
        #####################################
        # Generate updated dependency files #
        #####################################
        # print "\n  - Updating #{dep.name} (from #{dep.version})…"
        updater = Dependabot::FileUpdaters.for_package_manager(package_manager).new(
          dependencies: updated_deps,
          dependency_files: files,
          credentials: credentials,
        )

        updated_files = updater.updated_dependency_files

        ########################################
        # Create a pull request for the update #
        ########################################
        pr_creator = Dependabot::PullRequestCreator.new(
            source: source,
            base_commit: commit,
            dependencies: updated_deps,
            files: updated_files,
            credentials: credentials,
            label_language: true,
            assignees: assignees
        )
        pull_request = pr_creator.create

        puts "Pull request created."
    rescue StandardError => e
        raise e if fail_on_exception
        puts "error updating #{dep.name} (continuing)"
        puts e.full_message
    end
else
    puts 'Dependencies are up to date'
end

puts "Done!"