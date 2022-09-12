# frozen_string_literal: true

require File.expand_path(File.dirname(__FILE__) + "/base.rb")

# Edit the constants and initialize method for your import data.

class ImportScripts::JsonGeneric < ImportScripts::Base

  JSON_USERS_FILE_PATH = ENV['JSON_FILE'] || 'script/import_scripts/support/sample.json'
  BATCH_SIZE ||= 1000

  def initialize
    super

    @imported_users_json = load_json(JSON_USERS_FILE_PATH)
  end

  def execute
    puts "", "Importing from JSON file..."

    import_groups
    import_users
    puts "", "Done"
  end

  def load_json(path)
    JSON.parse(File.read(path))
  end

  def username_for(name)
    result = name.downcase.gsub(/[^a-z0-9\-\_]/, '')

    if result.blank?
      result = Digest::SHA1.hexdigest(name)[0...10]
    end

    result
  end

  def import_groups
    puts '', "Importing groups"

    groups = []
    @imported_users_json.each do |user|
      user['roles'].each do |u|
        g = {}
        g['id'] = u['id']
        g['name'] = u['name']
        groups << g
      end
    end
    groups.uniq!

    create_groups(groups) do |group|
      {
        id: group['id'],
        name: group['name']
      }
    end
  end

  def import_users
    puts '', "Importing users"

    users = []
    @imported_users_json.each do |user|
      u = {}
      u['id'] = user['User']['id']
      u['username'] = user['User']['login']
      u['email'] = user['User']['email']
      u['name'] = "#{user['User']['first_name']} #{user['User']['last_name']}"
      u['avatar_url'] = user['User']['avatar']['profile']
      u['bio_raw'] = user['User']['biography']
      u['location'] = user['User']['location']
      u['created_at'] = user['User']['registration_data']['registration_time']
      u['group_ids'] = []
      user['roles'].each do |group|
        u['group_ids'] << group['id']
      end
      users << u
    end
    users.uniq!

    create_users(users) do |u|
      {
        id: u['id'],
        username: username_for(u['username']),
        name: u['name'],
        email: u['email'],
        bio_raw: u['bio_raw'],
        location: u['location'],
        created_at: u['created_at'],
        post_create_action: proc do |user|
          if u['avatar_url'].present?
            UserAvatar.import_url_for_user(u['avatar_url'], user) rescue nil
          end
          u['group_ids'].each do |g|
            user_id = user_id_from_imported_user_id(u['id'])
            group_id = group_id_from_imported_group_id(g)
            if user_id && group_id
              GroupUser.find_or_create_by(user_id: user_id, group_id: group_id)
            end
          end
        end
      }
    end
  end
end

if __FILE__ == $0
  ImportScripts::JsonGeneric.new.perform
end
