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

module CoursesHelper
  def set_icon_data(opts = {})
    context      = opts[:context]
    contexts     = opts[:contexts]
    current_user = opts[:current_user]
    recent_event = opts[:recent_event]
    submission   = opts[:submission]

    unless recent_event.is_a?(Assignment)
      @icon_explanation, @icon_class = [nil, "calendar"]
      return
    end

    icon_data = [nil, 'icon-grading-gray']
    if can_do(context, current_user, :participate_as_student)
      icon_data = submission && submission.submitted_or_graded? ? [submission.readable_state, 'icon-grading'] : [t('#courses.recent_event.not_submitted', 'not submitted'), "icon-grading-gray"]
      icon_data[0] = nil if !recent_event.expects_submission?
    elsif can_do(context, current_user, :manage_grades)
      # no submissions
      if !recent_event.has_submitted_submissions?
        icon_data = [t('#courses.recent_event.no_submissions', 'no submissions'), "icon-grading-gray"]
      # all received submissions graded (but not all turned in)
      elsif recent_event.submitted_count < context.students.size && !current_user.assignments_needing_grading(:contexts => contexts).include?(recent_event)
        icon_data = [t('#courses.recent_event.no_new_submissions', 'no new submissions'), "icon-grading-gray"]
      # all submissions turned in and graded
      elsif !current_user.assignments_needing_grading(:contexts => contexts).include?(recent_event)
        icon_data = [t('#courses.recent_event.all_graded', 'all graded'), 'icon-grading']
      # assignments need grading
      else
        icon_data = [t('#courses.recent_event.needs_grading', 'needs grading'), "icon-grading-gray"]
      end
    end

    @icon_explanation, @icon_class = icon_data
  end

  def recent_event_url(recent_event)
    context = recent_event.context
    if recent_event.is_a?(Assignment)
      url = context_url(context, :context_assignment_url, :id => recent_event.id)
    else
      url = calendar_url_for(nil, {
        :query => {:month => recent_event.start_at.month, :year => recent_event.start_at.year},
        :anchor => "calendar_event_" + recent_event.id.to_s
      })
    end

    url
  end
end
