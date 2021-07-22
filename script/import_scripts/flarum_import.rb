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

  end

  def import_users
    puts '', "creating users"
    total_count = mysql_query("SELECT count(*) count FROM users;").first['count']

    batches(BATCH_SIZE) do |offset|
      results = mysql_query(
        "SELECT id, username, email, joined_at, last_seen_at
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
          last_seen_at: user['last_seen_at']
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
        mapped[:raw] = clean_up(m['raw'], m['id'])
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

  def clean_up(raw, import_id)
    @@debug_file_before.puts "\n\n--- record #{import_id}\n\n#{raw}" if FLARUM_POSTS_DRY_RUN

    @placeholders = PlaceholderContainer.new

    raw = replace_valuable_html(raw)
    raw = strip_html(raw)
    raw = @placeholders.apply(raw)

    @@debug_file_after.puts "\n\n--- record #{import_id}\n\n#{raw}" if FLARUM_POSTS_DRY_RUN

    raw
  end

  def replace_valuable_html(raw)
    raw = @htmlentities.decode(raw)

    # HACK: remove anything within <s>, which in all cases seems to only add bogus markup
    # not production worthy - just to make sample data look good per audition instructions
    # NOTE: only lowercase <s> and not <S> seems bogus, so no //i
    raw = raw.gsub(/<s>.*?<\/s>/m, '')

    raw = raw.gsub(/<url>(.*?)<\/url>/i, '\1')
    raw = raw.gsub(/<url url="(.*?)">(.*?)<\/url>/i, '[\2](\1)')

    # <c> .. </c> (code, presumably)
    raw = raw.gsub(/<c>(.*?)<\/c>/mi, '```\1```')

    # [u] .. [/u] (need to use a placeholder since there's no underlining in .md and thus in HtmlToMarkdown)
    raw = raw.gsub(/<u>(.*?)<\/u>/) do
      bbcode = "[u]#{$1}[/u]"
      @placeholders.store(bbcode)
    end

    # [youtube].. [/youtube]
    raw = raw.gsub(/\[youtube\](.*?)\[\/youtube\]/, 'https://www.youtube.com/watch?v=\1')

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

    raw
  end

  def strip_html(raw)
    raw = raw.gsub(/<r>(.*)<\/r>/m, '\1') #remove outside <r> tags
    raw = raw.gsub(/<t>(.*)<\/t>/m, '\1') #remove outside <t> tags

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
end

ImportScripts::FLARUM.new.perform

