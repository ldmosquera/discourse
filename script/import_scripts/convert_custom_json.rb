# frozen_string_literal: true

require File.expand_path(File.dirname(__FILE__) + "/base.rb")

# Edit the constants and initialize method for your import data.

class ImportScripts::JsonGeneric < ImportScripts::Base

  JSON_USERS_FILE_PATH = ENV['JSON_USERS_FILE'] || 'script/import_scripts/support/sample.json'
  JSON_CATEGORIES_FILE_PATH = ENV['JSON_CATEGORIES_FILE'] || 'script/import_scripts/support/category.json'
  JSON_SUBCATEGORIES_FILE_PATH = ENV['JSON_SUBCATEGORIES_FILE'] || 'script/import_scripts/support/Boards.json'
  BATCH_SIZE ||= 1000

  def initialize
    super

    @imported_users_json = load_json(JSON_USERS_FILE_PATH)
    @imported_categories_json = load_json(JSON_CATEGORIES_FILE_PATH)
    @imported_subcategories_json = load_json(JSON_SUBCATEGORIES_FILE_PATH)
  end

  def execute
    puts "", "Importing from JSON file..."

    import_groups
    import_users
    import_categories
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
      u['external_id'] = user['User']['sso_id']
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
            group_id = group_id_from_imported_group_id(g)
            if group_id
              GroupUser.find_or_create_by(user_id: user.id, group_id: group_id)
            end
          end
          if u['external_id'].present?
            SingleSignOnRecord.create!(user_id: user.id, external_id: u['external_id'], external_email: u['email'], last_payload: '')
          end
        end
      }
    end
  end

  def import_categories
    puts '', "Importing categories"

    categories = []
    @imported_categories_json.each do |category|
      c = {
        id: category['id'],
        name: category['title'],
        position: category['position'],
        description: category['description'],
      }

      if category['parent_category'].empty? # To ensure parents are created first
        categories.unshift(c)
      else
        c['parent_category_id'] = category['root_category']['id']
        categories << c
      end
    end
    categories.uniq!
    
    create_categories(categories) do |category|
      if category['parent_category_id'].present?
        parent_category_id = category_id_from_imported_category_id(category['parent_category_id'])
      end

      {
        id: category['id'],
        name: category['name'],
        position: category['position'],
        description: category['description'],
        parent_category_id: parent_category_id,
      }
    end
  end
end

if __FILE__ == $0
  ImportScripts::JsonGeneric.new.perform
end
