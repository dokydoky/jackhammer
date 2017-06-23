class GithubPullInfoWorker
	include Sidekiq::Worker
	include Sidekiq::Status::Worker
	sidekiq_options unique: :while_executing
	sidekiq_options({ :queue => :gitpull,:retry => 2 })
	def perform
		Octokit.auto_paginate = true
		Dir.mkdir(Rails.root + "log/scans") unless File.exists?(Rails.root + "log/scans")
		@logfile = File.open(Rails.root.join("log/scans/github_pull.log"), 'a')
		raise StandardError,"Github details are not configured" unless Setting['github']
		raise StandardError,"Api access token is not configured" unless Setting['github']['api_access_token']
		AlertNotification.create(
			user_id: Setting['gitlab']['user_id'].to_i,
			identifier: 'task',
			alert_type: 'success',
			message: 'Pulling git info started...',
			task_name: "Git pull")


		crypt = ActiveSupport::MessageEncryptor.new(Rails.application.secrets.secret_key_base)
		client = Octokit::Client.new(:access_token => crypt.decrypt_and_verify(Setting['github']['api_access_token']))
		github_org = client.orgs.first[:login]
		default_team = Team.find_or_create_by(name: 'GitHub')

		client.org_repos(github_org).each do |r|
			@logfile.puts "Pulling GitHub repo #{r[:name]}"
			repo = Repo.where(name: r[:name]).first_or_initialize
			repo.ssh_repo_url = r[:clone_url]
			repo.team = repo.team ? repo.team : default_team
			repo.git_type = "github"
			repo.repo_type = "Static"
			repo.save

			# Branch
			begin
				branches_github = client.branches(r[:full_name]).map {|b| b[:name]}
			rescue Octokit::NotFound => e
				branches_github = []
				@logfile.puts "No branch: team:#{git_team[:name]} repo:#{project[:name]} #{e.inspect}"
			end
			branches_db = repo.branches.map {|b| b.name}
			(branches_github - branches_db).each do |name|
				branch = Branch.create(repo: repo, name: name)
				@logfile.puts "New branch: #{branch.name} on #{r[:full_name]}"
			end

			(branches_db - branches_github).each do |name|
				if b = Branch.where(repo: repo, name: name)
					Branch.delete(b)
					@logfile.puts "Removed branch: #{name} on #{r[:full_name]}"
				end
			end
		end

		AlertNotification.create(
			user_id: Setting['github']['user_id'].to_i,
			identifier: 'task',
			alert_type: 'success',
			message: 'Pulling git info done!',
			task_name: "Git pull")
	rescue StandardError => e
		@logfile.puts e.message
		AlertNotification.create(
			user_id: Setting['github']['user_id'].to_i,
			identifier: 'task',
			alert_type: 'danger',
			message: e.message,
			task_name: "Git pull")
		raise e
	ensure
			@logfile.close
	end
end
