# frozen_string_literal: true

require "csv"
require File.expand_path(File.dirname(__FILE__) + "/base.rb")

# Edit the constants and initialize method for your import data.
# Make sure to follow the right format in your CSV files.

class ImportScripts::CsvImporter < ImportScripts::Base

  CSV_USERS = ENV['CSV_USER_FILE'] || '/Users/constanza/Work/migrations/landtrust/csv/users_landtrust.csv'
  IMPORT_CUSTOM_FIELDS = ENV['CSV_USER_FILE'] || false
  CSV_CUSTOM_FIELDS = ENV['CSV_CUSTOM_FIELDS'] || '/var/www/discourse/tmp/custom_fields.csv'
  CSV_EMAILS = ENV['CSV_EMAILS'] || '/Users/constanza/Work/migrations/landtrust/csv/emails_landtrust.csv'
  CSV_CATEGORIES = ENV['CSV_CATEGORIES'] || '/Users/constanza/Work/migrations/landtrust/csv/categories_landtrust.csv'
  CSV_TOPICS = ENV['CSV_TOPICS'] || '/var/www/discourse/tmp/topics_new_users.csv'
  CSV_TOPICS_EXISTING_USERS = ENV['CSV_TOPICS'] || '/var/www/discourse/tmp/topics_existing_users.csv'
  CSV_SSO = ENV['CSV_SSO'] || '/Users/constanza/Work/migrations/landtrust/csv/sso_records_landtrust.csv'
  IMPORT_PREFIX = ENV['IMPORT_PREFIX'] || '2022-08-11'
  IMPORT_USER_ID_PREFIX = 'csv-user-import-' + IMPORT_PREFIX + '-'
  IMPORT_CATEGORY_ID_PREFIX = 'csv-category-import-' + IMPORT_PREFIX + '-'
  IMPORT_TOPIC_ID_PREFIX = 'csv-topic-import-' + IMPORT_PREFIX + '-'
  IMPORT_TOPIC_ID_EXISITNG_PREFIX = 'csv-topic_existing-import-' + IMPORT_PREFIX + '-'

  def initialize
    super

    @imported_users = load_csv(CSV_USERS)
    @imported_emails = load_csv(CSV_EMAILS)
    @imported_sso = load_csv(CSV_SSO)
    @imported_custom_fields = load_csv(CSV_CUSTOM_FIELDS) if IMPORT_CUSTOM_FIELDS
    @imported_custom_fields_names = @imported_custom_fields.headers.drop(1) if IMPORT_CUSTOM_FIELDS
    @imported_categories = load_csv(CSV_CATEGORIES)
    @imported_topics = load_csv(CSV_TOPICS)
    @imported_topics_existing_users = load_csv(CSV_TOPICS_EXISTING_USERS)
    @skip_updates = true
  end

  def execute
    puts "", "Importing from CSV file..."
    import_users
    import_sso_records
    import_categories
    # import_topics
    # import_topics_existing_users

    puts "", "Done"
  end

  def load_csv(path)
    unless File.exist?(path)
      puts "File doesn't exist: #{path}"
      return nil
    end

    CSV.parse(File.read(path, encoding: 'bom|utf-8'), headers: true, col_sep: ";")
  end

  def username_for(name)
    result = name.downcase.gsub(/[^a-z0-9\-\_ ]/, '')
    if result.blank?
      result = Digest::SHA1.hexdigest(name)[0...10]
    end

    result
  end

  def get_email(id)
    email = nil
    @imported_emails.each do |e|
      if e["user_id"] == id
        email = e["email"]
      end
    end

    email
  end

  def get_custom_fields(id)
    custom_fields = {}
    @imported_custom_fields.each do |cf|
      if cf["user_id"] == id
        @imported_custom_fields_names.each do |name|
          custom_fields[name] = cf[name]
        end
      end
    end

    custom_fields
  end

  def import_users
    puts '', "Importing users"

    limit = 200

    counter = 0
    users = []
    @imported_users.each do |u|
      if counter == limit
        break
      end
      email = get_email(u['id'])
      custom_fields = IMPORT_CUSTOM_FIELDS ? get_custom_fields(u['id']) : {}
      u['email'] = email
      u['custom_fields'] = custom_fields
      user_id = u['id'].present? ? u['id'] : counter.to_s
      u['id'] = IMPORT_USER_ID_PREFIX + user_id 
      users << u
      counter += 1
    end
    users.uniq!

    create_users(users) do |u|
      {
        id: u['id'],
        username: username_for(u['name']),
        email: u['email'],
        created_at: u['created_at'],
        name: u['name'],
        custom_fields: u['custom_fields'],
      }
    end
  end

  def import_sso_records
    puts '', "Importing sso records"
    limit = 100

    counter = 0

    @imported_sso.each do |s|
      if counter == limit
        break
      end
      user_id = user_id_from_imported_user_id(IMPORT_USER_ID_PREFIX + s['user_id'])
      email = get_email(s['user_id'])
      SingleSignOnRecord.create!(user_id: user_id, external_id: s['external_id'], external_email: email, last_payload: '')
      counter += 1
    end

  end

  def import_categories
    puts '', "Importing categories"

    categories = []
    @imported_categories.each do |c|
      c['user_id'] = UserEmail.where(email: c['email']).pluck(:user_id) || Discourse::SYSTEM_USER_ID
      c['id'] = IMPORT_CATEGORY_ID_PREFIX + c['id']
      categories << c
    end
    categories.uniq!

    create_categories(categories) do |c|
      {
        id: c['id'],
        user_id: c['user_id'],
        name: c['name'],
        description: c['description']
      }
    end
  end

  def import_topics
    puts '', "Importing topics"

    topics = []
    @imported_topics.each do |t|
      if t['type'] == 'Post'
        next
      end
      user_id = UserEmail.where(email: t['email']).pluck(:user_id) || Discourse::SYSTEM_USER_ID
      t['user_id'] = user_id || Discourse::SYSTEM_USER_ID
      t['category_id'] = category_id_from_imported_category_id(IMPORT_CATEGORY_ID_PREFIX + t['category_id'])
      t['id'] = IMPORT_TOPIC_ID_PREFIX + t['id']
      t['topic_id'] = 
      t['reply_to_post_number']
      topics << t
    end

    create_posts(topics) do |t|
      {
        id: t['id'],
        user_id: t['user_id'],
        raw: t['raw'],
        topic_id: t
      }
    end
  end

  def import_topics_existing_users
    # Import topics for users that already existed in the DB, not imported during this migration
    puts '', "Importing topics for existing users"

    topics = []
    @imported_topics_existing_users.each do |t|
      t['id'] = IMPORT_TOPIC_ID_EXISITNG_PREFIX + t['id']
      topics << t
    end

    create_posts(topics) do |t|
      {
        id: t['id'],
        user_id: t['user_id'], # This is a Discourse user ID
        title: t['title'],
        category: t['category_id'], # This is a Discourse category ID
        raw: t['raw']
      }
    end
  end
end

def import_posts
  # Work In Progress

  puts '', "Importing posts"

  topics = []
  @imported_topics.each do |t|
    if t['type'] == 'Discussion'
      next
    end
    t['user_id'] = user_id_from_imported_user_id(IMPORT_USER_ID_PREFIX + t['user_id']) || Discourse::SYSTEM_USER_ID
    t['category_id'] = category_id_from_imported_category_id(IMPORT_CATEGORY_ID_PREFIX + t['category_id'])
    t['id'] = IMPORT_TOPIC_ID_PREFIX + t['id']
    topics << t
  end

  create_posts(topics) do |t|
    {
      id: t['id'],
      user_id: t['user_id'],
      title: t['title'],
      category: t['category_id'],
      raw: t['raw']
    }
  end
end

if __FILE__ == $0
  ImportScripts::CsvImporter.new.perform
end

# == CSV files format
#
# + File name: users
#
#  headers: id,username
#
# + File name: emails
#
#  headers: user_id,email
#
# + File name: custom_fields
#
#  headers: user_id,user_field_1,user_field_2,user_field_3,user_field_4
#
#  note: the "user_field_1","user_field_2", .. headers are the names of the
#        custom fields, as defined in Discourse's user_custom_fields table.
#
# + File name: categories
#
#  headers: id,user_id,name,description
#
# + File name: topics_new_users
#
#  headers: id,user_id,title,category_id,raw
#
# + File name: topics_existing_users
#
#  headers: id,user_id,title,category_id,raw
#
# == Important: except for the topics_existing_users, the IDs in the data can be anything
#            as long as they are consistent among the files.
#
