# James - 2008-09-12

# Rake tasks to repair Kete data to ensure integrity

namespace :kete do
  namespace :repair do

    # Run all tasks
    task :all => ['kete:repair:fix_topic_versions',
                  'kete:repair:set_missing_contributors',
                  'kete:repair:correct_thumbnail_privacies',
                  'kete:repair:correct_site_basket_roles',
                  'kete:repair:extended_fields']

    desc "Fix invalid topic versions (adds version column value or prunes on a case-by-case basis."
    task :fix_topic_versions => :environment do

      # This task repairs all Topic::Versions where #version is nil. This is a problem because it causes
      # exceptions when visiting history pages on items.

      pruned, fixed = 0, 0

      # First, find all the candidate versions
      Topic::Version.find(:all, :conditions => ['version IS NULL'], :order => 'id ASC').each do |topic_version|

        topic = topic_version.topic

        # Skip any problem topics
        next unless topic.version > 0

        # Find all existing versions
        existing_versions = topic.versions.map { |v| v.version }.compact

        # Find the maximum version
        max = [topic.version, existing_versions.max].compact.max

        # Find any versions that are missing from the range of versions we expect to find,
        # given the maximum version we found above..
        missing = (1..max).detect { |v| !existing_versions.member?(v) }

        if missing

          # The current topic_version has no version attribute, and there is a version missing from the set.
          # Therefore, the current version is likely the missing one.

          # Set the version on this topic_version to the missing one..

          topic_version.update_attributes!(
            :version => missing,
            :version_comment => topic_version.version_comment.to_s + " NOTE: Version number fixed automatically."
          )

          print "Fixed missing version for Topic with id = #{topic_version.topic_id} (version #{missing}).\n"
          fixed = fixed + 1

        elsif topic.versions.size > max

          # There are more versions than we expected, and there are no missing version records.
          # So, this version must be additional to requirements. We need to remove the current topic_version.

          # Clean up any flags/tags
          topic_version.flags.clear
          topic_version.tags.clear

          # Check the associations have been cleared
          topic_version.reload

          raise "Could not clear associations" if \
            topic_version.flags.size > 0 || topic_version.tags.size > 0

          # Prune if we're still here..
          topic_version.destroy

          print "Deleted invalid version for Topic with id = #{topic_version.topic_id}.\n"
          pruned = pruned + 1

        end

      end

      print "Finished. Removed #{pruned} invalid topic versions.\n"
      print "Finished. Fixed #{fixed} topic versions with missing version attributes.\n"
    end

    desc "Set missing contributors on topic versions."
    task :set_missing_contributors => :environment do
      fixed = 0

      # This rake task runs through all topic_versions and adds a contributor/creator to any
      # which are missing them.

      # This is done because a missing contributor results in exceptions being raised on the
      # topic history pages.

      Topic::Version.find(:all).each do |topic_version|

        # Check that this is a valid topic version.
        next if topic_version.version.nil?

        # Identify any existing contributors for the current topic_version and skip to the next
        # if existing contributors are present.

        sql = <<-SQL
          SELECT COUNT(*) FROM contributions
            WHERE contributed_item_type = "Topic"
            AND contributed_item_id = #{topic_version.topic.id}
            AND version = #{topic_version.version};
        SQL

        next unless Contribution.count_by_sql(sql) == 0

        # Add the admin user as the contributor and add a note to the version comment.

        Contribution.create(
          :contributed_item => topic_version.topic,
          :version => topic_version.version,
          :contributor_role => topic_version.version == 1 ? "creator" : "contributor",
          :user_id => 1
        )

        topic_version.update_attribute(:version_comment, topic_version.version_comment.to_s + " NOTE: Contributor added automatically. Actual contributor unknown.")

        print "Added contributor for version #{topic_version.version} of Topic with id = #{topic_version.topic.id}.\n"
        fixed = fixed + 1
      end

      print "Finished. Added contributor to #{fixed} topic versions.\n"
    end

    desc "Copies incorrectly located uploads to the correct location"
    task :correct_upload_locations => :environment do

      # Display a warning to the user, since we're copying files around on the file system
      # and there is a possibility of overwriting something important.

      puts "\n/!\\ IMPORTANT /!\\\n\n"
      puts "This task will copy files from audio_recordings/ into audio/, and videos/ into video/, "
      puts "where they should be stored.\n\n"

      puts "You should only run this once, to avoid overwriting files.\n\n"

      puts "Please ensure you have backed up your application directory before continuing. If you "
      puts "have not done this, press Ctrl+C now to abort. Otherwise, press any key to continue.\n\n"

      puts "Press any key to continue, or Ctrl+C to abort.."
      STDIN.gets
      puts "Running.. please wait.."

      # A list of folders to copy files between

      copy_directives = {
        'audio_recordings' => 'audio',
        'videos' => 'video'
      }

      # Do this in the context of both public and private files

      ['public', 'private'].each do |privacy_folder|
        copy_directives.each_pair do |src, dest|
          from  = File.join(RAILS_ROOT, privacy_folder, src, ".")
          to    = File.join(RAILS_ROOT, privacy_folder, dest)

          # Skip if the wrongly named folder doesn't exist
          next unless File.exists?(from)

          # Make the destination folder if it does not exist
          # Also detects symlinks, so should be Capistrano safe.
          FileUtils.mkdir(to) unless File.exists?(to)

          # Copy and report what's going on
          print "Copying #{from.gsub(RAILS_ROOT, "")} to #{to.gsub(RAILS_ROOT, "")}.."
          FileUtils.cp_r(from, to)
          print " Done.\n"
        end
      end

      Rake::Task['kete:repair:check_uploaded_files'].invoke
    end

    desc "Check uploaded files for accessibility"
    task :check_uploaded_files => :environment do

      puts "Checking files.. please wait.\n\n"

      inaccessible_files = [AudioRecording, Document, ImageFile, Video].collect do |item_type|
        item_type.find(:all).collect do |instance|
          instance unless File.exists?(instance.full_filename)
        end
      end.flatten.compact

      if inaccessible_files.empty?
        puts "All files could be found. No further action required."
      else
        puts "WARNING: Some files could not be found. See below for details:\n\n"
        inaccessible_files.each do |instance|
          puts "- Missing uploaded file for #{instance.class.name} with ID #{instance.id.to_s}."
        end
        puts "\nRun rake kete:repair:correct_upload_locations to relocate files to the correct "
        puts "location.\n\n"

        puts "If you have used Capistrano to deploy your Kete instance, you may also need to copy"
        puts "archived files from previous versions of your Kete application, which are saved "
        puts "under 'releases' in your main application folder."
        puts "See http://kete.net.nz/documentation/topics/show/207 for complete instructions."
      end
    end

    desc "Makes sure thumbnails are stored in the correct privacy for their still image"
    task :correct_thumbnail_privacies => :environment do
      puts "Getting all private StillImages and their public ImageFiles\n"
      StillImage.all.each do |still_image|
        any_incorrect_thumbnails = false
        if still_image.has_public_version?
          still_image.resized_image_files.find_all_by_file_private(true).each do |image_file|
            any_incorrect_thumbnails = true
            move_image_from_to(image_file, false)
          end
        else
          still_image.resized_image_files.find_all_by_file_private(false).each do |image_file|
            any_incorrect_thumbnails = true
            move_image_from_to(image_file, true)
          end
        end
        puts "Moving thumnails for still image #{still_image.id} to the correct directory." if any_incorrect_thumbnails
      end
    end

    def move_image_from_to(image_file, to_be_private)
      file_path = image_file.public_filename
      if to_be_private
        from = File.join(RAILS_ROOT, 'public', file_path)
        to = File.join(RAILS_ROOT, 'private', file_path)
      else
        from = File.join(RAILS_ROOT, 'private', file_path)
        to = File.join(RAILS_ROOT, 'public', file_path)
      end
      puts "Moving #{from.gsub(RAILS_ROOT, "")} to #{to.gsub(RAILS_ROOT, "")}"
      FileUtils.mv(from, to, :force => true)
      image_file.force_privacy = true
      image_file.file_private = to_be_private
      image_file.save!
    end

    desc "Correct site basket role creation dates for legacy databases"
    task :correct_site_basket_roles => :environment do
      site_basket = Basket.site_basket
      member_role = Role.find_by_name_and_authorizable_type_and_authorizable_id('member', 'Basket', site_basket)
      if member_role # skip this task incase there is no member role in site basket
        puts "Syncing basket role creation dates with user creation dates"
        user_roles = member_role.user_roles.all(:include => :user)
        user_roles.each do |role|
          next if role.created_at == role.user.created_at
          UserRole.update_all({:created_at => role.user.created_at}, {:user_id => role.user, :role_id => member_role})
          puts "Updated role creation date for #{role.user.user_name}"
        end
        puts "Synced basket role creation dates"
      end
    end

    desc "Run all extended field repair tasks"
    task :extended_fields => ['kete:repair:extended_fields:legacy_google_map']

    namespace :extended_fields do

      desc "Run the legacy google map repair tasks"
      task :legacy_google_map => :environment do
        map_types = ['map', 'map_address']
        map_fields = ExtendedField.all(:conditions => ["ftype IN (?)", map_types]).collect { |f| f.label_for_params }
        if map_fields.size > 0
          @gma_config_path = File.join(RAILS_ROOT, 'config/google_map_api.yml')
          raise "Error: Trying to use Google Maps without configuation (config/google_map_api.yml)" unless File.exists?(@gma_config_path)
          gma_config = YAML.load(IO.read(@gma_config_path))

          map_sql = map_fields.collect { |f| "extended_content LIKE '%<#{f}%'" }.join(' OR ')
          each_item_with_extended_fields("(#{map_sql})") do |item|
            original_extended_content = item.extended_content.dup
            map_fields.each do |field|
              begin
                map_data = item.send(field) # replace this with .try() in Rails 2.3
              rescue
                next
              end
              value = { 'zoom_lvl' => (map_data['zoom_lvl'] || gma_config[:google_map_api][:default_zoom_lvl].to_s),
                        'no_map' => (map_data['no_map'] || '0'), 'coords' => map_data['coords'] }
              value['address'] = map_data['address'] if map_data['address']
              item.send("#{field}=", value)
            end
            if item.extended_content != original_extended_content
              # make sure we set 'do_not_sanitize' to true or update_attribute will strip some HTML
              item.do_not_sanitize = true
              item.update_attribute(:extended_content, item.extended_content)
            end
          end
        end
      end

      private

      def each_item_with_extended_fields(conditions = nil, &block)
        conditions = "extended_content IS NOT NULL AND extended_content != '' AND #{(conditions || '1=1')}"
        ZOOM_CLASSES.each do |zoom_class|
          zoom_class.constantize.all(:conditions => conditions).each do |item|
            yield(item)
          end
        end
      end

    end

    desc 'Resize original images based on current IMAGE_SIZES and add new ones if needed. Does not remove no longer needed ones (to prevent links breaking).'
    task :resize_images => :environment do
      @logger = Logger.new(RAILS_ROOT + "/log/resize_images_#{Time.now.strftime('%Y-%m-%d_%H:%M:%S')}.log")

      puts "Resizing/created images based on IMAGE_SIZES..."
      @logger.info "Starting image file resizing."

      # get a list of thumbnail keys
      image_size_keys = IMAGE_SIZES.keys

      # setup some variables for reporting once the task is done
      resized_images_count = 0
      created_images_count = 0

      @logger.info "Looping through parent items"

      # loop over every parent image file
      ImageFile.all(:conditions => ["parent_id IS NULL"]).each do |parent_image_file|

        @logger.info "  Fetched parent image #{parent_image_file.id}"

        # start an array with all thumbnail keys and remove ones as we go through
        missing_image_size_keys = image_size_keys.dup

        # loop over the parent images files children thumbnails
        ImageFile.all(:conditions => ["parent_id = ?", parent_image_file]).each do |child_image_file|

          @logger.info "    Fetched child image #{child_image_file.id}"

          # remove this image files thumbnail key from the missing image size keys array
          # (so we eventually end up with an array of keys that aren't being used)
          missing_image_size_keys = missing_image_size_keys - [child_image_file.thumbnail.to_sym]

          # if this image doesn't need to be changed, skip it
          if image_file_match_image_size?(child_image_file)
            @logger.info "      Child image #{child_image_file.id} does not need resizing"
            next
          end

          # recreate an existing image to new sizes based on the parent (original) file
          resize_image_from_original(child_image_file, parent_image_file.full_filename)

          # increase the amount of resized images
          @logger.info "      Incrementing resizes images count"
          resized_images_count += 1

        end

        # loop over and keys we still have remaining
        @logger.info "    Image sizes keys not yet used: #{missing_image_size_keys.collect { |s| s.to_s }.join(',')}"
        missing_image_size_keys.each do |size|

          @logger.info "    Creating image for thumbnail size #{size}"

          # get the parent filename and attach the size to it for the new filename
          filename = parent_image_file.filename.gsub('.', "_#{size.to_s}.")

          # create a new image file based on the parent (details will be updated later)
          image_file = ImageFile.create!(
            parent_image_file.attributes.merge(
              :id => nil,
              :parent_id => parent_image_file.id,
              :thumbnail => size.to_s,
              :filename => filename
            )
          )
          @logger.info "      Created new image record for #{filename}, id #{image_file.id}"

          # recreate an existing image to new sizes based on the parent (original) file
          resize_image_from_original(image_file, parent_image_file.full_filename)

          # increase the amount of created images
          @logger.info "      Incrementing created images count"
          created_images_count += 1

        end

      end

      # Let the user know how many were resized and how many were created
      puts "Finished. #{resized_images_count} images resized, #{created_images_count} images created."
      @logger.info "Finished image resizing. #{resized_images_count} images resized, #{created_images_count} images created."
    end

    private

    # Checks whether an image file thumbnail size matches any of the IMAGE_SIZES values
    def image_file_match_image_size?(image_file)
      # get what the imags sizes should be
      size_string = IMAGE_SIZES[image_file.thumbnail.to_sym]

      # in the case that IMAGE_SIZES no longer has the sizes for existing image, skip it
      # TODO: in the future, we want to allow users to specify if image files and db
      # record should be deleted
      return true if size_string.blank?

      # if we have a ! in the size, then both height and width have to match (else only one needs to)
      absolute = size_string.include?('!')

      # if we have a x in the size, then we have both height and width to match (else we have only width)
      sizes = size_string.split('x').collect { |s| s.to_i }

      # do we have width and height?
      if sizes.size > 1
        # do we need to match both width and height?
        if absolute
          # check if the current width and height are what they should be
          sizes[0] == image_file.width &&
            sizes[1] == image_file.height
        else
          # check if the current width or height are what they should be
          sizes[0] == image_file.width ||
            sizes[1] == image_file.height
        end
      else
        # check if the current width is what it should be
        sizes[0] == image_file.width
      end
    end

    # takes an image file and resizes it based on the original file
    # uses attachment_fu method on the ImageFile class and image_file instance
    def resize_image_from_original(image_file, original_file)
      @logger.info "      Resizing child image #{image_file.id} based on #{original_file}"
      ImageFile.with_image original_file do |img|
        image_file.resize_image(img, IMAGE_SIZES[image_file.thumbnail.to_sym])
        image_file.send :destroy_file, image_file.full_filename
        image_file.send :save_to_storage, image_file.full_filename
        # make sure we update the image file size, width, and height based on the new resized image
        image_file.update_attributes!(
          :size => File.size(image_file.full_filename),
          :width => img.columns,
          :height => img.rows
        )
        @logger.info "      Child image record updated"
      end
    end

  end
end
