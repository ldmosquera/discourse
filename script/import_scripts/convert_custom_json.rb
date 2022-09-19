# frozen_string_literal: true

require File.expand_path(File.dirname(__FILE__) + "/base.rb")

require 'htmlentities'
require 'nokogiri'

# Edit the constants and initialize method for your import data.

class ImportScripts::JsonGeneric < ImportScripts::Base

  JSON_USERS_FILE_PATH = ENV['JSON_USERS_FILE'] || 'script/import_scripts/support/sample.json'
  JSON_CATEGORIES_FILE_PATH = ENV['JSON_CATEGORIES_FILE'] || 'script/import_scripts/support/category.json'
  JSON_SUBCATEGORIES_FILE_PATH = ENV['JSON_SUBCATEGORIES_FILE'] || 'script/import_scripts/support/Boards.json'
  JSON_MESSAGES_FILE_PATH = ENV['JSON_MESSAGES_FILE'] || 'script/import_scripts/support/messages.json'
  BATCH_SIZE ||= 1000

  def initialize
    super

    puts "", "Reading in files"
    @imported_users_json = load_json(JSON_USERS_FILE_PATH)
    @imported_categories_json = load_json(JSON_CATEGORIES_FILE_PATH)
    @imported_subcategories_json = load_json(JSON_SUBCATEGORIES_FILE_PATH)
    @imported_messages_json = load_json(JSON_MESSAGES_FILE_PATH)

    @htmlentities = HTMLEntities.new
  end

  def execute
    puts "", "Importing"

    SiteSetting.max_category_nesting = 3

    import_groups
    import_users
    # "categories" and "boards" map to first and second level categories in Discourse respectively
    import_categories
    import_topics
    import_replies

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
    puts '', "Importing categories and boards"

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

    root_category_names = categories.map { |c| c['id'] }

    # move leaf categories to the end to ensure their parents will be created before them
    sorted_subcats =
      @imported_subcategories_json.
      map { |sc| sc['boards'] }.flatten(1).
      sort_by { |board| root_category_names.include? board['parent_category']['id'] ? 0 : 1 }

    sorted_subcats.each do |board|
      parent_category_name =
        case board['parent_category']['id']
          #HACK: pave over some inconsistencies
          when 'Schulungen_Events' then 'schulungen'
          when 'Praxisteam' then 'Praxisteams'
          else
            board['parent_category']['id']
        end

      parent_category = categories.find { |c| c[:id] == parent_category_name }

      raise "ERROR: non existing root category #{parent_category_name}" unless parent_category

      categories << {
        id: board['id'],
        name: board['title'],

        #FIXME: this field probably needs massaging of some kind
        position: board['position'],

        description: board['description'],
        parent_category_id: parent_category[:id],
      }
    end

    categories.uniq!

    create_categories(categories) do |category|
      category = HashWithIndifferentAccess.new(category)

      if category['parent_category_id'].present?
        parent_category_id = category_id_from_imported_category_id(category['parent_category_id'])
      end

      {
        id: category['id'],
        name: category['name'],
        position: category['position'],
        description: strip_html(category['description']),
        parent_category_id: parent_category_id,
      }
    end
  end

  def post_from_message(inner_message)
    p = {}

    id = inner_message['id']
    user_id = user_id_from_imported_user_id(inner_message['author']['id'])

    return nil unless user_id

    p.merge!({
      id: id,
      user_id: user_id,
      category: category_id_from_imported_category_id(inner_message['board']['id']),
      raw: inner_message['body'],
      created_at: inner_message['post_time'],
      views: inner_message['metrics']['views'],
      import_mode: true,
    })

    if first_post_id = inner_message.dig('parent', 'id')
      topic_id = topic_lookup_from_imported_post_id(first_post_id)&.[](:topic_id)

      # raise "ERROR: topic_id not found for first post #{first_post_id} for post #{id}" unless topic_id

      p.merge! topic_id: topic_id
    else
      p.merge! title: @htmlentities.decode(inner_message['subject']).strip[0...255]
    end

    p
  end

  def import_topics
    puts '', "Importing topics"

    topics = @imported_messages_json.
      select { |m| m['Message']['parent'].nil? }.
      map { |message| post_from_message(message['Message']) }

    create_posts(topics, total: topics.count) do |topic|
      topic
    end
  end

  def import_replies
    puts '', "Importing replies"

    posts = @imported_messages_json.
      reject { |m| m['Message']['parent'].nil? }.
      sort_by { |m| [ m['Message']['parent']['id'], m['Message']['depth'] ] }.
      map { |message| post_from_message(message['Message']) }


    create_posts(posts, total: posts.count) do |post|
      post
    end
  end

  def strip_html(html)
    Nokogiri::HTML(html).text
  end

end

if __FILE__ == $0
  ImportScripts::JsonGeneric.new.perform
end
