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

  def path_from(url)
    # remove leading slash
    URI(url).path[1..-1]
  end

  def trim_empty_values(hash)
    Hash[ * hash.to_a.select { |k,v| v.presence }.flatten ]
  end

  def import_users
    puts '', "Importing users"

    @imported_users_json.uniq!

    create_users(@imported_users_json) do |u|
      username = u['login'].presence || SecureRandom.hex

      {
        id: u['id'],
        username: username,
        name: "#{u['first_name']} #{u['last_name']}",
        email: u['email'],
        bio_raw: u['biography'],
        location: u['location'],
        created_at: u['registration_time'],
        import_mode: true,

        custom_fields: trim_empty_values({
          'import_avatar_url': u['avatar_url'].presence,
          'import_url': u['profile_url'].presence,
        }),

        post_create_action: proc do |user|
          # if u['avatar_url'].present?
          #   UserAvatar.import_url_for_user(u['avatar_url'], user) rescue nil
          # end
          u['roles'].each do |r|
            if group_id = group_id_from_imported_group_id(r['id'])
              GroupUser.find_or_create_by!(user_id: user.id, group_id: group_id)
            end
          end

          if u['profile_url'].presence && u['login'].presence
            Permalink.create! url: path_from(u['profile_url']), external_url: "/u/#{username}"
          end
        end
      }
    end
  end

  def import_sso_records
    puts '', "Importing SSO records"

    external_ids = {}

    # deduplicate by external_id ensuring the biggest user_id "wins out"
    sso_records = @imported_users_json.
      select  {|r| r['sso_id'].presence }.
      sort_by {|r| r['id'].to_i }.
      each    {|r| external_ids[r['sso_id']] = [ r['id'], r['email'] ] }

    external_ids.each do |external_id, (khoros_user_id, email)|
      user_id = user_id_from_imported_user_id(khoros_user_id)

      begin
        raise "unknown imported user ID #{khoros_user_id}" unless user_id

        SingleSignOnRecord.create!(user_id: user_id, external_id: external_id, external_email: email, last_payload: '')
      rescue Exception => ex
        STDERR.puts "\nERROR when creating SSO record for #{user_id}: #{ex}"
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
          url: category['view_href'],
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
            url: board['url'],
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
          custom_fields_changed = false

          if category['language'].present?
            c.custom_fields['import_language'] = category['language']
            custom_fields_changed = true
          end

          if category['url'].present?
            Permalink.create! url: path_from(category['url']), category_id: c.id

            c.custom_fields['import_url'] = category['url']
            custom_fields_changed = true
          end

          c.save_custom_fields if custom_fields_changed
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

    post_style = message['style']

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

        post_custom_fields_changed = false

        if post_style.presence
          post.custom_fields['import_post_style'] = post_style
          post_custom_fields_changed = true
        end

        if url = message['url'].presence
          Permalink.create! url: path_from(url), post_id: post.id

          post.custom_fields['import_url'] = url
          post_custom_fields_changed = true
        end

        post.save_custom_fields if post_custom_fields_changed

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

  def drop_posts_for_newer_users(posts)
    last_user_created_at = User.last.created_at

    before = posts.count

    posts.reject! { |p| Date.parse(p['post_time']) > last_user_created_at }

    after = posts.count

    if (after - before).abs != 0
      STDERR.puts "WARN - dropping #{before - after} posts after last user creation date of #{last_user_created_at}"
    end

    posts
  end

  def import_topics
    puts '', "Importing topics"

    topics = @imported_messages_json.
      select  { |m| m['depth'] == 0 }.
      sort_by { |m| m['id'].to_i }

    topics = drop_posts_for_newer_users topics

    topics = topics.map{ |m| post_from_message(m, is_first_post: true) }.compact

    create_posts(topics, total: topics.count) do |topic|
      topic
    end
  end

  def import_replies
    puts '', "Importing replies"

    posts = @imported_messages_json.
      reject  { |m| m['depth'] == 0 }.
      sort_by { |m| m['id'].to_i }

    posts = drop_posts_for_newer_users posts

    posts = posts.map{ |m| post_from_message(m, is_first_post: true) }.compact

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

