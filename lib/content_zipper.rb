#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#
require 'zip/zip'
require 'action_controller'
require 'action_controller/test_process.rb'
require 'tmpdir'
require 'set'

class ContentZipper

  def initialize
    @logger = Rails.logger
  end
  
  def self.send_later_if_production(*args)
    if ENV['RAILS_ENV'] == 'production'
      send_later(*args)
    else
      send(*args)
    end
  end
  
  def send_later_if_production(*args)
    if ENV['RAILS_ENV'] == 'production'
      send_later(*args)
    else
      send(*args)
    end
  end

  # we evaluate some ERB templates from under app/views/ while generating assignment zips
  include I18nUtilities
  def t(*a, &b)
    I18n.t(*a, &b)
  end

  def self.process_attachment(*args)
    ContentZipper.new.process_attachment(*args)
  end
  
  def process_attachment(attachment, user = nil)
    raise "No attachment provided to ContentZipper.process_attachment" unless attachment
    
    attachment.update_attribute(:workflow_state, 'zipping')
    @user = user
    @logger.debug("file found: #{attachment.id} zipping files...")
    
    begin
      case attachment.context
      when Assignment; zip_assignment(attachment, attachment.context)
      when Eportfolio; zip_eportfolio(attachment, attachment.context)
      when Folder; zip_base_folder(attachment, attachment.context)
      end
    rescue => e
      ErrorReport.log_exception(:default, e, {
        :message => "Content zipping failed",
      })
      @logger.debug(e.to_s)
      @logger.debug(e.backtrace.join('\n'))
      attachment.update_attribute(:workflow_state, 'to_be_zipped')
    end
  end
  
  def zip_assignment(zip_attachment, assignment)
    files = []
    @logger.debug("zipping into attachment: #{zip_attachment.id}")
    zip_attachment.workflow_state = 'zipping'
    zip_attachment.scribd_attempts += 1
    zip_attachment.save!
    filename = "#{assignment.context.short_name}-#{assignment.title} submissions".gsub(/ /, "_").gsub(/[^\w-]/, "")
    make_zip_tmpdir(filename) do |zip_name|
      @logger.debug("creating #{zip_name}")
      submissions_added = 0
      Zip::ZipFile.open(zip_name, Zip::ZipFile::CREATE) do |zipfile|
        count = assignment.submissions.count
        assignment.submissions.each_with_index do |submission, idx|
          submissions_added += 1
          @assignment = assignment
          @submission = submission
          @context = assignment.context
          @logger.debug(" checking submission for #{(submission.user.name rescue nil)}")
          filename = submission.user.last_name_first + (submission.late? ? " LATE " : " ") + submission.user_id.to_s
          filename = filename.gsub(/ /, "_").gsub(/[^\w]/, "").downcase
          content = nil
          if submission.submission_type == "online_upload"
            submission.attachments.each do |attachment|
              @logger.debug("  found attachment: #{attachment.display_name}")
              fn = filename + "_" + attachment.id.to_s + "_" + attachment.display_name
              if add_attachment_to_zip(attachment, zipfile, fn)
                files << fn
              end
            end
          elsif submission.submission_type == "online_url" && submission.url
            @logger.debug("  found url: #{submission.url}")
            self.extend(ApplicationHelper)
            filename += "_link.html"
            @logger.debug("  loading template")
            content = File.open(File.join("app", "views", "assignments", "redirect_page.html.erb")).read
            @logger.debug("  parsing template")
            content = ERB.new(content).result(binding)
            @logger.debug("  done parsing template")
            if content
              zipfile.get_output_stream(filename) {|f| f.puts content }
              files << filename
            end
          elsif submission.submission_type == "online_text_entry" && submission.body
            @logger.debug("  found text entry")
            self.extend(ApplicationHelper)
            filename += "_text.html"
            content = File.open(File.join("app", "views", "assignments", "text_entry_page.html.erb")).read
            content = ERB.new(content).result(binding)
            if content
              zipfile.get_output_stream(filename) {|f| f.puts content }
              files << filename
            end
          end
          zip_attachment.workflow_state = 'zipping'
          zip_attachment.file_state = ((idx + 1).to_f / count.to_f * 100).to_i
          zip_attachment.save!
          @logger.debug("status for #{zip_attachment.id} updated to #{zip_attachment.file_state}")
        end
      end
      @logger.debug("added #{submissions_added} submissions")
      assignment.increment!(:submissions_downloads)
      if files.empty?
        zip_attachment.workflow_state = 'errored'
        zip_attachment.save!
      else
        @logger.debug("data zipped! uploading to s3...")
        uploaded_data = ActionController::TestUploadedFile.new(zip_name, 'application/zip')
        zip_attachment.uploaded_data = uploaded_data
        zip_attachment.workflow_state = 'zipped'
        zip_attachment.file_state = 'available'
        zip_attachment.save!
      end
    end
  end
  
  def self.zip_eportfolio(*args)
    ContentZipper.new.zip_eportfolio(*args)
  end
  
  def zip_eportfolio(zip_attachment, portfolio)
    static_attachments = []
    submissions = []
    portfolio.eportfolio_entries.each do |entry|
      static_attachments += entry.attachments
      submissions += entry.submissions
    end
    idx = 1
    submissions_hash = {}
    submissions.each do |s|
      submissions_hash[s.id] = s
      if s.submission_type == 'online_upload'
        static_attachments += s.attachments
      else
      end
    end
    static_attachments = static_attachments.uniq.map do |a|
      obj = OpenObject.new
      obj.display_name = a.display_name
      obj.filename = "#{idx}_#{a.filename}"
      obj.content_type = a.content_type
      obj.uuid = a.uuid
      obj.attachment = a
      idx += 1
      obj
    end
    filename = "#{portfolio.name.gsub(/\s/, "_")}"
    make_zip_tmpdir(filename) do |zip_name|
      idx = 0
      count = static_attachments.length + 2
      Zip::ZipFile.open(zip_name, Zip::ZipFile::CREATE) do |zipfile|
        zip_attachment.file_state = ((idx + 1).to_f / count.to_f * 100).to_i
        zip_attachment.save!
        portfolio.eportfolio_entries.each do |entry|
          filename = "#{entry.full_slug}.html"
          content = render_eportfolio_page_content(entry, portfolio, static_attachments, submissions_hash)
          zipfile.get_output_stream(filename) {|f| f.puts content }
        end
        zip_attachment.file_state = ((idx + 1).to_f / count.to_f * 100).to_i
        zip_attachment.save!
        static_attachments.each do |a|
          add_attachment_to_zip(a.attachment, zipfile)
          zip_attachment.file_state = ((idx + 1).to_f / count.to_f * 100).to_i
          zip_attachment.save!
        end
        if css = File.open(File.join(RAILS_ROOT, 'public', 'stylesheets', 'static', 'eportfolio_static.css')) rescue nil
          content = css.read
          zipfile.get_output_stream("eportfolio.css") {|f| f.puts content } if content
        end
        content = File.open(File.join(RAILS_ROOT, 'public', 'images', 'logo.png'), 'rb').read rescue nil
        zipfile.get_output_stream("logo.png") {|f| f.write content } if content
      end
      @logger.debug("data zipped!")
      uploaded_data = ActionController::TestUploadedFile.new(zip_name, 'application/zip')
      zip_attachment.uploaded_data = uploaded_data
      zip_attachment.workflow_state = 'zipped'
      zip_attachment.file_state = 'available'
      zip_attachment.save!
    end
  end

  def render_eportfolio_page_content(page, portfolio, static_attachments, submissions_hash)
    @page = page
    @portfolio = @portfolio
    @static_attachments = static_attachments
    @submissions_hash = submissions_hash
    av = ActionView::Base.new(Rails::Configuration.new.view_path)
    av.extend TextHelper
    res = av.render(:partial => "eportfolios/static_page", :locals => {:page => page, :portfolio => portfolio, :static_attachments => static_attachments, :submissions_hash => submissions_hash})
    res
  end
  
  def self.zip_base_folder(*args)
    ContentZipper.new.zip_base_folder(*args)
  end
  
  def zip_base_folder(zip_attachment, folder)
    @files_added = true
    @logger.debug("zipping into attachment: #{zip_attachment.id}")
    zip_attachment.workflow_state = 'zipping' #!(:workflow_state => 'zipping')
    zip_attachment.scribd_attempts += 1
    zip_attachment.save!
    filename = "#{folder.context.short_name}-#{folder.name} files".gsub(/ /, "_").gsub(/[^\w-]/, "")
    make_zip_tmpdir(filename) do |zip_name|
      @logger.debug("creating #{zip_name}")
      Zip::ZipFile.open(zip_name, Zip::ZipFile::CREATE) do |zipfile|
        @logger.debug("zip_name: #{zip_name}")
        process_folder(folder, zipfile)
      end
      if @files_added
        @logger.debug("data zipped!")
        uploaded_data = ActionController::TestUploadedFile.new(zip_name, 'application/zip')
        zip_attachment.uploaded_data = uploaded_data
        zip_attachment.workflow_state = 'zipped'
        zip_attachment.file_state = 'available'
        zip_attachment.save!
      else
        zip_attachment.workflow_state = 'errored'
        zip_attachment.save!
      end
    end
  end
  
  def process_folder(folder, zipfile, start_dirs=[], &callback)
    if callback
      zip_folder(folder, zipfile, start_dirs, &callback)
    else
      zip_folder(folder, zipfile, start_dirs)
    end
  end
  
  protected

  # make a tmp directory and yield a filename under that directory to the block
  # given. the tmp directory is deleted when the block returns.
  def make_zip_tmpdir(filename)
    Dir.mktmpdir do |dirname|
      zip_name = File.join(dirname, "#{filename}.zip")
      yield zip_name
    end
  end
  
  # The callback should accept two arguments, the attachment/folder and the folder names
  def zip_folder(folder, zipfile, folder_names, &callback)
    if callback && (folder.hidden? || folder.locked)
      callback.call(folder, folder_names)
    end
    attachments = if !@user || folder.context.grants_right?(@user, nil, :manage_files)
                folder.active_file_attachments
              else
                folder.visible_file_attachments
              end
    attachments.select{|a| !@user || a.grants_right?(@user, nil, :download)}.each do |attachment|
      callback.call(attachment, folder_names) if callback
      @context = folder.context
      @logger.debug("  found attachment: #{attachment.unencoded_filename}")
      path = folder_names.empty? ? attachment.filename : File.join(folder_names, attachment.unencoded_filename)
      @files_added = false unless add_attachment_to_zip(attachment, zipfile, path)
    end
    folder.active_sub_folders.select{|f| !@user || f.grants_right?(@user, nil, :read_contents)}.each do |sub_folder|
      new_names = Array.new(folder_names) << sub_folder.name
      if callback
        zip_folder(sub_folder, zipfile, new_names, &callback)
      else
        zip_folder(sub_folder, zipfile, new_names)
      end
    end
  end
  
  def add_attachment_to_zip(attachment, zipfile, filename = nil)
    filename ||= attachment.filename

    # we allow duplicate filenames in the same folder. it's a bit silly, but we
    # have to handle it here or people might not get all their files zipped up.
    @files_in_zip ||= Set.new
    filename = Attachment.make_unique_filename(filename, @files_in_zip)
    @files_in_zip << filename
    
    handle = nil
    begin
      handle = attachment.open(:need_local_file => true)
      zipfile.get_output_stream(filename){|zos| IOExtras.copy_stream(zos, handle)}
    rescue => e
      @logger.error("  skipping #{attachment.full_filename} with error: #{e.message}")
      return false
    ensure
      handle.close if handle
    end
    
    true
  end
end
