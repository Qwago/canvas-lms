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

require File.expand_path(File.dirname(__FILE__) + '/../spec_helper.rb')

describe ConversationMessage do
  context "notifications" do
    before(:each) do
      Notification.create(:name => "Conversation Message", :category => "TestImmediately")
      Notification.create(:name => "Added To Conversation", :category => "TestImmediately")

      course_with_teacher(:active_all => true)
      @students = []
      3.times{ @students << student_in_course(:active_all => true).user }
      @first_student = @students.first
      @initial_students = @students.first(2)
      @last_student = @students.last

      [@teacher, *@students].each do |user|
        channel = user.communication_channels.create(:path => "test_channel_email_#{user.id}", :path_type => "email")
        channel.confirm
      end

      @conversation = @teacher.initiate_conversation(@initial_students.map(&:id))
      add_message # need initial message for add_participants to not barf
    end

    def add_message
      @conversation.add_message("message")
    end

    def add_last_student
      @conversation.add_participants([@last_student.id])
    end

    it "should create appropriate notifications on new message" do
      message = add_message
      message.messages_sent.should be_include("Conversation Message")
      message.messages_sent.should_not be_include("Added To Conversation")
    end

    it "should create appropriate notifications on added participants" do
      event = add_last_student
      event.messages_sent.should_not be_include("Conversation Message")
      event.messages_sent.should be_include("Added To Conversation")
    end

    it "should not notify the author" do
      message = add_message
      message.messages_sent["Conversation Message"].map(&:user_id).should_not be_include(@teacher.id)

      event = add_last_student
      event.messages_sent["Added To Conversation"].map(&:user_id).should_not be_include(@teacher.id)
    end

    it "should not notify unsubscribed participants" do
      student_view = @first_student.conversations.first
      student_view.subscribed = false
      student_view.save

      message = add_message
      message.messages_sent["Conversation Message"].map(&:user_id).should_not be_include(@first_student.id)
    end

    it "should notify subscribed participants on new message" do
      message = add_message
      message.messages_sent["Conversation Message"].map(&:user_id).should be_include(@first_student.id)
    end

    it "should notify new participants" do
      event = add_last_student
      event.messages_sent["Added To Conversation"].map(&:user_id).should be_include(@last_student.id)
    end

    it "should not notify existing participants on added participant" do
      event = add_last_student
      event.messages_sent["Added To Conversation"].map(&:user_id).should_not be_include(@first_student.id)
    end

    it "should add a new message when a user replies to a notification" do
      conversation_message = add_message
      message = conversation_message.messages_sent["Conversation Message"].first

      message.context.should == conversation_message
      message.context.reply_from(:user => message.user, :purpose => 'general',
        :subject => message.subject,
        :text => "Reply to notification")
      # The initial message, the one the sent the notification,
      # and the response to the notification
      @conversation.messages.size.should == 3
      @conversation.messages.first.body.should match(/Reply to notification/)
    end
  end

  context "generate_user_note" do
    it "should add a user note under nominal circumstances" do
      Account.default.update_attribute :enable_user_notes, true
      course_with_teacher
      @teacher.associated_accounts << Account.default
      student = student_in_course.user
      student.associated_accounts << Account.default
      conversation = @teacher.initiate_conversation([student.id])
      message = conversation.add_message("reprimanded!")
      message.created_at = Time.at(0) # Jan 1, 1970 00:00:00 UTC
      note = message.generate_user_note
      student.user_notes.size.should be(1)
      student.user_notes.first.should eql(note)
      note.creator.should eql(@teacher)
      note.title.should eql("Private message, Jan  1, 1970")
      note.note.should eql("reprimanded!")
    end

    it "should fail if notes are disabled on the account" do
      Account.default.update_attribute :enable_user_notes, false
      course_with_teacher
      @teacher.associated_accounts << Account.default
      student = student_in_course.user
      student.associated_accounts << Account.default
      conversation = @teacher.initiate_conversation([student.id])
      message = conversation.add_message("reprimanded!")
      message.generate_user_note.should be_nil
      student.user_notes.size.should be(0)
    end

    it "should fail if there's more than one recipient" do
      Account.default.update_attribute :enable_user_notes, true
      course_with_teacher
      @teacher.associated_accounts << Account.default
      student1 = student_in_course.user
      student1.associated_accounts << Account.default
      student2 = student_in_course.user
      student2.associated_accounts << Account.default
      conversation = @teacher.initiate_conversation([student1.id, student2.id])
      message = conversation.add_message("message")
      message.generate_user_note.should be_nil
      student1.user_notes.size.should be(0)
      student2.user_notes.size.should be(0)
    end
  end

  context "stream_items" do
    it "should create a stream item based on the conversation" do
      old_count = StreamItem.count

      course_with_teacher
      student_in_course
      conversation = @teacher.initiate_conversation([@user.id])
      message = conversation.add_message("initial message")

      StreamItem.count.should eql(old_count + 1)
      stream_item = StreamItem.last
      stream_item.item_asset_string.should eql(message.conversation.asset_string)
    end

    it "should not create additional stream_items for additional messages in the same conversation" do
      old_count = StreamItem.count

      course_with_teacher
      student_in_course
      conversation = @teacher.initiate_conversation([@user.id])
      conversation.add_message("first message")
      stream_item = StreamItem.last
      conversation.add_message("second message")
      conversation.add_message("third message")

      StreamItem.count.should eql(old_count + 1)
      StreamItem.last.should eql(stream_item)
    end

    it "should not delete the stream_item if a message is deleted, just regenerate" do
      old_count = StreamItem.count

      course_with_teacher
      student_in_course
      conversation = @teacher.initiate_conversation([@user.id])
      conversation.add_message("initial message")
      message = conversation.add_message("second message")

      stream_item = StreamItem.last
      
      message.destroy
      StreamItem.count.should eql(old_count + 1)
    end

    it "should delete the stream_item if the conversation is deleted" # not yet implemented
  end
end
