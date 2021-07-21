# frozen_string_literal: true

require "mysql2"
require 'time'
require 'date'

require File.expand_path(File.dirname(__FILE__) + "/base.rb")

class ImportScripts::FLARUM < ImportScripts::Base
  #SET THE APPROPRIATE VALUES FOR YOUR MYSQL CONNECTION
  FLARUM_HOST ||= ENV['FLARUM_HOST'] || "db_host"
  FLARUM_DB ||= ENV['FLARUM_DB'] || "db_name"
  BATCH_SIZE ||= 1000
  FLARUM_USER ||= ENV['FLARUM_USER'] || "db_user"
  FLARUM_PW ||= ENV['FLARUM_PW'] || "db_user_pass"

  FLARUM_POSTS_DRY_RUN = !!ENV['FLARUM_POSTS_DRY_RUN']
  AVATAR_DIR ||= ENV['AVATAR_DIR'] || "/shared/import/data/import_uploads"

  def initialize
    super

    @htmlentities = HTMLEntities.new
    @placeholders = nil

    @client = Mysql2::Client.new(
      host: FLARUM_HOST,
      username: FLARUM_USER,
      password: FLARUM_PW,
      database: FLARUM_DB
    )
  end

  def execute
    import_users
    import_categories

    if ! FLARUM_POSTS_DRY_RUN
      import_posts
    else
      begin
        @@debug_file_before = File.open('/tmp/debug.1.before.txt', 'w+')
        @@debug_file_after =  File.open('/tmp/debug.2.after.txt', 'w+')

        Post.transaction do
          import_posts

          # don't actually create records so they won't be skipped on next run,
          # removing need to rollback DB externally before testing again
          raise ActiveRecord::Rollback, "nope"
        end
      ensure
        @@debug_file_before.close
        @@debug_file_after.close
      end
    end

    create_permalinks
  end

  def import_users
    puts '', "creating users"
    total_count = mysql_query("SELECT count(*) count FROM users;").first['count']

    batches(BATCH_SIZE) do |offset|
      results = mysql_query(
        "SELECT id, username, email, joined_at, last_seen_at, avatar_url
         FROM users
         LIMIT #{BATCH_SIZE}
         OFFSET #{offset};")

      break if results.size < 1

      next if all_records_exist? :users, results.map { |u| u["id"].to_i }

      create_users(results, total: total_count, offset: offset) do |user|
        { id: user['id'],
          email: user['email'],
          username: user['username'],
          name: user['username'],
          created_at: user['joined_at'],
          last_seen_at: user['last_seen_at'],
          post_create_action: proc do |u|
            import_profile_picture(user, u)
          end,
        }
      end
    end
  end

  def import_categories
    puts "", "importing top level categories..."

    categories = mysql_query("
                              SELECT id, name, description, position
                              FROM tags
                              ORDER BY position ASC
                            ").to_a

    create_categories(categories) do |category|
      {
        id: category["id"],
        name: category["name"]
      }
    end

    puts "", "importing children categories..."

    children_categories = mysql_query("
                                       SELECT id, name, description, position
                                       FROM tags
                                       ORDER BY position
                                      ").to_a

    create_categories(children_categories) do |category|
      {
        id: "child##{category['id']}",
        name: category["name"],
        description: category["description"],
      }
    end
  end

  def import_posts
    puts "", "creating topics and posts"

    total_count = mysql_query("SELECT count(*) count from posts").first["count"]

    batches(BATCH_SIZE) do |offset|
      results = mysql_query("
        SELECT p.id id,
               d.id topic_id,
               d.title title,
               d.first_post_id first_post_id,
               p.user_id user_id,
               p.content raw,
               p.created_at created_at,
               t.tag_id category_id
        FROM posts p,
             discussions d,
             discussion_tag t
        WHERE p.discussion_id = d.id
          AND t.discussion_id = d.id
        ORDER BY p.created_at
        LIMIT #{BATCH_SIZE}
        OFFSET #{offset};
      ").to_a

      break if results.size < 1
      next if all_records_exist? :posts, results.map { |m| m['id'].to_i }

      create_posts(results, total: total_count, offset: offset) do |m|
        skip = false
        mapped = {}

        mapped[:id] = m['id']
        mapped[:user_id] = user_id_from_imported_user_id(m['user_id']) || -1

        cleaned_content, extra = clean_up(m['raw'], m['id'])
        mapped[:reply_to_post_number] = extra[:reply_to_post_number]
        mapped[:raw] = cleaned_content

        mapped[:created_at] = Time.zone.at(m['created_at'])

        if m['id'] == m['first_post_id']
          mapped[:category] = category_id_from_imported_category_id("child##{m['category_id']}")
          mapped[:title] = CGI.unescapeHTML(m['title'])
        else
          parent = topic_lookup_from_imported_post_id(m['first_post_id'])
          if parent
            mapped[:topic_id] = parent[:topic_id]
          else
            puts "Parent post #{m['first_post_id']} doesn't exist. Skipping #{m["id"]}: #{m["title"][0..40]}"
            skip = true
          end
        end

        skip ? nil : mapped
      end
    end
  end

  def create_permalinks
    puts '', 'Creating redirects...', ''

    # users: https://discuss.flarum.org/u/askvortsov
    # no need to create User permalinks since URL is /u/#{username} both in Flarum and Discord

    # posts: https://discuss.flarum.org/d/26525-rfc-flarum-cli-alpha/5
    Post.find_each do |post|
      pcf = post.custom_fields
      if pcf && pcf["import_id"]
        id = topic_lookup_from_imported_post_id(pcf["import_id"])[:topic_id]
        topic = post.topic
        slug = Slug.for(topic.title) # probably matches what flarum would do...
        if post.post_number == 1
          Permalink.find_or_create_by(url: "d/#{id}-#{slug}", topic_id: topic.id)
        else
          Permalink.find_or_create_by(url: "d/#{id}-#{slug}/#{post.post_number}", post_id: post.id)
        end
        print '.'
      end
    end
  end

  #returns [ str, extra ] where extra is a hash of additional data
  def clean_up(raw, import_id)
    @@debug_file_before.puts "\n\n--- record #{import_id}\n\n#{raw}" if FLARUM_POSTS_DRY_RUN

    # NOTE: some BB is produced, which assumes the official BB code plugin is installed:
    # https://meta.discourse.org/t/discourse-bbcode/65425

    @placeholders = PlaceholderContainer.new

    # convert any tags with special meaning before they are treated as standard HTML by
    # HtmlToMarkdown and either mishandled or wiped away
    raw, extra = replace_valuable_html(raw)

    # use HtmlToMarkdown to turn remaining HTML into Markdown
    raw = strip_html(raw)

    raw = @placeholders.apply(raw)

    @@debug_file_after.puts "\n\n--- record #{import_id}\n\n#{raw}" if FLARUM_POSTS_DRY_RUN

    [ raw, extra ]
  end

  #returns [ str, extra ] where extra is a hash of additional data
  def replace_valuable_html(raw)
    extra = {}
    raw = @htmlentities.decode(raw)

    # HACK: remove anything within <s>, which in all cases seems to only add bogus markup
    # not production worthy - just to make sample data look good per audition instructions
    # NOTE: only lowercase <s> seems bogus, so no //i
    raw = raw.gsub(/<s>.*?<\/s>/m, '')

    raw = raw.gsub(/<url>(.*?)<\/url>/i, '\1')
    raw = raw.gsub(/<url url="(.*?)">(.*?)<\/url>/i, '[\2](\1)')

    # <c> <code> [pre]
    raw = raw.gsub(/<c>(.*?)<\/c>/mi, '[code]\1[/code]')
    raw = raw.gsub(/<code>(.*?)<\/code>/mi, '[code]\1[/code]')
    raw = raw.gsub(/\[pre\]/i, "<pre>")
    raw = raw.gsub(/\[\/pre\]/i, "</pre>")

    # [u] .. [/u] (need to use a placeholder since there's no underlining in .md and thus in HtmlToMarkdown)
    raw = raw.gsub(/<u>(.*?)<\/u>/) do
      bbcode = "[u]#{$1}[/u]"
      @placeholders.store(bbcode)
    end

    # [youtube] .. [/youtube]
    raw = raw.gsub(/\[youtube\](.*?)\[\/youtube\]/, 'https://www.youtube.com/watch?v=\1')

    # <POSTMENTION discussionid="8" displayname="meghna" id="31" number="3" username="meghna">@meghna#31</POSTMENTION>
    #   becomes:
    # [quote="meghna, post:3, topic:8"]@meghna#31[/quote]
    # FIXME: this should probably use a recursive regex
    raw = raw.gsub(/<postmention discussionId="(\d+)" displayname="(.*?)" id="(\d+)".*?>(.*?)<\/postmention>/im) do
      _, display_name, imported_post_id, tag_content = $1, $2, $3, $4

      #FIXME: add error checking
      imported = @lookup.topic_lookup_from_imported_post_id(imported_post_id)
      topic_id = imported[:topic_id]
      post_number = imported[:post_number]

      tag_content.gsub!(/@#{display_name}#\d+/, "@#{display_name}") # @meghna#31 -> @meghna

      # FIXME: this imports the post as a reply per last <postmention> occurrence in the text,
      # but ignores any others before it, and it assumes they're always for the current topic.
      # Ie. only semantically correct for posts with exactly 1 intra-topic <postmention>
      extra[:reply_to_post_number] = post_number

      quote = %Q{[quote="#{display_name}, post:#{post_number}, topic:#{topic_id}"]#{tag_content}[/quote]}
      @placeholders.store(quote)
    end

    # <quote> ... </quote>
    raw = raw.gsub(/<quote>(.+?)<\/quote>/im) do
      quote_content = $1.gsub(/<i>\s*>\s*<\/i>/i, '') # HACK - otherwise results in redundant >
      quote_content = html_to_markdown(quote_content).gsub(/\n+/, "\n > ")
      markdown = "\n> #{quote_content}\n"

      @placeholders.store(markdown)
    end

    # <list type="decimal"> ... </list>
    raw = raw.gsub(/<list type="decimal">(.+?)<\/list>/im) do
      list_contents = $1
      markdown = list_contents.gsub(/<li>(.*?)<\/li>/i, "\n 1. \\1") + "\n"
      @placeholders.store(markdown)
    end

    # <list> ... </list>
    raw = raw.gsub(/<list>(.+?)<\/list>/im) do
      list_contents = $1
      markdown = list_contents.gsub(/<li>(.*?)<\/li>/i, "\n - \\1") + "\n"
      @placeholders.store(markdown)
    end

    raw = raw.gsub(/<size size="(\d+)">(.*?)<\/size>/mi, '[size=\1]\2[/size]')
    raw = raw.gsub(/<color color="(.+?)">(.*?)<\/color>/mi, '[color=1]\2[/color]')

    raw = raw.gsub(/<center>(.*?)<\/center>/mi, '[center]\1[/center]')
    raw = raw.gsub(/<left>(.*?)<\/left>/mi, '[left]\1[/left]')
    raw = raw.gsub(/<right>(.*?)<\/right>/mi, '[right]\1[/right]')

    [ raw, extra ]
  end

  def strip_html(raw)
    raw = raw.gsub(/<r>(.*)<\/r>/im, '\1') #remove outside <r> tags
    raw = raw.gsub(/<t>(.*)<\/t>/im, '\1') #remove outside <t> tags

    html_to_markdown raw
  end

  def html_to_markdown(str)
    HtmlToMarkdown.new(str).to_markdown
  end

  def mysql_query(sql)
    @client.query(sql, cache_rows: false)
  end

  # Allows to leave placeholders in a string, which can then survive an otherwise destructive operation.
  # In this file, used to store bits of "hand cooked" markdown
  # so that the final HtmlToMarkdown call (which only expects HTML) doesn't destroy them.
  #
  # FIXME: improve abstraction
  class PlaceholderContainer
    def initialize
      @store = {}
    end

    # stores str under a new random key which is returned
    def store(str)
      key = SecureRandom.hex
      @store[key] = str
      key
    end

    # for a given string, replace all stored placeholders
    def apply(str)
      @store.each do |key, replacement|
        str = str.gsub(/#{key}/, replacement)
      end
      @store = {}
      str
    end
  end

  def import_profile_picture(old_user, imported_user)
    avatar_filename = old_user['avatar_url']
    if avatar_filename.present?
      path = File.join(AVATAR_DIR, avatar_filename)
      file = get_file(path)
      if file.present?
        upload = UploadCreator.new(file, file.path, type: "avatar").create_for(imported_user.id)

        if !upload.persisted?
          #FIXME: investigate etiquette
          STDERR.puts "upload not persisted for avatar of user #{imported_user['id']}"
          return
        end

        imported_user.create_user_avatar
        imported_user.user_avatar.update(custom_upload_id: upload.id)
        imported_user.update(uploaded_avatar_id: upload.id)
      end
    end
  ensure
    file.close rescue nil
  end

  def get_file(path)
    return File.open(path) if File.exist?(path)
    nil
  end
end

ImportScripts::FLARUM.new.perform

