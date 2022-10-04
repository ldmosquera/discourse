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

    @missing_user_id = User.create!(
      username: 'missing_user',
      email: 'missing_user@invalid.email',
    ).id

    @htmlentities = HTMLEntities.new
  end

  def execute
    puts "", "Importing"

    SiteSetting.max_category_nesting = 3

    # per customer request:
    SiteSetting.min_username_length = 2
    SiteSetting.unicode_usernames = true

    import_groups
    import_users
    import_sso_records

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
      u['id'] = user['id']
      u['external_id'] = user['sso_id']
      u['username'] = user['login']
      u['email'] = user['email']
      u['name'] = "#{user['first_name']} #{user['last_name']}"
      u['avatar_url'] = user['avatar_url']
      u['bio_raw'] = user['biography']
      u['location'] = user['location']
      u['created_at'] = user['registration_time']
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
        import_mode: true,

        custom_fields: ({
          'import_avatar_url': u['avatar_url'],
        } if u['avatar_url'].presence),

        post_create_action: proc do |user|
          # if u['avatar_url'].present?
          #   UserAvatar.import_url_for_user(u['avatar_url'], user) rescue nil
          # end
          u['group_ids'].each do |g|
            group_id = group_id_from_imported_group_id(g)
            if group_id
              GroupUser.find_or_create_by(user_id: user.id, group_id: group_id)
            end
          end
        end
      }
    end
  end

  def import_sso_records
    puts '', "Importing SSO records"

    sso_records = @imported_users_json.
      sort_by {|r| - r['id'].to_i }.  #sort in reverse to ensure the latest user_id wins out in case of duplicates
      map     {|r| [ r['id'], r['external_id'], r['email'] ] if r['external_id'] }.
      compact

    sso_records.each do |user_id, external_id, email|
      user_id = user_id_from_imported_user_id user_id

      begin
        SingleSignOnRecord.create!(user_id: user_id, external_id: u['external_id'], external_email: u['email'], last_payload: '')
      rescue Exception => ex
        STDERR.puts "ERROR when creating SSO record for #{user.id}: #{ex}"
      end
      print '.'
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
        creation_date: category['creation_date'],
      }

      if category['parent_category'].empty? # To ensure parents are created first
        categories.unshift(c)
      else
        c['parent_category_id'] = category['root_category']['id']
        categories << c
      end
    end

    # sort breadth first
    sorted_subcats = @imported_subcategories_json.sort_by { |board| [ board['language'], board['depth'], board['position'] ] }

    sorted_subcats.each do |board|
      parent_category_name = board['parent_category_id']
      parent_category = categories.find { |c| c[:id] == parent_category_name }

      unless parent_category
        STDERR.puts "ERROR: non existing root category #{parent_category_name} for board #{board['id']}"
        next
      end

      categories << {
        id: board['id'],
        name: board['title'],

        #FIXME: this field probably needs massaging of some kind
        position: board['position'],

        description: board['description'],
        parent_category_id: parent_category[:id],
        creation_date: board['creation_date'],
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
        created_at: Time.parse(category['creation_date']),

        post_create_action: proc do |c|
          if category['language'].present?
            c.custom_fields['import_language'] = category['language']
            c.save!
          end

          if category['url'].present?
            c.custom_fields['import_url'] = category['url']
            c.save!
          end
        end
      }
    end
  end

  def staff_guardian
    @_staff_guardian ||= Guardian.new(Discourse.system_user)
  end

  def post_from_message(message, is_first_post:)
    p = {}

    id = message['id']
    user_id = user_id_from_imported_user_id(message['author']['id']) || @missing_user_id

    p.merge!({
      id: id,
      user_id: user_id,
      category: category_id_from_imported_category_id(message['board']['id']),
      title: strip_html_entities(message['subject'])[0...255],
      raw: message['body'],
      created_at: message['post_time'],
      views: message['metrics']['views'],
      cook_method: Post.cook_methods[:raw_html],
      import_mode: true,
      post_create_action: proc do |post|
        message['kudos'].each do |k|
          liker_id = user_id_from_imported_user_id(k['user_id']) || @missing_user_id
          liker = User.find_by_id liker_id

          PostActionCreator.like(liker, post) if liker
        end

        if message['labels'].any?
          tag_names = message['labels']

          DiscourseTagging.tag_topic_by_names(post.topic, staff_guardian, tag_names)
        end

        if message['url'].present?
          tag_names = message['url']

          post.custom_fields['import_url'] = message['url']
          post.save!
        end
      end
    })

    if ! is_first_post
      first_post_id = message.dig('topic', 'id')
      result = topic_lookup_from_imported_post_id(first_post_id)

      if result
        p.merge! topic_id: result[:topic_id]
      else
        STDERR.puts "ERROR: first post not found for post #{message['id']}"
        return nil
      end
    end

    p
  end

  def import_topics
    puts '', "Importing topics"

    topics = @imported_messages_json.
      select  { |m| m['depth'] == 0 }.
      sort_by { |m| m['id'].to_i } .
      map     { |m| post_from_message(m, is_first_post: true) }.
      compact

    create_posts(topics, total: topics.count) do |topic|
      topic
    end
  end

  def import_replies
    puts '', "Importing replies"

    posts = @imported_messages_json.
      reject  { |m| m['depth'] == 0 }.
      sort_by { |m| m['id'].to_i } .
      map     { |m| post_from_message(m, is_first_post: false) }.
      compact

    create_posts(posts, total: posts.count) do |post|
      post
    end
  end

  def strip_html(html)
    Nokogiri::HTML(html).text
  end

  def strip_html_entities(text)
    @htmlentities.decode(text).strip
  end

end

if __FILE__ == $0
  ImportScripts::JsonGeneric.new.perform
end
