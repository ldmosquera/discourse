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

    missing_user_email = 'missing_user@invalid.email'

    @missing_user_id = UserEmail.find_by_email(missing_user_email)&.user_id ||
      User.create!(
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
    import_categories
    import_topics
    import_replies

    puts "", "Done"
  end

  def load_json(path)
    return [] if path == 'SKIP'

    JSON.parse(File.read(path))
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

    @imported_users_json.uniq!

    create_users(@imported_users_json) do |u|
      {
        id: u['id'],
        username: (u['login'].presence || SecureRandom.hex),
        name: "#{u['first_name']} #{u['last_name']}",
        email: u['email'],
        bio_raw: u['biography'],
        location: u['location'],
        created_at: u['registration_time'],
        import_mode: true,

        custom_fields: ({
          'import_avatar_url': u['avatar_url'],
        } if u['avatar_url'].presence),

        post_create_action: proc do |user|
          # if u['avatar_url'].present?
          #   UserAvatar.import_url_for_user(u['avatar_url'], user) rescue nil
          # end
          u['roles'].each do |r|
            if group_id = group_id_from_imported_group_id(r['id'])
              GroupUser.find_or_create_by!(user_id: user.id, group_id: group_id)
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
      map     {|r| [ r['id'], r['sso_id'], r['email'] ] if r['sso_id'] }.
      compact

    sso_records.each do |user_id, external_id, email|
      user_id = user_id_from_imported_user_id(user_id)

      raise unless user_id

      begin
        SingleSignOnRecord.create!(user_id: user_id, external_id: external_id, external_email: email, last_payload: '')
      rescue Exception => ex
        STDERR.puts "ERROR when creating SSO record for #{user_id}: #{ex}"
      end
      print '.'
    end
  end

  def import_categories
    # NOTE: "categories" map to first level Discourse categories; "boards" map to 2nd level and beyond
    puts '', "Importing categories and boards"

    categories = []

    # Khoros "categories" are top level categories
    categories.concat(
      @imported_categories_json.map do |category|
        {
          id: category['id'],
          name: category['title'],
          position: category['position'],
          description: category['description'],
          creation_date: category['creation_date'],
          language: category['language'],
        }
      end
    )

    # Khoros "boards" are children categories to the above
    categories.concat(
      @imported_subcategories_json.
        sort_by { |board| [ board['order'] ] }.
        map do |board|
          {
            id: board['id'],
            name: board['title'],

            #FIXME: this field probably needs massaging of some kind
            position: board['position'],

            description: board['description'],
            parent_category_id: board['parent_category_id'],
            creation_date: board['creation_date'],
            language: board['language'],
          }
        end
    )

    # validation: drop categories with unknown parent_category_id (NOTE: resolve data issues before proceeding)
    categories = categories.map do |category|
      if parent_id = category[:parent_category_id]
        unless categories.find { |c| c[:id] == parent_id }
          STDERR.puts "ERROR: non existing parent category #{parent_id} for board #{category[:id]}"
          next
        end
      end

      category
    end.compact

    #pull categories
    #categories = categories.partition{|c| c[:parent_category_id].nil? }.flatten

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
            c.save_custom_fields
          end

          if category['url'].present?
            c.custom_fields['import_url'] = category['url']
            c.save_custom_fields
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

    category_id = category_id_from_imported_category_id(message['board']['id'])

    #skip posts for which category ID can't be found, because if it's not in categories/boards data then it's unwanted
    return nil if category_id.nil?

    id = message['id']
    user_id = user_id_from_imported_user_id(message['author']['id']) || @missing_user_id

    p.merge!({
      id: id,
      user_id: user_id,
      category: category_id,
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
          post.save_custom_fields
        end

        if message['cover_image']['href'].presence
          post.topic.custom_fields['header_image_url'] = message['cover_image']['href']
          post.topic.save_custom_fields
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

