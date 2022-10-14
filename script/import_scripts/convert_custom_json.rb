# frozen_string_literal: true

require File.expand_path(File.dirname(__FILE__) + "/base.rb")

require 'htmlentities'
require 'nokogiri'

# Edit the constants and initialize method for your import data.

class ImportScripts::JsonGeneric < ImportScripts::Base

  JSON_USERS_FILE_PATH = ENV['JSON_USERS_FILE'] || 'script/import_scripts/support/sample.json'
  JSON_BOARDS_FILE_PATH = ENV['JSON_BOARDS_FILE'] || 'script/import_scripts/support/boards_and_categories.json'
  JSON_MESSAGES_FILE_PATH = ENV['JSON_MESSAGES_FILE'] || 'script/import_scripts/support/messages.json'
  BATCH_SIZE ||= 1000

  def initialize
    super

    puts "", "Reading in files"
    @imported_users_json = load_json(JSON_USERS_FILE_PATH)
    @imported_boards_json = load_json(JSON_BOARDS_FILE_PATH)
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

    # FIXME: implement
    # import_badges

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
    # NOTE:
    # "Khoros categories" map to first level Discourse categories and do not directly contain posts
    # "Khoros boards" map to 2nd level categories and beyond
    puts '', "Importing categories and boards"

    categories = @imported_boards_json.
      sort_by{|r| r['order'].to_i}.
      map do |r|
        {
          # deduplicated between cats and boards
          id:                 r['id_to_use'].presence || r['id'],
          title:              r['title'],
          # NOTE: can be either a Khoros category or a board
          parent_category_id: r['parent_id_to_use'].presence || r['parent_id'],
          created_at:         r['created_at'],
          description:        r['description'],
          language:           r['language'],
          url:                r['url'],
        }
      end

    create_categories(categories) do |category|
      category = HashWithIndifferentAccess.new(category)

      if pcid = category['parent_category_id'].presence
        parent_category_id = category_id_from_imported_category_id(pcid)

        unless parent_category_id
          raise "ERROR: non existing parent category #{pcid} for board #{category[:id]}"
        end
      end

      {
        id: category['id'],
        name: category['title'],
        description: strip_html(category['description']),
        parent_category_id: parent_category_id,
        created_at: Time.parse(category['created_at']),

        post_create_action: proc do |c|
          if category['language'].present?
            c.custom_fields['import_language'] = category['language']
          end

          if category['url'].present?
            Permalink.create! url: path_from(category['url']), category_id: c.id
            c.custom_fields['import_url'] = category['url']
          end

          c.save_custom_fields
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

        begin
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
        end

        if cover_url = message['cover_image']['href'].presence
          post.topic.custom_fields['header_image_url'] = cover_url
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

