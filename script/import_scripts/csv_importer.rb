# frozen_string_literal: true

require "csv"
require File.expand_path(File.dirname(__FILE__) + "/base.rb")

# Edit the constants and initialize method for your import data.
# Make sure to follow the right format in your CSV files.

class ImportScripts::CsvImporter < ImportScripts::Base

  CSV_USERS                 = ENV['CSV_USER_FILE']     || '/shared/tmp/coco/users_landtrust.csv'
  CSV_EMAILS                = ENV['CSV_EMAILS']        || '/shared/tmp/coco/emails_landtrust.csv'
  CSV_CATEGORIES            = ENV['CSV_CATEGORIES']    || '/shared/tmp/coco/categories_landtrust.csv'
  CSV_TOPICS                = ENV['CSV_TOPICS']        || '/shared/tmp/coco/posts_landtrust.csv'
  #CSV_TOPICS_EXISTING_USERS = ENV['CSV_TOPICS']        || '/shared/tmp/coco/topics_existing_users.csv'
  CSV_SSO                   = ENV['CSV_SSO']           || '/shared/tmp/coco/sso_records_landtrust.csv'

  IMPORT_PREFIX                   = ENV['IMPORT_PREFIX'] || '2022-08-11'
  IMPORT_USER_ID_PREFIX           = 'csv-user-import-' + IMPORT_PREFIX + '-'
  IMPORT_CATEGORY_ID_PREFIX       = 'csv-category-import-' + IMPORT_PREFIX + '-'
  IMPORT_TOPIC_ID_PREFIX          = 'csv-topic-import-' + IMPORT_PREFIX + '-'
  IMPORT_TOPIC_ID_EXISITNG_PREFIX = 'csv-topic_existing-import-' + IMPORT_PREFIX + '-'

  CSV_CUSTOM_FIELDS         = ENV['CSV_CUSTOM_FIELDS'] || '/shared/tmp/coco/custom_fields.csv'
  IMPORT_CUSTOM_FIELDS      = !! ENV['CSV_USER_FILE']

  def initialize
    super

    @imported_users = load_csv(CSV_USERS)
    @imported_emails = load_csv(CSV_EMAILS)
    @imported_sso = load_csv(CSV_SSO)
    @imported_custom_fields = load_csv(CSV_CUSTOM_FIELDS) if IMPORT_CUSTOM_FIELDS
    @imported_custom_fields_names = @imported_custom_fields.headers.drop(1) if IMPORT_CUSTOM_FIELDS
    @imported_categories = load_csv(CSV_CATEGORIES)
    @imported_topics = load_csv(CSV_TOPICS)
    #@imported_topics_existing_users = load_csv(CSV_TOPICS_EXISTING_USERS)
    @skip_updates = true

    @anonymized_user_id = User.create!(
      name: 'Anonymous User',
      username: 'anonymous',
      email: 'anonymous@invalid.email',
    ).id

    @email_by_user_id = Hash[ * @imported_emails.map{ |e| [ e['user_id'], e['email'] ] }.flatten ]
  end

  def user_id_for(original_user_id, fallback: nil)
    user_id = user_id_from_imported_user_id(IMPORT_USER_ID_PREFIX + original_user_id.to_s)
    user_id || fallback
  end

  def user_id_by_email(email, fallback: nil)
    user_id = UserEmail.where(email: email).first&.user_id
    user_id || fallback
  end

  def execute
    puts "", "Importing from CSV file..."
    import_users
    import_sso_records
    import_categories
    import_topics
    #import_topics_existing_users
    import_posts

    puts "", "Done"
  end

  def load_csv(path)
    unless File.exist?(path)
      puts "File doesn't exist: #{path}"
      return nil
    end

    CSV.parse(File.read(path, encoding: 'bom|utf-8'), headers: true)
  end

  def username_for(name)
    result = name.downcase.gsub(/[^a-z0-9\-\_ ]/, '')
    if result.blank?
      result = Digest::SHA1.hexdigest(name)[0...10]
    end

    result
  end

  def get_email(id)
    @email_by_user_id[id]
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

    counter = 0
    users = []
    @imported_users.each do |u|
      #custom_fields = IMPORT_CUSTOM_FIELDS ? get_custom_fields(u['id']) : {}
      u['email'] = get_email(u['id'])
      #u['custom_fields'] = custom_fields
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
        #custom_fields: u['custom_fields'],
      }
    end
  end

  def import_sso_records
    puts '', "Importing sso records"

    @imported_sso.each do |s|

      user_id = s['user_id']
      external_id = s['external_id']

      if user_id = user_id_for(user_id)
        email = get_email(user_id)

        UserAssociatedAccount.create!(
          provider_name: "oidc",
          provider_uid: external_id,

          user_id: user_id,
          info: { 'email' => email, 'email_verified' => true },
        )
      else
        STDERR.puts "ERROR: imported user_id not found for SSO record with external_id #{external_id}"
      end

      print '.'

    end

  end

  def import_categories
    puts '', "Importing categories"

    categories = []
    @imported_categories.each do |c|
      c['user_id'] = user_id_by_email(c['email'], fallback: Discourse::SYSTEM_USER_ID)
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

  def post_from_source(source, is_first_post: false)
    s = source

    topic_id =
      if ! is_first_post
        posted_in = s['PostedIn']
        record = topic_lookup_from_imported_post_id(IMPORT_TOPIC_ID_PREFIX + posted_in)

        if record
          record[:topic_id]
        else
          STDERR.puts "ERROR: imported topic_id not found for post #{posted_in}"

          # signal to avoid creating the record, otherwise this reply would be created as a topic instead
          return nil
        end
      end

    {
      id: IMPORT_TOPIC_ID_PREFIX + s['id'],
      user_id: user_id_by_email(s['email'], fallback: @anonymized_user_id),
      category_id: category_id_from_imported_category_id(IMPORT_CATEGORY_ID_PREFIX + s['category_id']),
      title: s['title'] || 'ZZZ no title',
      raw: s['raw'],
      created_at: Time.parse(s['PostedOn']),
      topic_id: topic_id,
    }
  end

  def import_topics
    puts '', "Importing topics"

    first_posts = @imported_topics.
      select { |t| t['type'] == 'Discussion' }.
      map    { |t| post_from_source(t, is_first_post: true) }.
      compact


    create_posts(first_posts) { |p| p }
  end

  def import_posts
    puts '', "Importing posts"

    posts = @imported_topics.
      select { |t| t['type'] == 'Post' }.
      map    { |t| post_from_source(t, is_first_post: false) }.
      compact

    create_posts(posts) { |p| p }
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
